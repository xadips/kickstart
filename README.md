# kickstart

Arch Linux installer for [xadips/dotfiles](https://github.com/xadips/dotfiles).

## Usage

From an Arch live USB (UEFI mode, Secure Boot off), at the ISO boot menu press **`e`** to edit the boot entry and append one of these to the kernel cmdline so the live env has enough writable space:

- `cow_spacesize=4G` — explicit 4 GiB tmpfs overlay (works on any RAM)
- `copytoram=y` — copies the entire ISO to RAM and gives the rest of RAM as cowspace (faster but needs ≥16 GiB RAM)

Without one of these, the live env's default cowspace (~256-512 MiB) may run out during pacman operations.

After boot, connect to network (`iwctl` for WiFi or DHCP for ethernet), then:

```sh
bash <(curl -sL https://raw.githubusercontent.com/xadips/kickstart/main/kickstart.sh)
```

Interactive: prompts for hostname, user, password, RAID Y/N, target disks. Lays out ESP + swap + BTRFS root, pacstraps base + chezmoi/age/bitwarden-cli/jq, configures the user, and writes `~/.first-login-bootstrap.sh` to be run after first reboot.

## What it sets up

- BTRFS subvol layout: `@`, `@home`, `@snapshots`, `@var_log`
- GRUB on UEFI
- 16 GiB swap per disk (priority-based active in RAID)
- 200 MiB ESP
