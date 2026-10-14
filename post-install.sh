#!/usr/bin/env bash
# r3dg0d/nixos-installer post-install: install a GitHub user's repos SYSTEM-WIDE on NixOS.
#
#   curl -fsSL https://raw.githubusercontent.com/r3dg0d/nixos-installer/main/post-install.sh | sudo bash
#
# Clones/updates repos under /opt/r3dg0d/src, pre-builds each one on its own, writes
# /etc/nixos/r3dg0d-repos.nix (environment.systemPackages), imports it from
# configuration.nix and runs nixos-rebuild switch. Re-run to update. MIT licensed.
set -euo pipefail

GH_USER="${NI_GITHUB_USER:-r3dg0d}"
REPOS="${NI_REPOS:-}"
SRC_DIR="${NI_SRC_DIR:-/opt/r3dg0d/src}"
NIXOS_DIR="${NI_NIXOS_DIR:-/etc/nixos}"
MODULE_OUT=""
SKIP_DEFAULT="r3dg0d r3dg0d.github.io dotfiles nixos-installer"
INCLUDE_ALL=no
SWITCH=yes
UPDATE=yes
CHECK_HOST=yes
LOG="${NI_LOG:-/var/log/r3dg0d-post-install.log}"

usage() {
  cat <<USAGE
post-install.sh: build ${GH_USER}'s public repos and add them to environment.systemPackages.

  --repos a,b,c        only these repos (default: every public non-fork repo)
  --github-user NAME   default: r3dg0d          (GITHUB_TOKEN env avoids API rate limits)
  --include-all        also include: $SKIP_DEFAULT
  --src-dir DIR        where repos are cloned  (default: /opt/r3dg0d/src)
  --nixos-dir DIR      NixOS config dir        (default: /etc/nixos)
  --module-out FILE    write the module here   (default: <nixos-dir>/r3dg0d-repos.nix)
  --no-update          do not git pull repos that already exist
  --no-switch          generate + verify only; do not touch configuration.nix or rebuild
  --no-host-check      allow running off NixOS / as non-root (testing; implies --no-switch)
  -h, --help
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repos) REPOS="$2"; shift ;;
    --github-user) GH_USER="$2"; shift ;;
    --include-all) INCLUDE_ALL=yes ;;
    --src-dir) SRC_DIR="$2"; shift ;;
    --nixos-dir) NIXOS_DIR="$2"; shift ;;
    --module-out) MODULE_OUT="$2"; shift ;;
    --no-update) UPDATE=no ;;
    --no-switch) SWITCH=no ;;
    --no-host-check) CHECK_HOST=no; SWITCH=no ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done
MODULE_OUT="${MODULE_OUT:-$NIXOS_DIR/r3dg0d-repos.nix}"

if [ "$CHECK_HOST" = yes ]; then
  [ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 1; }
  grep -qs '^ID=nixos' /etc/os-release || { echo "this is not NixOS" >&2; exit 1; }
else
  LOG="${NI_LOG:-/tmp/r3dg0d-post-install.log}"
fi
mkdir -p "$(dirname "$LOG")" "$SRC_DIR"
: >>"$LOG"
say()  { printf '%s\n' "$*" >&2; printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG"; }
die()  { say "ERROR: $*"; exit 1; }

export NIX_CONFIG="experimental-features = nix-command flakes
${NIX_CONFIG:-}"
if [ -z "${NIX_PATH:-}" ]; then
  export NIX_PATH="nixpkgs=/nix/var/nix/profiles/per-user/root/channels/nixos:nixos-config=$NIXOS_DIR/configuration.nix"
fi
SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
command -v git >/dev/null || die "git is required"
say "=== post-install for $GH_USER on $SYSTEM (src $SRC_DIR)"

# ---------- repo list ----------
list_repos() {
  if [ -n "$REPOS" ]; then printf '%s\n' "$REPOS" | tr ',' '\n' | sed '/^$/d'; return 0; fi
  local page=1 body names auth=()
  [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  while :; do
    body="$(curl -fsSL --max-time 30 "${auth[@]}" -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/users/${GH_USER}/repos?type=owner&per_page=100&page=${page}")" \
      || die "GitHub API request failed (rate limited? set GITHUB_TOKEN or use --repos)"
    names="$(printf '%s\n' "$body" | awk '
      /^    "name": /    { n=$0; sub(/^[^:]*: "/,"",n); sub(/",?$/,"",n) }
      /^    "private": / { p=($0 ~ /true/) }
      /^    "fork": /    { if ($0 ~ /false/ && !p && n!="") print n; n="" }')"
    [ -n "$names" ] || break
    printf '%s\n' "$names"
    [ "$(printf '%s\n' "$names" | wc -l)" -lt 100 ] && break
    page=$((page+1))
  done
}

mapfile -t ALL < <(list_repos)
[ "${#ALL[@]}" -gt 0 ] || die "no repos found"

declare -a INCLUDED=() SKIPPED=() FAILED=() ENTRIES=() MODULE_NOTES=()
is_default_skip() { [ "$INCLUDE_ALL" = no ] && [ -z "$REPOS" ] && [[ " $SKIP_DEFAULT " == *" $1 "* ]]; }

# ---------- per repo ----------
for name in "${ALL[@]}"; do
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || { SKIPPED+=("$name (odd name)"); continue; }
  if is_default_skip "$name"; then SKIPPED+=("$name (skipped by default; --include-all)"); continue; fi
  dir="$SRC_DIR/$name"
  if [ -d "$dir/.git" ]; then
    if [ "$UPDATE" = yes ]; then
      git -C "$dir" pull --ff-only --quiet >>"$LOG" 2>&1 || say "warn: could not update $name (keeping current checkout)"
    fi
  else
    git clone --quiet "https://github.com/${GH_USER}/${name}.git" "$dir" >>"$LOG" 2>&1 \
      || { FAILED+=("$name (clone failed)"); say "FAILED $name: clone"; continue; }
  fi
  ref="git+file://$dir"
  attrs=()
  kind=""
  if [ -f "$dir/flake.nix" ]; then
    if json="$(nix eval --json "$ref#packages.$SYSTEM" --apply builtins.attrNames 2>>"$LOG")"; then
      mapfile -t attrs < <(printf '%s' "$json" | tr -d '[]"' | tr ',' '\n' | sed '/^$/d')
      # Prefer the default package; fall back to every named package.
      if printf '%s\n' "${attrs[@]}" | grep -qx default; then attrs=(default); fi
      kind=flake
    fi
    if nix eval --json "$ref#nixosModules" --apply builtins.attrNames >/tmp/r3dg0d-mods.$$ 2>/dev/null; then
      MODULE_NOTES+=("$name provides nixosModules: $(tr -d '[]"' </tmp/r3dg0d-mods.$$) (not enabled automatically)")
    fi
    rm -f /tmp/r3dg0d-mods.$$
  fi
  if [ -z "$kind" ]; then
    for f in package.nix default.nix; do
      if [ -f "$dir/$f" ]; then kind="callPackage:$f"; attrs=(_); break; fi
    done
  fi
  if [ -z "$kind" ]; then SKIPPED+=("$name (no flake packages, package.nix or default.nix)"); say "skip $name: nothing buildable"; continue; fi

  for a in "${attrs[@]}"; do
    if [ "$kind" = flake ]; then
      label="$name#$a"
      build=(nix build --no-link --print-out-paths "$ref#packages.$SYSTEM.$a")
      expr="(builtins.getFlake \"$ref\").packages.\${pkgs.stdenv.hostPlatform.system}.\"$a\""
    else
      f="${kind#callPackage:}"; label="$name ($f)"
      build=(nix-build --no-out-link -E "with import <nixpkgs> {}; callPackage $dir/$f {}")
      expr="(pkgs.callPackage $dir/$f { })"
    fi
    say "building $label ..."
    if out="$("${build[@]}" 2>>"$LOG" | tail -n1)"; then
      INCLUDED+=("$label -> $out"); ENTRIES+=("    $expr  # $label")
      say "ok $label"
    else
      FAILED+=("$label (build failed; see $LOG)"); say "FAILED $label: build"
    fi
  done
done

# ---------- module ----------
tmp="$(mktemp)"
{
  echo "# Generated by r3dg0d/nixos-installer post-install.sh on $(date -Is). Re-run to regenerate."
  echo "# Only repos that built successfully on their own are listed."
  echo "{ pkgs, ... }:"
  echo "{"
  echo "  nix.settings.experimental-features = [ \"nix-command\" \"flakes\" ];"
  echo "  environment.systemPackages = ["
  if [ "${#ENTRIES[@]}" -gt 0 ]; then printf '%s\n' "${ENTRIES[@]}"; fi
  echo "  ];"
  for n in "${MODULE_NOTES[@]}"; do echo "  # $n"; done
  echo "}"
} >"$tmp"

# Evaluate the generated module on its own against the system's nixpkgs before installing it.
say "evaluating generated module"
if ! nix-instantiate --eval --strict -E "
  let pkgs = import <nixpkgs> {}; m = import $tmp { inherit pkgs; };
  in map (p: p.outPath) m.environment.systemPackages" >>"$LOG" 2>&1; then
  rm -f "$tmp"; die "generated module did not evaluate; nothing changed (see $LOG)"
fi
mkdir -p "$(dirname "$MODULE_OUT")"
install -m 0644 "$tmp" "$MODULE_OUT"; rm -f "$tmp"
say "wrote $MODULE_OUT"

# ---------- wire + switch ----------
if [ "$SWITCH" = yes ]; then
  cfg="$NIXOS_DIR/configuration.nix"
  if [ -f "$NIXOS_DIR/flake.nix" ]; then
    say "NOTE: $NIXOS_DIR is a flake. Add ./r3dg0d-repos.nix to your nixosConfiguration modules and run:"
    say "      nixos-rebuild switch --impure   (builtins.getFlake on local paths needs --impure)"
  elif grep -q 'r3dg0d-repos\.nix' "$cfg"; then
    say "configuration.nix already imports r3dg0d-repos.nix"
  elif grep -qE '^[[:space:]]*imports[[:space:]]*=[[:space:]]*\[' "$cfg"; then
    cp "$cfg" "$cfg.bak-r3dg0d"
    sed -i -E '0,/^[[:space:]]*imports[[:space:]]*=[[:space:]]*\[/s//&\n    .\/r3dg0d-repos.nix/' "$cfg"
    say "added ./r3dg0d-repos.nix to imports in $cfg (backup: $cfg.bak-r3dg0d)"
  else
    die "could not find 'imports = [' in $cfg; add ./r3dg0d-repos.nix to imports yourself"
  fi
  if [ ! -f "$NIXOS_DIR/flake.nix" ]; then
    say "running nixos-rebuild switch"
    nixos-rebuild switch 2>&1 | tee -a "$LOG" >&2 || die "nixos-rebuild failed (module kept at $MODULE_OUT; see $LOG)"
  fi
fi

{
  echo
  echo "Included (${#INCLUDED[@]}):"; for x in "${INCLUDED[@]}"; do echo "  + $x"; done
  echo "Skipped (${#SKIPPED[@]}):";   for x in "${SKIPPED[@]}";  do echo "  - $x"; done
  echo "Failed (${#FAILED[@]}):";     for x in "${FAILED[@]}";   do echo "  ! $x"; done
  for n in "${MODULE_NOTES[@]}"; do echo "  note: $n"; done
  echo "Module: $MODULE_OUT   Log: $LOG"
} | tee -a "$LOG" >&2
