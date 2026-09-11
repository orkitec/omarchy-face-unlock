#!/bin/bash
# Removes the lock plugin and the face PAM service. Keeps Howdy and your face
# models installed; remove those with: sudo pacman -Rns howdy-git python-dlib
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ID=$(jq -r .id "$HERE/../manifest.json")

sudo -v
omarchy plugin disable "$PLUGIN_ID" 2>/dev/null || true
rm -rf "$HOME/.config/omarchy/plugins/$PLUGIN_ID"
sudo rm -f /etc/pam.d/omarchy-lock-face
if grep -q pam_howdy.so /etc/pam.d/sddm 2>/dev/null; then
  sudo sed -i '/pam_howdy\.so/d; /omarchy-hw-laptop-closed/d' /etc/pam.d/sddm
fi
sudo rm -f /etc/udev/rules.d/60-facetime-camera-no-autosuspend.rules
omarchy-shell -q shell ping && echo "Plugin removed; the stock lock screen is active again." \
  || echo "Plugin removed; takes effect at next login."
