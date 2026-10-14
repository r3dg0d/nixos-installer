# nixos-installer

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
| `--terminal foot\|alacritty` | `NI_TERMINAL` | `foot` | |
| `--github-user NAME` | `NI_GITHUB_USER` | `r3dg0d` | Whose public repos to clone |
| `--repos a,b,c` | `NI_REPOS` | all public non-fork repos | Explicit list instead of the GitHub API |
| `--no-repos` | `NI_CLONE_REPOS=no` | | Clone nothing |
| `--build-repos` / `--no-build-repos` | `NI_BUILD_REPOS` | on | Install flake packages from the repos on first boot |
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
   - foot or alacritty, fuzzel, waybar, mako, xwayland-satellite, swaylock/swayidle/swaybg,
     wl-clipboard, grim/slurp, Firefox, xdg-desktop-portal-gtk, polkit, gnome-keyring
   - PipeWire (ALSA/Pulse/JACK), NetworkManager, Bluetooth, redistributable firmware, graphics
   - your user in `wheel`, with the password stored as a hash in
     `/etc/nixos/secrets/<user>.passwd` (mode 0600)
   - Nix flakes enabled, weekly garbage collection, `allowUnfree`
   - systemd-boot (UEFI) or GRUB (BIOS)
5. **Clones repos** into `/home/<user>/src/` using the unauthenticated GitHub API (paged, public,
   non-fork). A failed clone is logged and skipped.
6. Writes `~/src/install-repos.sh` and a one-shot `r3dg0d-install-repos.service`. On first boot,
   once the network is up, it runs as your user and installs the default package of every repo
   with a `flake.nix` into your Nix profile. Repos without packages are skipped and failures are
   logged to `~/src/install-repos.log` without stopping the rest. It runs once; re-run by hand
   with `~/src/install-repos.sh`.
7. Runs `nixos-install --no-root-passwd`, sets the user password, and saves the log to
   `/var/log/r3dg0d-installer.log` on the new system.

There is no root password; use `sudo` as your user. After boot, edit
`/etc/nixos/configuration.nix` and run `sudo nixos-rebuild switch`.

## niri basics

The first time niri starts it writes a default config to `~/.config/niri/config.kdl`.
`Mod+T` opens a terminal, `Mod+D` opens fuzzel, `Mod+Shift+/` shows the hotkey overlay. Add
`spawn-at-startup "waybar"` and `spawn-at-startup "mako"` to that file for a bar and notifications.

## License

MIT, see [LICENSE](LICENSE).
