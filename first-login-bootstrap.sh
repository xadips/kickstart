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

# Self-cleanup BEFORE the reboot prompt: if the user picks "yes", reboot
# kills the wrapping zsh before its post-bootstrap cleanup can run, leaving
# ~/.zshrc + this script orphaned (chezmoi's .zshenv sets ZDOTDIR after,
# so the stale ~/.zshrc is never read again). Doing it here is robust to
# either branch of the reboot prompt.
echo "==> Cleaning up bootstrap artifacts"
rm -f ~/.zshrc ~/.first-login-bootstrap.sh

echo
echo "==> Done. A reboot is recommended to pick up kernel modules, /etc"
echo "    overrides, mkinitcpio regen, and the proper getty autologin."
read -rp "Reboot now? [Y/n] " ans
case "${ans,,}" in
    n|no) echo "    Skipped — run 'sudo reboot' when ready." ;;
    *)    echo "    Rebooting..."; sudo systemctl reboot ;;
esac
