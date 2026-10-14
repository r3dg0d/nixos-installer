#!/usr/bin/env bash
# r3dg0d/nixos-installer — install NixOS with niri + SDDM and clone a GitHub user's repos.
#
#   curl -fsSL https://raw.githubusercontent.com/r3dg0d/nixos-installer/main/install.sh | sudo bash
#   curl -fsSL .../install.sh | sudo bash -s -- --dry-run
#
# THIS WIPES THE TARGET DISK. Read it first. MIT licensed.
set -euo pipefail

VERSION="0.1.0"
LOG_TMP="/tmp/r3dg0d-installer.log"
LOG_TARGET="/var/log/r3dg0d-installer.log"

# ---------- defaults (env overrides: NI_*) ----------
DISK="${NI_DISK:-}"
HOSTNAME_="${NI_HOSTNAME:-}"
USERNAME="${NI_USER:-}"
PASSWORD="${NI_PASSWORD:-}"
PASSWORD_HASH="${NI_PASSWORD_HASH:-}"
TIMEZONE="${NI_TIMEZONE:-}"
LOCALE="${NI_LOCALE:-}"
KEYMAP="${NI_KEYMAP:-}"
SWAP_GB="${NI_SWAP_GB:-}"
LUKS="${NI_LUKS:-}"                 # yes|no
LUKS_PASSWORD="${NI_LUKS_PASSWORD:-}"
FS="${NI_FS:-}"                     # ext4|btrfs
GH_USER="${NI_GITHUB_USER:-r3dg0d}"
REPOS="${NI_REPOS:-}"               # comma-separated explicit list; empty = fetch from API
CLONE_REPOS="${NI_CLONE_REPOS:-yes}"
SYSTEM_REPOS="${NI_SYSTEM_REPOS:-yes}"  # first boot: post-install.sh builds repos system-wide
BUILD_REPOS="${NI_BUILD_REPOS:-no}"     # first boot: per-user nix profile mode (legacy)
TERMINAL="${NI_TERMINAL:-}"          # ghostty with --rice, otherwise alacritty (niri default Mod+T)
RICE="${NI_RICE:-yes}"                 # deep-space rice from r3dg0d/dotfiles
DOTFILES_REPO="${NI_DOTFILES_REPO:-https://github.com/r3dg0d/dotfiles.git}"
CONFIRM_WIPE="${NI_CONFIRM_WIPE:-}" # unattended: must equal the disk name
DRY_RUN=no
ASSUME_DEFAULTS=no

usage() {
  cat <<USAGE
r3dg0d nixos-installer $VERSION — installs NixOS + niri + SDDM and clones GitHub repos.

Usage: install.sh [options]          (run as root from the NixOS live ISO)

  --disk DEV              target disk, e.g. /dev/nvme0n1 (WIPED)
  --hostname NAME         default: nixos
  --user NAME             login user (added to wheel)
  --password PW           plaintext (hashed with mkpasswd); or env NI_PASSWORD_HASH
  --timezone TZ           default: UTC        e.g. America/Los_Angeles
  --locale LOCALE         default: en_US.UTF-8
  --keymap MAP            default: us (console + XKB layout)
  --swap GB               swap partition size in GiB, 0 = none (default 0)
  --luks | --no-luks      encrypt root with LUKS2 (default: no)
  --luks-password PW      LUKS passphrase (else prompted)
  --fs ext4|btrfs         default: ext4 (btrfs uses @, @home, @nix subvolumes)
  --terminal ghostty|alacritty|foot
                          default: ghostty with --rice, else alacritty (niri's default Mod+T)
  --rice | --no-rice      apply the deep-space rice from github.com/r3dg0d/dotfiles: niri, ghostty,
                          waybar, fuzzel, mako, fastfetch configs + SDDM theme + wallpaper (default: on)
  --github-user NAME      whose public repos to clone (default: r3dg0d)
  --repos a,b,c           explicit repo list instead of querying the GitHub API
  --no-repos              do not clone any repos
  --system-repos | --no-system-repos
                          on first boot, run post-install.sh as root: build each repo and add it to
                          environment.systemPackages via /etc/nixos/r3dg0d-repos.nix (default: on)
  --build-repos | --no-build-repos
                          on first boot, install flake packages into the user's nix profile
                          instead/as well (default: off)
  --confirm-wipe DEV      unattended: confirm wiping DEV (must equal --disk)
  --defaults              accept defaults for anything not given (still asks for disk/user/password)
  --dry-run               print the plan and change nothing
  -h, --help              this help

Every option also has an env var: NI_DISK NI_HOSTNAME NI_USER NI_PASSWORD
NI_PASSWORD_HASH NI_TIMEZONE NI_LOCALE NI_KEYMAP NI_SWAP_GB NI_LUKS NI_LUKS_PASSWORD
NI_FS NI_TERMINAL NI_RICE NI_GITHUB_USER NI_REPOS NI_CLONE_REPOS NI_SYSTEM_REPOS NI_BUILD_REPOS
NI_CONFIRM_WIPE.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --disk) DISK="$2"; shift ;;
    --hostname) HOSTNAME_="$2"; shift ;;
    --user) USERNAME="$2"; shift ;;
    --password) PASSWORD="$2"; shift ;;
    --timezone) TIMEZONE="$2"; shift ;;
    --locale) LOCALE="$2"; shift ;;
    --keymap) KEYMAP="$2"; shift ;;
    --swap) SWAP_GB="$2"; shift ;;
    --luks) LUKS=yes ;;
    --no-luks) LUKS=no ;;
    --luks-password) LUKS_PASSWORD="$2"; shift ;;
    --fs) FS="$2"; shift ;;
    --terminal) TERMINAL="$2"; shift ;;
    --rice) RICE=yes ;;
    --no-rice) RICE=no ;;
    --github-user) GH_USER="$2"; shift ;;
    --repos) REPOS="$2"; shift ;;
    --no-repos) CLONE_REPOS=no ;;
    --system-repos) SYSTEM_REPOS=yes ;;
    --no-system-repos) SYSTEM_REPOS=no ;;
    --build-repos) BUILD_REPOS=yes ;;
    --no-build-repos) BUILD_REPOS=no ;;
    --confirm-wipe) CONFIRM_WIPE="$2"; shift ;;
    --defaults) ASSUME_DEFAULTS=yes ;;
    --dry-run) DRY_RUN=yes ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

# ---------- output helpers ----------
if [ -t 2 ]; then R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'; else R=; G=; Y=; B=; N=; fi
: > "$LOG_TMP" 2>/dev/null || LOG_TMP=/dev/null
log()  { printf '%s\n' "$*" >>"$LOG_TMP"; }
info() { printf '%s==>%s %s\n' "$G" "$N" "$*" >&2; log "==> $*"; }
warn() { printf '%sWARN:%s %s\n' "$Y" "$N" "$*" >&2; log "WARN: $*"; }
die()  { printf '%sERROR:%s %s\n' "$R" "$N" "$*" >&2; log "ERROR: $*"; exit 1; }
run()  {
  log "+ $*"
  if [ "$DRY_RUN" = yes ]; then printf '  [dry-run] %s\n' "$*" >&2; return 0; fi
  "$@" >>"$LOG_TMP" 2>&1 || die "command failed: $* (see $LOG_TMP)"
}

try_run() { # like run, but failure is fine (cleanup steps)
  log "+ $* (failure ok)"
  if [ "$DRY_RUN" = yes ]; then printf '  [dry-run] %s\n' "$*" >&2; return 0; fi
  "$@" >>"$LOG_TMP" 2>&1 || true
}

# Prompts read from the terminal so the script works when piped from curl.
TTY=/dev/tty
have_tty() { [ -r "$TTY" ] && [ -w "$TTY" ] && { : <"$TTY"; } 2>/dev/null; }
ask() { # ask VAR "Prompt" default
  local __var="$1" __prompt="$2" __def="${3:-}" __ans=""
  if [ -n "${!__var:-}" ]; then return 0; fi
  if [ "$ASSUME_DEFAULTS" = yes ] && [ -n "$__def" ]; then printf -v "$__var" '%s' "$__def"; return 0; fi
  have_tty || die "no terminal for prompt '$__prompt'; pass it as a flag or NI_* env var"
  printf '%s%s%s%s: ' "$B" "$__prompt" "$N" "${__def:+ [$__def]}" >"$TTY"
  IFS= read -r __ans <"$TTY" || true
  printf -v "$__var" '%s' "${__ans:-$__def}"
}
ask_secret() { # ask_secret VAR "Prompt"
  local __var="$1" __prompt="$2" a="" b=""
  if [ -n "${!__var:-}" ]; then return 0; fi
  have_tty || die "no terminal for '$__prompt'; pass it as a flag or NI_* env var"
  while :; do
    printf '%s: ' "$__prompt" >"$TTY"; IFS= read -rs a <"$TTY" || true; printf '\n' >"$TTY"
    printf 'Repeat: ' >"$TTY"; IFS= read -rs b <"$TTY" || true; printf '\n' >"$TTY"
    if [ -z "$a" ]; then printf 'Empty, try again.\n' >"$TTY"; continue; fi
    if [ "$a" = "$b" ]; then break; fi
    printf 'Did not match, try again.\n' >"$TTY"
  done
  printf -v "$__var" '%s' "$a"
}
yesno() { case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in y|yes|true|1|on) echo yes ;; *) echo no ;; esac; }

# ---------- preflight ----------
preflight() {
  info "r3dg0d nixos-installer $VERSION"
  local fatal=no
  if [ "$(id -u)" -ne 0 ]; then warn "not running as root"; fatal=yes; fi
  if ! grep -qs '^ID=nixos' /etc/os-release; then warn "this does not look like NixOS"; fatal=yes
  elif [ ! -e /etc/NIXOS_LUSTRATE ] && ! grep -qs 'VARIANT_ID=installer' /etc/os-release && [ ! -d /iso ]; then
    warn "could not confirm this is the NixOS live ISO (continuing)"
  fi
  for c in lsblk parted wipefs mkfs.vfat mkfs.ext4 nixos-generate-config nixos-install curl git; do
    command -v "$c" >/dev/null 2>&1 || { warn "missing command: $c"; fatal=yes; }
  done
  if curl -fsS --max-time 10 -o /dev/null https://cache.nixos.org/nix-cache-info; then info "network: ok"
  else warn "no network (cache.nixos.org unreachable)"; fatal=yes; fi
  if [ -n "${NI_BOOT_MODE:-}" ]; then BOOT_MODE="$NI_BOOT_MODE"; warn "boot mode forced to $BOOT_MODE via NI_BOOT_MODE"
  elif [ -d /sys/firmware/efi/efivars ]; then BOOT_MODE=uefi; else BOOT_MODE=bios; fi
  info "boot mode: $BOOT_MODE"
  if [ "$fatal" = yes ]; then
    if [ "$DRY_RUN" = yes ]; then warn "preflight failed; continuing only because this is --dry-run"
    else die "preflight failed (run as root from the NixOS live ISO with network)"; fi
  fi
}

# ---------- choices ----------
gather() {
  if [ -z "$DISK" ]; then
    printf '\nAvailable disks:\n' >&2
    lsblk -dpno NAME,SIZE,MODEL,TYPE 2>/dev/null | awk '$NF=="disk"||$NF=="loop"' >&2 || true
    printf '\n' >&2
  fi
  ask DISK "Target disk (WILL BE WIPED)"
  [ -b "$DISK" ] || die "$DISK is not a block device"
  ask HOSTNAME_ "Hostname" "nixos"
  ask USERNAME "Username"
  [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid username: $USERNAME"
  [[ "$HOSTNAME_" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]] || die "invalid hostname: $HOSTNAME_"
  if [ -z "$PASSWORD_HASH" ]; then ask_secret PASSWORD "Password for $USERNAME"; fi
  ask TIMEZONE "Timezone" "UTC"
  ask LOCALE "Locale" "en_US.UTF-8"
  ask KEYMAP "Keyboard layout" "us"
  ask SWAP_GB "Swap size in GiB (0 = none)" "0"
  [[ "$SWAP_GB" =~ ^[0-9]+$ ]] || die "swap must be a whole number of GiB"
  ask LUKS "Encrypt root with LUKS? (yes/no)" "no"; LUKS="$(yesno "$LUKS")"
  if [ "$LUKS" = yes ] && [ "$DRY_RUN" = no ]; then ask_secret LUKS_PASSWORD "LUKS passphrase"; fi
  ask FS "Filesystem (ext4/btrfs)" "ext4"
  case "$FS" in ext4|btrfs) ;; *) die "filesystem must be ext4 or btrfs" ;; esac
  RICE="$(yesno "$RICE")"
  if [ -z "$TERMINAL" ]; then if [ "$RICE" = yes ]; then TERMINAL=ghostty; else TERMINAL=alacritty; fi; fi
  case "$TERMINAL" in ghostty|foot|alacritty) ;; *) die "terminal must be ghostty, alacritty or foot" ;; esac
  CLONE_REPOS="$(yesno "$CLONE_REPOS")"; BUILD_REPOS="$(yesno "$BUILD_REPOS")"; SYSTEM_REPOS="$(yesno "$SYSTEM_REPOS")"
  [ "$CLONE_REPOS" = yes ] || BUILD_REPOS=no
}

partname() { case "$1" in *[0-9]) printf '%sp%s' "$1" "$2" ;; *) printf '%s%s' "$1" "$2" ;; esac; }

plan_layout() {
  local n=1
  if [ "$BOOT_MODE" = uefi ]; then P_ESP="$(partname "$DISK" $n)"; n=$((n+1)); P_BIOS=""; P_BOOT=""
  else P_BIOS="$(partname "$DISK" $n)"; n=$((n+1)); P_BOOT="$(partname "$DISK" $n)"; n=$((n+1)); P_ESP=""; fi
  if [ "$SWAP_GB" -gt 0 ]; then P_SWAP="$(partname "$DISK" $n)"; n=$((n+1)); else P_SWAP=""; fi
  P_ROOT="$(partname "$DISK" $n)"
  ROOT_DEV="$P_ROOT"; [ "$LUKS" = yes ] && ROOT_DEV=/dev/mapper/cryptroot
  return 0
}

print_plan() {
  cat >&2 <<PLAN

${B}Install plan${N}
  disk        $DISK  ($(lsblk -dno SIZE "$DISK" 2>/dev/null || echo '?'))
  boot        $BOOT_MODE ($( [ "$BOOT_MODE" = uefi ] && echo systemd-boot || echo GRUB ))
  partitions  ${P_ESP:+ESP 1GiB vfat=$P_ESP  }${P_BIOS:+bios_grub 1MiB=$P_BIOS  /boot 1GiB ext4=$P_BOOT  }${P_SWAP:+swap ${SWAP_GB}GiB=$P_SWAP  }root=$P_ROOT
  root fs     $FS$( [ "$FS" = btrfs ] && echo ' (subvolumes @ @home @nix, zstd)')$( [ "$LUKS" = yes ] && echo ' on LUKS2 (cryptroot)')
  hostname    $HOSTNAME_
  user        $USERNAME (wheel, NetworkManager)
  locale      $LOCALE   timezone $TIMEZONE   keymap $KEYMAP
  desktop     niri + SDDM (Wayland), PipeWire, $TERMINAL, fuzzel, waybar, mako, xwayland-satellite
  repos       $( [ "$CLONE_REPOS" = yes ] && echo "clone ${REPOS:-all public non-fork repos of $GH_USER} -> /home/$USERNAME/src" || echo none)
  rice        $( [ "$RICE" = yes ] && echo "deep-space from r3dg0d/dotfiles (configs in ~/.config, SDDM theme)" || echo no)
  system pkgs $( [ "$SYSTEM_REPOS" = yes ] && echo 'first boot: post-install.sh builds repos into environment.systemPackages' || echo no)
  user pkgs   $( [ "$BUILD_REPOS" = yes ] && echo 'first boot: install flake packages into the user profile' || echo no)
PLAN
}

confirm_wipe() {
  printf '\n%s%s!!! WARNING: EVERYTHING ON %s WILL BE DESTROYED !!!%s\n' "$R" "$B" "$DISK" "$N" >&2
  lsblk -po NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DISK" >&2 || true
  if [ -n "$CONFIRM_WIPE" ]; then
    [ "$CONFIRM_WIPE" = "$DISK" ] || die "--confirm-wipe ($CONFIRM_WIPE) does not match --disk ($DISK)"
    warn "wipe confirmed non-interactively for $DISK"; return 0
  fi
  have_tty || die "need a terminal to confirm the wipe (or pass --confirm-wipe $DISK)"
  local typed=""
  printf '%sType the disk name (%s) to wipe it, anything else aborts:%s ' "$B" "$DISK" "$N" >"$TTY"
  IFS= read -r typed <"$TTY" || true
  [ "$typed" = "$DISK" ] || die "confirmation did not match; nothing was changed"
}

# ---------- GitHub repos ----------
list_repos() { # prints repo names, one per line
  if [ -n "$REPOS" ]; then printf '%s\n' "$REPOS" | tr ',' '\n' | sed '/^$/d'; return 0; fi
  local page=1 body names
  while :; do
    body="$(curl -fsSL --max-time 30 -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/users/${GH_USER}/repos?type=owner&per_page=100&page=${page}")" \
      || { warn "GitHub API request failed (page $page); rate limited? Use --repos a,b,c"; return 0; }
    if command -v jq >/dev/null 2>&1; then
      names="$(printf '%s' "$body" | jq -r '.[] | select(.fork == false and .private == false) | .name')"
    else
      # GitHub pretty-prints JSON: repo-level keys are indented by 4 spaces.
      names="$(printf '%s\n' "$body" | awk '
        /^    "name": /    { n=$0; sub(/^[^:]*: "/,"",n); sub(/",?$/,"",n) }
        /^    "private": / { p=($0 ~ /true/) }
        /^    "fork": /    { if ($0 ~ /false/ && !p && n!="") print n; n="" }')"
    fi
    [ -n "$names" ] || break
    printf '%s\n' "$names"
    [ "$(printf '%s\n' "$names" | wc -l)" -lt 100 ] && break
    page=$((page+1))
  done
}

clone_repos() {
  local dest="/mnt/home/$USERNAME/src" ok=0 bad=0 r
  run mkdir -p "$dest"
  mapfile -t REPO_LIST < <(list_repos)
  info "repos to clone: ${#REPO_LIST[@]}"
  for r in "${REPO_LIST[@]}"; do
    [[ "$r" =~ ^[A-Za-z0-9._-]+$ ]] || { warn "skipping odd repo name: $r"; continue; }
    if [ "$DRY_RUN" = yes ]; then printf '  [dry-run] git clone https://github.com/%s/%s %s/%s\n' "$GH_USER" "$r" "$dest" "$r" >&2; ok=$((ok+1)); continue; fi
    if [ -d "$dest/$r/.git" ]; then ok=$((ok+1)); continue; fi
    if git clone --quiet "https://github.com/${GH_USER}/${r}.git" "$dest/$r" >>"$LOG_TMP" 2>&1; then
      ok=$((ok+1)); log "cloned $r"
    else bad=$((bad+1)); warn "clone failed: $r (continuing)"; fi
  done
  REPO_SUMMARY="$( [ "$DRY_RUN" = yes ] && echo "would clone $ok" || echo "cloned $ok, failed $bad")"
}

write_repo_installer() { # first-boot script that installs flake packages into the user profile
  local f="/mnt/home/$USERNAME/src/install-repos.sh"
  [ "$DRY_RUN" = yes ] && { printf '  [dry-run] write %s\n' "$f" >&2; return 0; }
  cat >"$f" <<'SCRIPT'
#!/usr/bin/env bash
# Installs the default package of every repo in ~/src that has a flake.nix.
# Safe to re-run; a failing repo is logged and skipped. Log: ~/src/install-repos.log
set -uo pipefail
src="$(cd "$(dirname "$0")" && pwd)"
logf="$src/install-repos.log"
state="${XDG_STATE_HOME:-$HOME/.local/state}/r3dg0d-install-repos"   # one file per installed repo (git rev)
mkdir -p "$state"
sys="$(nix eval --impure --raw --expr builtins.currentSystem 2>/dev/null || echo x86_64-linux)"
ok=0; bad=0; skip=0
echo "=== $(date -Is) install-repos ($sys)" >>"$logf"
for d in "$src"/*/; do
  d="${d%/}"; name="$(basename "$d")"
  [ -f "$d/flake.nix" ] || { echo "skip $name: no flake.nix" >>"$logf"; skip=$((skip+1)); continue; }
  if ! nix eval "path:$d#packages.$sys" --apply builtins.attrNames >/dev/null 2>>"$logf"; then
    echo "skip $name: flake has no packages.$sys" >>"$logf"; skip=$((skip+1)); continue
  fi
  rev="$(git -C "$d" rev-parse HEAD 2>/dev/null || echo unknown)"
  if [ "$(cat "$state/$name" 2>/dev/null)" = "$rev" ]; then echo "ok $name (already installed at $rev)" >>"$logf"; ok=$((ok+1)); continue; fi
  echo "installing $name ..." | tee -a "$logf"
  if nix profile install "path:$d" >>"$logf" 2>&1; then ok=$((ok+1)); echo "ok $name" >>"$logf"; printf '%s\n' "$rev" >"$state/$name"
  else bad=$((bad+1)); echo "FAILED $name" | tee -a "$logf"; fi
done
echo "done: installed $ok, failed $bad, skipped $skip" | tee -a "$logf"
exit 0
SCRIPT
  chmod 755 "$f"
}

# ---------- disk ----------
partition_and_mount() {
  info "partitioning $DISK"
  try_run swapoff -a
  if mountpoint -q /mnt 2>/dev/null; then run umount -R /mnt; fi
  [ -e /dev/mapper/cryptroot ] && try_run cryptsetup close cryptroot
  run wipefs -af "$DISK"
  run parted -s "$DISK" mklabel gpt
  local start=1
  if [ "$BOOT_MODE" = uefi ]; then
    run parted -s "$DISK" mkpart ESP fat32 1MiB 1025MiB
    run parted -s "$DISK" set 1 esp on
    start=1025
  else
    run parted -s "$DISK" mkpart biosboot 1MiB 2MiB
    run parted -s "$DISK" set 1 bios_grub on
    run parted -s "$DISK" mkpart boot ext4 2MiB 1026MiB
    start=1026
  fi
  if [ "$SWAP_GB" -gt 0 ]; then
    local end=$((start + SWAP_GB * 1024))
    run parted -s "$DISK" mkpart swap linux-swap "${start}MiB" "${end}MiB"
    start=$end
  fi
  run parted -s "$DISK" mkpart root "${start}MiB" 100%
  run partprobe "$DISK"
  run udevadm settle

  if [ "$LUKS" = yes ]; then
    info "setting up LUKS2 on $P_ROOT"
    if [ "$DRY_RUN" = no ]; then
      printf '%s' "$LUKS_PASSWORD" | cryptsetup luksFormat --type luks2 --batch-mode --key-file - "$P_ROOT" >>"$LOG_TMP" 2>&1 || die "luksFormat failed"
      printf '%s' "$LUKS_PASSWORD" | cryptsetup open --key-file - "$P_ROOT" cryptroot >>"$LOG_TMP" 2>&1 || die "cryptsetup open failed"
    else printf '  [dry-run] cryptsetup luksFormat + open %s as cryptroot\n' "$P_ROOT" >&2; fi
  fi

  info "formatting"
  [ -n "$P_ESP" ] && run mkfs.vfat -F 32 -n BOOT "$P_ESP"
  [ -n "$P_BOOT" ] && run mkfs.ext4 -F -L boot "$P_BOOT"
  [ -n "$P_SWAP" ] && [ "$LUKS" = no ] && run mkswap -L swap "$P_SWAP"
  if [ "$FS" = ext4 ]; then
    run mkfs.ext4 -F -L nixos "$ROOT_DEV"
    run udevadm settle
    run mount -t ext4 "$ROOT_DEV" /mnt
  else
    run mkfs.btrfs -f -L nixos "$ROOT_DEV"
    run udevadm settle
    run mount -t btrfs "$ROOT_DEV" /mnt
    run btrfs subvolume create /mnt/@
    run btrfs subvolume create /mnt/@home
    run btrfs subvolume create /mnt/@nix
    run umount /mnt
    run mount -t btrfs -o subvol=@,compress=zstd,noatime "$ROOT_DEV" /mnt
    run mkdir -p /mnt/home /mnt/nix
    run mount -t btrfs -o subvol=@home,compress=zstd,noatime "$ROOT_DEV" /mnt/home
    run mount -t btrfs -o subvol=@nix,compress=zstd,noatime "$ROOT_DEV" /mnt/nix
  fi
  run mkdir -p /mnt/boot
  if [ -n "$P_ESP" ]; then run mount -t vfat -o umask=0077 "$P_ESP" /mnt/boot; else run mount -t ext4 "$P_BOOT" /mnt/boot; fi
  [ -n "$P_SWAP" ] && [ "$LUKS" = no ] && run swapon "$P_SWAP"
  return 0
}

# ---------- configuration ----------
nix_str() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/\\$/g')"; }

write_config() {
  local cfg="/mnt/etc/nixos/configuration.nix" sv
  sv="$(nixos-version 2>/dev/null | cut -d. -f1-2 || true)"; [[ "$sv" =~ ^[0-9]{2}\.[0-9]{2}$ ]] || sv="25.05"
  local boot luks="" swap="" btrfsopts="" build=""
  if [ "$BOOT_MODE" = uefi ]; then
    boot='  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10;
  boot.loader.efi.canTouchEfiVariables = true;'
  else
    boot="  boot.loader.grub.enable = true;
  boot.loader.grub.device = $(nix_str "$DISK");"
  fi
  if [ "$LUKS" = yes ]; then
    local uuid=DRY-RUN-UUID
    if [ "$DRY_RUN" = no ]; then uuid="$(blkid -s UUID -o value "$P_ROOT")"; fi
    luks="  boot.initrd.luks.devices.cryptroot.device = \"/dev/disk/by-uuid/$uuid\";"
  fi
  if [ -n "$P_SWAP" ]; then
    if [ "$LUKS" = yes ]; then
      local partuuid=DRY-RUN-PARTUUID
      if [ "$DRY_RUN" = no ]; then partuuid="$(blkid -s PARTUUID -o value "$P_SWAP")"; fi
      swap="  # Swap is re-encrypted with a random key every boot (no hibernation).
  swapDevices = [ { device = \"/dev/disk/by-partuuid/$partuuid\"; randomEncryption.enable = true; } ];"
    fi
  fi
  if [ "$FS" = btrfs ]; then
    btrfsopts='  fileSystems."/".options = [ "compress=zstd" "noatime" ];
  fileSystems."/home".options = [ "compress=zstd" "noatime" ];
  fileSystems."/nix".options = [ "compress=zstd" "noatime" ];
  services.btrfs.autoScrub.enable = true;'
  fi
  local sysrepos=""
  if [ "$SYSTEM_REPOS" = yes ]; then
    local pargs="--github-user $GH_USER --user $USERNAME"
    [ "$RICE" = yes ] || pargs="$pargs --no-dotfiles"
    [ -n "$REPOS" ] && pargs="$pargs --repos $REPOS"
    sysrepos="  # First boot: build ${GH_USER}'s repos and add them system-wide (runs once; re-run
  # /etc/nixos/r3dg0d-post-install.sh by hand to update). Log: /var/log/r3dg0d-post-install.log
  systemd.services.r3dg0d-post-install = {
    description = \"Build repos into environment.systemPackages (r3dg0d nixos-installer)\";
    wantedBy = [ \"multi-user.target\" ];
    wants = [ \"network-online.target\" ];
    after = [ \"network-online.target\" \"nix-daemon.service\" ];
    path = with pkgs; [ nix git curl coreutils gnused gnugrep gawk findutils bash config.system.build.nixos-rebuild ];
    environment.NIX_PATH = lib.concatStringsSep \":\" config.nix.nixPath;
    unitConfig.ConditionPathExists = \"!/var/lib/r3dg0d-installer/system-repos-done\";
    restartIfChanged = false;
    serviceConfig = {
      Type = \"oneshot\";
      StateDirectory = \"r3dg0d-installer\";
      TimeoutStartSec = \"infinity\";
      ExecStart = \"\${pkgs.bash}/bin/bash /etc/nixos/r3dg0d-post-install.sh $pargs\";
      ExecStartPost = \"\${pkgs.coreutils}/bin/touch /var/lib/r3dg0d-installer/system-repos-done\";
    };
  };"
  fi
  if [ "$BUILD_REPOS" = yes ]; then
    build="  # First boot: install flake packages from ~/src into the user's profile (runs once).
  systemd.services.r3dg0d-install-repos = {
    description = \"Install flake packages from ~/src (r3dg0d nixos-installer)\";
    wantedBy = [ \"multi-user.target\" ];
    wants = [ \"network-online.target\" ];
    after = [ \"network-online.target\" \"nix-daemon.service\" ];
    path = [ pkgs.nix pkgs.git pkgs.coreutils pkgs.gnugrep pkgs.bash ];
    unitConfig.ConditionPathExists = \"!/var/lib/r3dg0d-installer/repos-done\";
    serviceConfig = {
      Type = \"oneshot\";
      User = $(nix_str "$USERNAME");
      StateDirectory = \"r3dg0d-installer\";
      TimeoutStartSec = \"6h\";
      ExecStart = \"\${pkgs.bash}/bin/bash /home/$USERNAME/src/install-repos.sh\";
      ExecStartPost = \"\${pkgs.coreutils}/bin/touch /var/lib/r3dg0d-installer/repos-done\";
    };
  };"
  fi

  [ "$DRY_RUN" = yes ] && cfg="/tmp/r3dg0d-installer-configuration.nix"
  mkdir -p "$(dirname "$cfg")"
  cat >"$cfg" <<NIX
# Generated by r3dg0d/nixos-installer $VERSION — edit freely, then: sudo nixos-rebuild switch
{ config, lib, pkgs, ... }:

{
  imports = [ ./hardware-configuration.nix$( [ "$RICE" = yes ] && echo " ./r3dg0d-rice.nix") ];

$boot
$luks
  boot.kernelPackages = pkgs.linuxPackages_latest;

  networking.hostName = $(nix_str "$HOSTNAME_");
  networking.networkmanager.enable = true;

  time.timeZone = $(nix_str "$TIMEZONE");
  i18n.defaultLocale = $(nix_str "$LOCALE");
  console.keyMap = $(nix_str "$KEYMAP");
  services.xserver.xkb.layout = $(nix_str "$KEYMAP");

  hardware.enableRedistributableFirmware = true;
  hardware.graphics.enable = true;
  hardware.bluetooth.enable = true;

$swap
$btrfsopts

  # Desktop: niri (scrollable-tiling Wayland compositor) started from SDDM.
  programs.niri.enable = true;
  services.displayManager.sddm.enable = true;
  services.displayManager.sddm.wayland.enable = true;
  services.displayManager.defaultSession = "niri";
  xdg.portal.enable = true;
  xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
  security.polkit.enable = true;
  services.gnome.gnome-keyring.enable = true;
  fonts.packages = with pkgs; [ noto-fonts noto-fonts-color-emoji dejavu_fonts ];

  # Audio
  security.rtkit.enable = true;
  services.pulseaudio.enable = false;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    jack.enable = true;
  };

  users.users.$(nix_str "$USERNAME") = {
    isNormalUser = true;
    uid = 1000;
    description = $(nix_str "$USERNAME");
    extraGroups = [ "wheel" "networkmanager" "video" "audio" "input" ];
    hashedPasswordFile = "/etc/nixos/secrets/$USERNAME.passwd";
  };
  users.mutableUsers = true;

  environment.systemPackages = with pkgs; [
    git curl wget vim htop file unzip
    $TERMINAL fuzzel waybar mako xwayland-satellite
    swaylock swayidle swaybg wl-clipboard grim slurp brightnessctl pavucontrol
    networkmanagerapplet firefox
  ];
  environment.sessionVariables.NIXOS_OZONE_WL = "1";

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.trusted-users = [ "root" "@wheel" ];
  nix.gc = { automatic = true; dates = "weekly"; options = "--delete-older-than 14d"; };
  nixpkgs.config.allowUnfree = true;

$build

$sysrepos

  services.openssh.enable = false;
  system.stateVersion = "$sv";
}
NIX
  info "wrote $cfg"
}

write_password() {
  local f="/mnt/etc/nixos/secrets/$USERNAME.passwd"
  [ "$DRY_RUN" = yes ] && { printf '  [dry-run] write hashed password to %s (0600)\n' "$f" >&2; return 0; }
  if [ -z "$PASSWORD_HASH" ]; then
    command -v mkpasswd >/dev/null 2>&1 || die "mkpasswd not found"
    PASSWORD_HASH="$(printf '%s' "$PASSWORD" | mkpasswd -m sha-512 --stdin)"
  fi
  install -d -m 0700 "$(dirname "$f")"
  ( umask 077; printf '%s\n' "$PASSWORD_HASH" >"$f" )
}

apply_rice() { # system module + user configs from r3dg0d/dotfiles
  local dir=/mnt/etc/nixos/r3dg0d-dotfiles home="/mnt/home/$USERNAME"
  if [ "$DRY_RUN" = yes ]; then
    printf '  [dry-run] git clone %s %s\n' "$DOTFILES_REPO" "$dir" >&2
    printf '  [dry-run] write /mnt/etc/nixos/r3dg0d-rice.nix (imports ./r3dg0d-dotfiles/nix/rice.nix)\n' >&2
    printf '  [dry-run] HOME=%s %s/install.sh  (configs into ~/.config)\n' "$home" "$dir" >&2
    return 0
  fi
  info "applying the deep-space rice"
  if ! git clone --quiet "$DOTFILES_REPO" "$dir" >>"$LOG_TMP" 2>&1; then
    warn "could not clone $DOTFILES_REPO; installing without the rice"
    RICE=no
    sed -i 's# ./r3dg0d-rice.nix##' /mnt/etc/nixos/configuration.nix
    return 0
  fi
  cat >/mnt/etc/nixos/r3dg0d-rice.nix <<'NIX'
# deep-space rice (github.com/r3dg0d/dotfiles): packages, fonts and SDDM theme.
# Update with: sudo /etc/nixos/r3dg0d-post-install.sh   (or git -C /etc/nixos/r3dg0d-dotfiles pull)
{ imports = [ ./r3dg0d-dotfiles/nix/rice.nix ]; }
NIX
  mkdir -p "$home"
  HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
    bash "$dir/install.sh" >>"$LOG_TMP" 2>&1 || warn "dotfiles install.sh failed (see $LOG_TMP)"
}

POST_URL="${NI_POST_INSTALL_URL:-https://raw.githubusercontent.com/r3dg0d/nixos-installer/main/post-install.sh}"
fetch_post_install() {
  local f=/mnt/etc/nixos/r3dg0d-post-install.sh here
  here="$(dirname "${BASH_SOURCE[0]:-/nonexistent}")"
  if [ "$DRY_RUN" = yes ]; then printf '  [dry-run] fetch %s -> %s\n' "$POST_URL" "$f" >&2; return 0; fi
  if [ -f "$here/post-install.sh" ]; then cp "$here/post-install.sh" "$f"
  elif ! curl -fsSL --max-time 60 "$POST_URL" -o "$f"; then
    warn "could not download post-install.sh; system-wide repo builds disabled"
    SYSTEM_REPOS=no; sed -i '/r3dg0d-post-install = {/,/^  };/d' /mnt/etc/nixos/configuration.nix; return 0
  fi
  chmod 755 "$f"
}

# ---------- main ----------
main() {
  preflight
  gather
  plan_layout
  print_plan
  if [ "$DRY_RUN" = yes ]; then
    info "DRY RUN: no disk changes will be made"
  else
    confirm_wipe
  fi
  partition_and_mount
  info "generating hardware configuration"
  run nixos-generate-config --root /mnt
  write_config
  write_password
  if [ "$SYSTEM_REPOS" = yes ]; then fetch_post_install; fi
  REPO_SUMMARY="skipped"
  if [ "$RICE" = yes ]; then apply_rice; fi
  if [ "$CLONE_REPOS" = yes ]; then clone_repos; [ "$BUILD_REPOS" = yes ] && write_repo_installer; fi
  if [ "$DRY_RUN" = no ] && [ -d "/mnt/home/$USERNAME" ]; then chown -R 1000:100 "/mnt/home/$USERNAME"; fi
  info "running nixos-install (this takes a while)"
  if [ "$DRY_RUN" = yes ]; then printf '  [dry-run] nixos-install --no-root-passwd --root /mnt\n' >&2
  else
    nixos-install --no-root-passwd --root /mnt 2>&1 | tee -a "$LOG_TMP" || die "nixos-install failed (see $LOG_TMP)"
  fi
  # The hashed password file is applied at activation; also set it directly so it is in /etc/shadow.
  if [ "$DRY_RUN" = no ]; then
    printf '%s:%s\n' "$USERNAME" "$PASSWORD_HASH" | nixos-enter --root /mnt -c 'chpasswd -e' >>"$LOG_TMP" 2>&1 \
      || warn "could not set password via chpasswd (hashedPasswordFile still applies)"
    mkdir -p /mnt/var/log && cp "$LOG_TMP" "/mnt$LOG_TARGET"
  fi

  cat >&2 <<DONE

${G}${B}Done.${N}$( [ "$DRY_RUN" = yes ] && echo ' (dry run — nothing was changed)')
  disk      $DISK ($BOOT_MODE, $FS$( [ "$LUKS" = yes ] && echo ', LUKS'))
  host      $HOSTNAME_   user $USERNAME
  desktop   niri via SDDM$( [ "$RICE" = yes ] && echo ", deep-space rice (ghostty)")
  repos     $REPO_SUMMARY  -> /home/$USERNAME/src
  system    $( [ "$SYSTEM_REPOS" = yes ] && echo "first boot: r3dg0d-post-install.service (log /var/log/r3dg0d-post-install.log)" || echo off)
  user pkgs $( [ "$BUILD_REPOS" = yes ] && echo "first boot: r3dg0d-install-repos.service (log ~/src/install-repos.log)" || echo off)
  config    /etc/nixos/configuration.nix
  log       $( [ "$DRY_RUN" = yes ] && echo "$LOG_TMP" || echo "$LOG_TARGET") 
$( [ "$DRY_RUN" = yes ] && echo "  preview   /tmp/r3dg0d-installer-configuration.nix" || echo "Remove the ISO and reboot.")
DONE
}

main "$@"
