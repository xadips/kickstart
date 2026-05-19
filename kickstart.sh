#!/bin/bash
#
# Arch Linux installation
#
# Bootable USB:
# - [Download](https://archlinux.org/download/) ISO and GPG files
# - Verify the ISO file: `$ pacman-key -v archlinux-<version>-dual.iso.sig`
# - Create a bootable USB with: `# dd if=archlinux*.iso of=/dev/sdX && sync`
#
# UEFI setup:
#
# - Set boot mode to UEFI, disable Legacy mode entirely.
# - Disable Secure Boot.
# - Set SATA operation to AHCI mode.
#
# Run installation:
#
# - Connect to wifi via: `# iwctl station wlan0 connect WIFI-NETWORK`
# - Run: `# bash <(curl -sL https://raw.githubusercontent.com/xadips/kickstart/main/kickstart.sh)`

set -uo pipefail
trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

exec 1> >(tee "stdout.log")
exec 2> >(tee "stderr.log" >&2)

export SNAP_PAC_SKIP=y

# Swap size per disk (GiB). With RAID, both disks get a swap of this size and
# fstab activates them with different priorities — primary preferred.
SWAP_SIZE_GB=16

# Dialog
BACKTITLE="Arch Linux installation"

get_input() {
    title="$1"
    description="$2"

    input=$(dialog --clear --stdout --backtitle "$BACKTITLE" --title "$title" --inputbox "$description" 0 0)
    echo "$input"
}

get_password() {
    title="$1"
    description="$2"

    init_pass=$(dialog --clear --stdout --backtitle "$BACKTITLE" --title "$title" --passwordbox "$description" 0 0)
    : ${init_pass:?"password cannot be empty"}

    test_pass=$(dialog --clear --stdout --backtitle "$BACKTITLE" --title "$title" --passwordbox "$description again" 0 0)
    if [[ "$init_pass" != "$test_pass" ]]; then
        echo "Passwords did not match" >&2
        exit 1
    fi
    echo $init_pass
}

get_choice() {
    title="$1"
    description="$2"
    shift 2
    options=("$@")
    dialog --clear --stdout --backtitle "$BACKTITLE" --title "$title" --menu "$description" 0 0 0 "${options[@]}"
}

echo -e "\n### Ensuring live env has enough writable space (resize cowspace tmpfs)"
mount -o remount,size=4G /run/archiso/cowspace 2>/dev/null || true

echo -e "\n### Loading kernel modules needed during install (vfat for ESP, btrfs)"
modprobe vfat fat nls_cp437 nls_iso8859-1 2>/dev/null || true
modprobe btrfs 2>/dev/null || true

echo -e "\n### Starting pacman-init just in case"
systemctl start pacman-init.service

echo -e "\n### Checking UEFI boot mode"
if [ ! -f /sys/firmware/efi/fw_platform_size ]; then
    echo >&2 "You must boot in UEFI mode to continue"
    exit 2
fi

echo -e "\n### Setting up clock"
timedatectl set-ntp true
hwclock --systohc --utc
echo -e "\n### Setting mirrors"
reflector -c Lithuania,Latvia,Poland -a 6 --sort rate --save /etc/pacman.d/mirrorlist

echo -e "\n### Refreshing pacman repos"
pacman -Sy --noconfirm
# dialog + terminus-font are what the kickstart itself uses (TUI + setfont).
# git/wget aren't used here — they're installed into the target via pacstrap.
# Pulling them into the live env triggered nettle/gnutls SONAME conflicts.
for pkg in dialog terminus-font; do
    pacman -Qi "$pkg" >/dev/null 2>&1 || pacman -S --noconfirm "$pkg"
done

hostname=$(get_input "Hostname" "Enter hostname") || exit 1
clear
: ${hostname:?"hostname cannot be empty"}

user=$(get_input "User" "Enter username") || exit 1
clear
: ${user:?"user cannot be empty"}

password=$(get_password "User" "Enter password") || exit 1
clear
: ${password:?"password cannot be empty"}

noyes=("Yes" "The System is RAID1" "No" "Single drive setup")
raid=$(get_choice "Drive status" "Do you want RAID1 for 2 drives?" "${noyes[@]}") || exit 1

devicelist=$(lsblk -dplnx size -o name,size | grep -Ev "boot|rpmb|loop" | tac | tr '\n' ' ')
read -r -a devicelist <<<$devicelist

fdevice=$(get_choice "Installation" "Select first drive" "${devicelist[@]}") || exit 1
[[ "$raid" == "Yes" ]] && sdevice=$(get_choice "Installation" "Select second drive" "${devicelist[@]}") || exit 1

clear

clear
font="ter-716n"
setfont "$font"

echo -e "\n### Setting up partitions"
umount -R /mnt 2>/dev/null || true

lsblk -plnx size -o name "${fdevice}" | xargs -n1 wipefs --all
[[ "$raid" == "Yes" ]] && lsblk -plnx size -o name "${sdevice}" | xargs -n1 wipefs --all
sgdisk --clear "${fdevice}" \
    --new 1:0:+200Mib --typecode 1:ef00 \
    --new 2:0:+${SWAP_SIZE_GB}G --typecode 2:8200 \
    --new 3:0:0 --typecode 3:8300 \
    "${fdevice}"
sgdisk --change-name=1:ESP --change-name=2:swap --change-name=3:primary "${fdevice}"
if [[ "$raid" == "Yes" ]]; then
    sgdisk --clear "${sdevice}" \
        --new 1:0:+200Mib --typecode 1:ef00 \
        --new 2:0:+${SWAP_SIZE_GB}G --typecode 2:8200 \
        --new 3:0:0 --typecode 3:8300 \
        "${sdevice}"
    sgdisk --change-name=1:ESP --change-name=2:swap --change-name=3:primary "${sdevice}"
fi

fpart_boot="$(ls ${fdevice}* | grep -E "^${fdevice}p?1$")"
fpart_swap="$(ls ${fdevice}* | grep -E "^${fdevice}p?2$")"
fpart_root="$(ls ${fdevice}* | grep -E "^${fdevice}p?3$")"

[[ "$raid" == "Yes" ]] && spart_boot="$(ls ${sdevice}* | grep -E "^${sdevice}p?1$")"
[[ "$raid" == "Yes" ]] && spart_swap="$(ls ${sdevice}* | grep -E "^${sdevice}p?2$")"
[[ "$raid" == "Yes" ]] && spart_root="$(ls ${sdevice}* | grep -E "^${sdevice}p?3$")"

echo -e "\n### Formatting partitions"
mkfs.vfat -n "EFI" -F 32 "${fpart_boot}"
mkswap -L swap1 "${fpart_swap}"
if [[ "$raid" == "Yes" ]]; then
    mkfs.vfat -n "EFI" -F 32 "${spart_boot}"
    mkswap -L swap2 "${spart_swap}"
fi

[[ "$raid" == "Yes" ]] && mkfs.btrfs -L btrfs -m raid1 -d raid1 $fpart_root $spart_root -f || mkfs.btrfs -L btrfs -m single -d single "${fpart_root}" -f

echo -e "\n### Setting up BTRFS subvolumes"
mount "${fpart_root}" /mnt
btrfs su cr /mnt/@
btrfs su cr /mnt/@home
btrfs su cr /mnt/@snapshots
btrfs su cr /mnt/@var_log
umount /mnt

mount -o noatime,compress-force=zstd,space_cache=v2,subvol=@ "${fpart_root}" /mnt
mkdir -p /mnt/{boot/efi,home,.snapshots,var/log}

mount -o noatime,compress-force=zstd,space_cache=v2,subvol=@home "${fpart_root}" /mnt/home
mount -o noatime,compress-force=zstd,space_cache=v2,subvol=@snapshots "${fpart_root}" /mnt/.snapshots
mount -o noatime,compress-force=zstd,space_cache=v2,subvol=@var_log "${fpart_root}" /mnt/var/log
mount "${fpart_boot}" /mnt/boot/efi

echo -e "\n### Installing packages"
pacstrap /mnt base linux-zen linux-zen-headers linux-firmware neovim amd-ucode grub grub-btrfs efibootmgr networkmanager dialog wpa_supplicant mtools dosfstools git reflector bluez bluez-utils cups btrfs-progs base-devel openssh zsh inotify-tools chezmoi age bitwarden-cli jq terminus-font

echo "FONT=$font" >/mnt/etc/vconsole.conf
genfstab -L /mnt >>/mnt/etc/fstab
{
    echo ""
    echo "# Swap (RAID setups use both with different priorities)"
    echo "UUID=$(blkid -s UUID -o value ${fpart_swap}) none swap sw,pri=10 0 0"
    [[ "$raid" == "Yes" ]] && echo "UUID=$(blkid -s UUID -o value ${spart_swap}) none swap sw,pri=5 0 0"
} >>/mnt/etc/fstab
echo "${hostname}" >/mnt/etc/hostname
echo "en_US.UTF-8 UTF-8" >>/mnt/etc/locale.gen
echo "en_GB.UTF-8 UTF-8" >>/mnt/etc/locale.gen
ln -sf /usr/share/zoneinfo/Europe/Vilnius /mnt/etc/localtime
arch-chroot /mnt locale-gen

echo -e "\n### Setting up initramfs and boot"
cat <<EOF >/mnt/etc/mkinitcpio.conf
MODULES=(btrfs)
BINARIES=(setfont)
FILES=()
HOOKS=(base udev consolefont autodetect microcode kms modconf keyboard block grub-btrfs-overlayfs)
COMPRESSION_OPTIONS=(-v -5 --long)
EOF
arch-chroot /mnt mkinitcpio -p linux-zen
arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
[[ "$raid" == "Yes" ]] && dd if="${fpart_boot}" of="${spart_boot}" && arch-chroot /mnt efibootmgr --create --disk "${sdevice}" --part 1 -w --label GRUB2 --loader '\EFI\GRUB\grubx64.efi'

echo -e "\n### Creating user"
arch-chroot /mnt useradd -mG wheel,network,video,input -s /usr/bin/zsh "$user"
arch-chroot /mnt chsh -s /usr/bin/zsh
echo "$user:$password" | arch-chroot /mnt chpasswd
echo "$user ALL=(ALL) ALL" | arch-chroot /mnt bash -c "EDITOR='tee -a' visudo"
echo "Defaults passwd_timeout=60,timestamp_timeout=60" | arch-chroot /mnt bash -c "EDITOR='tee -a' visudo"
echo "Defaults !tty_tickets" | arch-chroot /mnt bash -c "EDITOR='tee -a' visudo"
echo "Defaults pwfeedback" | arch-chroot /mnt bash -c "EDITOR='tee -a' visudo"
arch-chroot /mnt systemctl enable NetworkManager
arch-chroot /mnt systemctl enable NetworkManager-wait-online.service

if [ "${user}" = "spidax" ]; then
    echo -e "\n### Writing first-login chezmoi bootstrap script"
    arch-chroot /mnt sudo -u "$user" bash <<'INNER'
        cat > ~/.first-login-bootstrap.sh <<'EOF'
#!/usr/bin/env bash
# One-shot bootstrap: Bitwarden → age key + SSH key → chezmoi init --apply.
# Idempotent: safe to re-run. Prereqs: Bitwarden master password.
set -e

# Vault URL prompted at runtime — never embedded.
AGE_ITEM_ID="78a62650-872e-46f0-8eb0-4af640b552d5"
SSH_RSA_ITEM="fa174e56-4506-4d60-8c70-88d363c7020a"   # the key registered on GitHub
REPO="git@github.com:xadips/dotfiles.git"

echo "==> Bitwarden login (interactive — needs email + master password + 2FA)"
read -rp "Bitwarden vault server URL: " SERVER
[ -z "$SERVER" ] && { echo "Empty vault URL — aborting"; exit 1; }

bw config server "$SERVER" >/dev/null
status=$(bw status 2>/dev/null | jq -r .status 2>/dev/null || echo unauthenticated)
case "$status" in
    unauthenticated) export BW_SESSION=$(bw login --raw) ;;   # login + unlock in one prompt
    locked)          export BW_SESSION=$(bw unlock --raw) ;;
    unlocked)        : ;;                                     # already unlocked (BW_SESSION pre-set)
esac
[ -n "${BW_SESSION:-}" ] || { echo "Bitwarden auth failed"; exit 1; }

echo "==> Restoring age private key"
mkdir -p ~/.config/chezmoi
bw get attachment key.txt --itemid "$AGE_ITEM_ID" --output ~/.config/chezmoi/key.txt
chmod 600 ~/.config/chezmoi/key.txt

echo "==> Restoring SSH key for GitHub auth (id_rsa — others populated by chezmoi templates)"
mkdir -p ~/.ssh; chmod 700 ~/.ssh
bw get item "$SSH_RSA_ITEM" | jq -r '.sshKey.privateKey' > ~/.ssh/id_rsa
bw get item "$SSH_RSA_ITEM" | jq -r '.sshKey.publicKey'  > ~/.ssh/id_rsa.pub
chmod 600 ~/.ssh/id_rsa
chmod 644 ~/.ssh/id_rsa.pub

echo "==> Trusting github.com host key"
ssh-keyscan -t ed25519,rsa github.com 2>/dev/null >> ~/.ssh/known_hosts
sort -u -o ~/.ssh/known_hosts ~/.ssh/known_hosts

echo "==> chezmoi init --apply"
chezmoi init --apply "$REPO"

echo
echo "==> Done. Reboot or relog to enter your hyprland session."
echo "    You may now delete: rm ~/.first-login-bootstrap.sh"
EOF
        chmod +x ~/.first-login-bootstrap.sh
        touch ~/.zshrc
        cat >> ~/.zshrc <<'EOF'

# First-login bootstrap reminder (delete the script after chezmoi init succeeds)
if [ -x ~/.first-login-bootstrap.sh ]; then
    echo
    echo "==> Run ~/.first-login-bootstrap.sh to clone dotfiles + restore secrets."
    echo
fi
EOF
INNER

    echo -e "\n### After reboot: log in as ${user}, run ~/.first-login-bootstrap.sh"
fi

umount -R /mnt
echo -e "\n### DONE - You can reboot now"

noyes=("Yes" "Reboot" "No" "Do not reboot")
rebootask=$(get_choice "Reboot" "Do you want to continue?" "${noyes[@]}") || exit 1

[[ "$rebootask" == "Yes" ]] && reboot
