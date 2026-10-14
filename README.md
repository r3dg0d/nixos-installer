# nixos-installer

Two scripts:

- **`install.sh`** runs from the NixOS live ISO, wipes a disk and installs NixOS with niri + SDDM.
- **`post-install.sh`** runs on an installed NixOS and installs r3dg0d's repos **system-wide**
  (declaratively, via `environment.systemPackages`). `install.sh` schedules it for first boot by
  default.

An open-source NixOS installer script. Run it from the official NixOS live ISO and it
partitions a disk, installs NixOS with the **niri** Wayland compositor started from **SDDM**, and
clones every public repo of [r3dg0d](https://github.com/r3dg0d) into `~/src`.

> [!WARNING]
> **This erases the whole target disk.** Every partition and file on it is destroyed. The script
> shows the disk and asks you to type its name before it touches anything, and `--dry-run` shows the
> full plan without changing anything. Back up first.

## Quick start

Boot the NixOS ISO (25.11 or newer, graphical or minimal), connect to the network, then:

```bash
curl -fsSL https://raw.githubusercontent.com/r3dg0d/nixos-installer/main/install.sh | sudo bash
```

Prompts are read from `/dev/tty`, so they work even though the script is piped. Preview first:

```bash
curl -fsSL https://raw.githubusercontent.com/r3dg0d/nixos-installer/main/install.sh | sudo bash -s -- --dry-run
```

## Inspect before running

Piping a script into root is a trust decision. Read it first:

```bash
curl -fsSL https://raw.githubusercontent.com/r3dg0d/nixos-installer/main/install.sh -o install.sh
less install.sh
sudo bash install.sh --dry-run
sudo bash install.sh
```

To pin an exact version, replace `main` in the URL with a commit SHA.

## Options

| Flag | Env var | Default | Meaning |
|------|---------|---------|---------|
| `--disk DEV` | `NI_DISK` | prompt (lists disks) | Disk to **wipe** and install to |
| `--hostname NAME` | `NI_HOSTNAME` | `nixos` | Hostname |
| `--user NAME` | `NI_USER` | prompt | Login user (in `wheel`, `networkmanager`) |
| `--password PW` | `NI_PASSWORD` / `NI_PASSWORD_HASH` | prompt (hidden) | Hashed with `mkpasswd -m sha-512` |
| `--timezone TZ` | `NI_TIMEZONE` | `UTC` | e.g. `America/Los_Angeles` |
| `--locale L` | `NI_LOCALE` | `en_US.UTF-8` | |
| `--keymap MAP` | `NI_KEYMAP` | `us` | Console keymap and XKB layout |
| `--swap GB` | `NI_SWAP_GB` | `0` | Swap partition size in GiB, `0` = none |
| `--luks` / `--no-luks` | `NI_LUKS` | no | LUKS2-encrypt the root partition |
| `--luks-password PW` | `NI_LUKS_PASSWORD` | prompt (hidden) | |
| `--fs ext4\|btrfs` | `NI_FS` | `ext4` | btrfs uses `@`, `@home`, `@nix` subvolumes with zstd |
| `--terminal ghostty\|alacritty\|foot` | `NI_TERMINAL` | `ghostty` with rice, else `alacritty` | terminal installed for `Mod+T` |
| `--rice` / `--no-rice` | `NI_RICE` | on | apply the deep-space theme from [r3dg0d/dotfiles](https://github.com/r3dg0d/dotfiles) |
| `--github-user NAME` | `NI_GITHUB_USER` | `r3dg0d` | Whose public repos to clone |
| `--repos a,b,c` | `NI_REPOS` | all public non-fork repos | Explicit list instead of the GitHub API |
| `--no-repos` | `NI_CLONE_REPOS=no` | | Clone nothing |
| `--system-repos` / `--no-system-repos` | `NI_SYSTEM_REPOS` | on | First boot: run `post-install.sh` as root (system-wide packages) |
| `--build-repos` / `--no-build-repos` | `NI_BUILD_REPOS` | off | First boot: install flake packages into the user's Nix profile instead/as well |
| `--confirm-wipe DEV` | `NI_CONFIRM_WIPE` | | Unattended wipe confirmation; must equal `--disk` |
| `--defaults` | | | Use defaults for anything not given (disk, user, password still required) |
| `--dry-run` | | | Print the plan and the generated config; change nothing |

Fully unattended example:

```bash
sudo NI_PASSWORD='change-me' bash install.sh --disk /dev/nvme0n1 --confirm-wipe /dev/nvme0n1 \
  --user vincent --hostname zion --timezone America/Los_Angeles --fs btrfs --swap 16 --defaults
```

## What it does

1. **Preflight:** checks it is root on NixOS (the live ISO), that required tools exist, that
   `cache.nixos.org` is reachable, and whether the machine booted UEFI or BIOS.
2. **Partitions** the disk with GPT:
   - UEFI: 1 GiB ESP (`/boot`, vfat) → optional swap → root.
   - BIOS: 1 MiB BIOS boot → 1 GiB `/boot` (ext4) → optional swap → root.
   - With `--luks`, root is LUKS2 (`cryptroot`) and swap is re-encrypted with a random key each
     boot (no hibernation).
3. Formats, mounts and runs `nixos-generate-config --root /mnt`.
4. Writes `/etc/nixos/configuration.nix` (plain, no flake) with:
   - **niri** (`programs.niri.enable`), **SDDM** with Wayland enabled and niri as the default session
   - ghostty (with the rice; otherwise alacritty or foot), fuzzel, waybar, mako, xwayland-satellite, swaylock/swayidle/swaybg,
     wl-clipboard, grim/slurp, Firefox, xdg-desktop-portal-gtk, polkit, gnome-keyring
   - PipeWire (ALSA/Pulse/JACK), NetworkManager, Bluetooth, redistributable firmware, graphics
   - your user in `wheel`, with the password stored as a hash in
     `/etc/nixos/secrets/<user>.passwd` (mode 0600)
   - Nix flakes enabled, weekly garbage collection, `allowUnfree`
   - systemd-boot (UEFI) or GRUB (BIOS)
5. **Clones repos** into `/home/<user>/src/` using the unauthenticated GitHub API (paged, public,
   non-fork). A failed clone is logged and skipped.
6. Saves `post-install.sh` as `/etc/nixos/r3dg0d-post-install.sh` and adds a one-shot
   `r3dg0d-post-install.service`. On first boot, once the network is up, it runs as root and
   installs the repos system-wide (see below). It runs once; log `/var/log/r3dg0d-post-install.log`.
   With `--build-repos`, the older per-user mode is also set up: `~/src/install-repos.sh` and
   `r3dg0d-install-repos.service` install each flake's default package into your Nix profile.
7. Runs `nixos-install --no-root-passwd`, sets the user password, and saves the log to
   `/var/log/r3dg0d-installer.log` on the new system.

There is no root password; use `sudo` as your user. After boot, edit
`/etc/nixos/configuration.nix` and run `sudo nixos-rebuild switch`.

## Theme: deep-space

With `--rice` (default) the installer clones [r3dg0d/dotfiles](https://github.com/r3dg0d/dotfiles) to `/etc/nixos/r3dg0d-dotfiles`,
adds `./r3dg0d-rice.nix` to `configuration.nix` imports (packages, JetBrains Mono Nerd Font, the `deep-space` SDDM theme) and copies
the niri, ghostty, waybar, fuzzel, mako and fastfetch configs plus the wallpaper into the new user's home. `--no-rice` gives stock niri.

![SDDM deep-space](https://raw.githubusercontent.com/r3dg0d/dotfiles/main/previews/sddm.png)
![desktop mockup](https://raw.githubusercontent.com/r3dg0d/dotfiles/main/previews/desktop-mockup.png)

(The desktop image is a labeled mockup; the SDDM one is a real greeter render.)

## post-install.sh: repos system-wide

```bash
curl -fsSL https://raw.githubusercontent.com/r3dg0d/nixos-installer/main/post-install.sh | sudo bash
```

For every public non-fork repo of the GitHub user (or `--repos a,b,c`):

1. Clones it to `/opt/r3dg0d/src/<repo>`, or `git pull --ff-only` if it is already there.
2. Detects what it provides: flake `packages.<system>.default` (or every named package when there
   is no default), otherwise `package.nix` / `default.nix` via `callPackage`. `nixosModules` are
   reported but not enabled.
3. **Builds each package on its own.** A repo that fails to build is left out and logged, so one
   broken repo never breaks your system rebuild.
4. Writes `/etc/nixos/r3dg0d-repos.nix` listing only the packages that built, checks it evaluates,
   adds `./r3dg0d-repos.nix` to `imports` in `configuration.nix` (once; a backup is kept as
   `configuration.nix.bak-r3dg0d`) and runs `nixos-rebuild switch`.
5. Prints included / skipped / failed per repo. Log: `/var/log/r3dg0d-post-install.log`.

Re-run it any time to pull updates and rebuild. Options:

| Flag | Meaning |
|------|---------|
| `--repos a,b,c` | Only these repos |
| `--github-user NAME` | Default `r3dg0d`. Set `GITHUB_TOKEN` to avoid the 60 requests/hour API limit |
| `--include-all` | Also include `r3dg0d`, `r3dg0d.github.io`, `dotfiles`, `nixos-installer` (skipped by default) |
| `--src-dir DIR` | Clone location (default `/opt/r3dg0d/src`) |
| `--no-update` | Don't pull repos that already exist |
| `--no-switch` | Build and write the module, but don't edit `configuration.nix` or rebuild |

Notes: flake packages are pulled in with `builtins.getFlake "git+file:///opt/r3dg0d/src/<repo>"`,
so they use each repo's own pinned nixpkgs (`flake.lock`); `callPackage` repos use the system
channel. If `/etc/nixos` is itself a flake, the script writes the module and tells you to add it
to your `modules` and rebuild with `--impure`.

### Dotfiles from post-install.sh

`post-install.sh` also installs the rice (`--dotfiles`, default on; `--no-dotfiles` to skip):
clones or fast-forwards r3dg0d/dotfiles into `/etc/nixos/r3dg0d-dotfiles` (`--dotfiles-dir DIR`), writes `r3dg0d-rice.nix`,
checks that it evaluates, adds it to imports, runs `nixos-rebuild switch`, then runs the dotfiles `install.sh` as the user
(`--user NAME`; default is the first normal account with UID >= 1000). Changed files are backed up to
`~/.config/.dotfiles-backup/<timestamp>/`; unchanged files are skipped, so it is safe to re-run.

## niri basics

The first time niri starts it writes a default config to `~/.config/niri/config.kdl`.
`Mod+T` opens ghostty with the rice (stock niri config: alacritty; if you chose foot, change that bind), `Mod+D` opens fuzzel, `Mod+Shift+/` shows the hotkey overlay. Add
`spawn-at-startup "waybar"` and `spawn-at-startup "mako"` to that file for a bar and notifications.

## License

MIT, see [LICENSE](LICENSE).
