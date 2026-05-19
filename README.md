# kickstart

Arch Linux installer for [xadips/dotfiles](https://github.com/xadips/dotfiles).

## Usage

From an Arch live USB (UEFI mode, Secure Boot off):

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
