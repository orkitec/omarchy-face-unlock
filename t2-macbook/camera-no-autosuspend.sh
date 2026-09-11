#!/bin/bash
# Keeps the T2 MacBook FaceTime camera out of USB runtime autosuspend.
#
# After a lid-close suspend, the t2bce_vhci bridge can fail to complete a runtime
# suspend of the camera (power/runtime_status stuck at "suspending", kernel
# "Possible desync"). Every later camera open then hangs in the kernel, the
# camera LED stays on, and the internal keyboard and trackpad on the same
# bridge stop working until a reboot. Keeping the camera powered avoids that.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULE=/etc/udev/rules.d/60-facetime-camera-no-autosuspend.rules
# Plain loop, not a command substitution: with `set -e` a substitution whose
# last iteration fails to match would abort the script before it starts.
CAM=""
for d in /sys/bus/usb/devices/*; do
  [[ -f $d/product ]] && grep -q FaceTime "$d/product" && { CAM=$d; break; }
done

echo -e "\e[32m==> Sudo password needed to install the udev rule\e[0m"
sudo -v

sudo install -m 644 "$HERE/60-facetime-camera-no-autosuspend.rules" "$RULE"
sudo udevadm control --reload-rules
echo "Installed $RULE"

if [[ -n $CAM ]]; then
  echo "Applying to the running camera ($CAM) via a bind event..."
  sudo udevadm trigger --action=bind "$CAM"/*:1.0 2>/dev/null || true
  sleep 1
  if [[ $(cat "$CAM/power/control") != on ]]; then
    echo "Bind trigger did not apply, setting it directly for this boot."
    echo on | sudo tee "$CAM/power/control" >/dev/null
  fi
  echo "camera power/control = $(cat "$CAM/power/control"), runtime_status = $(cat "$CAM/power/runtime_status")"
else
  echo "Camera not found on the USB bus right now; the rule applies at next boot."
fi
