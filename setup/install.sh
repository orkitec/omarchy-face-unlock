#!/bin/bash
#
# Face unlock for Omarchy: builds Howdy, enrolls your face, creates the PAM
# service the lock plugin uses, and installs the plugin.
#
#   ./setup/install.sh            everything
#   ./setup/install.sh --sddm     also put face unlock on the SDDM login screen
#
# Safe to re-run: every step is skipped when already done. Nothing here touches
# sudo or polkit; face unlock is convenience for the lock screen, not security.
#
# Environment:
#   CAMERA=/dev/videoN   camera to use (default: first /dev/video* that captures)
#   TIMEOUT=3            seconds Howdy searches per scan
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
BUILD="${BUILD:-$HOME/.cache/omarchy-face-unlock-build}"
CONF=/etc/howdy/config.ini
FACE_PAM=/etc/pam.d/omarchy-lock-face
PLUGIN_ID=$(jq -r .id "$REPO/manifest.json")
TIMEOUT=${TIMEOUT:-3}
WITH_SDDM=0
GATE='auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed'
HOWDY='auth      sufficient pam_howdy.so'

for arg in "$@"; do
  case $arg in
    --sddm) WITH_SDDM=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

step() { echo -e "\n\e[32m==> $*\e[0m"; }
warn() { echo -e "\e[33m$*\e[0m"; }

step "Sudo password needed for package installs and PAM changes"
sudo -v
( while true; do sleep 50; sudo -n true 2>/dev/null || exit; done ) &
KEEPALIVE=$!
trap 'kill $KEEPALIVE 2>/dev/null || true' EXIT

step "Installing build dependencies from the Arch repos"
sudo pacman -S --needed --noconfirm base-devel git boost cmake meson ninja \
  python-opencv python-setuptools sqlite v4l-utils ffmpeg jq

export MAKEFLAGS="-j$(nproc)"
mkdir -p "$BUILD"

aur_build() {
  local pkg=$1
  if pacman -Q "$pkg" &>/dev/null; then
    echo "$pkg already installed"
    return
  fi
  if [[ -d $BUILD/$pkg/.git ]]; then
    git -C "$BUILD/$pkg" pull -q
  else
    git clone -q "https://aur.archlinux.org/$pkg.git" "$BUILD/$pkg"
  fi
  if [[ $pkg == python-dlib ]]; then
    # The AUR PKGBUILD defaults to a CUDA build, which drags in the whole
    # CUDA toolkit. Face unlock is fine on the CPU.
    sed -i 's/^_build_cuda=1/_build_cuda=0/' "$BUILD/$pkg/PKGBUILD"
  fi
  (cd "$BUILD/$pkg" && makepkg -si --noconfirm --needed)
}

step "Building python-dlib (CPU only; 10-20 minutes the first time)"
aur_build python-dlib

step "Building howdy-git (native PAM module)"
aur_build howdy-git

step "Choosing a camera"
CAM=${CAMERA:-}
if [[ -z $CAM ]]; then
  for dev in /dev/video*; do
    if python -c "import cv2,sys; c=cv2.VideoCapture('$dev', cv2.CAP_V4L2); ok,_=c.read(); sys.exit(0 if ok else 1)" 2>/dev/null \
      || ffmpeg -v error -f v4l2 -i "$dev" -frames:v 1 -f null - 2>/dev/null; then
      CAM=$dev; break
    fi
  done
fi
[[ -n $CAM ]] || { warn "No camera delivered a frame. Set CAMERA=/dev/videoN and re-run."; exit 1; }
echo "Using $CAM"
sudo sed -i -E "s|^device_path ?=.*|device_path = $CAM|" "$CONF"
sudo sed -i -E "s|^timeout ?=.*|timeout = $TIMEOUT|" "$CONF"
if python -c "import cv2,sys; c=cv2.VideoCapture('$CAM', cv2.CAP_V4L2); ok,_=c.read(); sys.exit(0 if ok else 1)" 2>/dev/null; then
  echo "OpenCV reads $CAM, keeping the opencv recorder."
else
  warn "OpenCV cannot read $CAM (no mmap support, typical for the T2 FaceTime camera); using the ffmpeg recorder."
  sudo sed -i -E 's|^recording_plugin ?=.*|recording_plugin = ffmpeg|' "$CONF"
fi
grep -E "^(device_path|recording_plugin|timeout|certainty|dark_threshold) ?=" "$CONF"

step "Enrolling your face"
if sudo howdy list 2>/dev/null | grep -qE '^\s*[0-9]+'; then
  echo "Face models already enrolled:"
  sudo howdy list
  echo "Add more with 'sudo howdy add', one per lighting situation you sit in."
else
  echo "Look straight at the camera. Good light on your face helps a lot."
  sudo howdy add
fi

step "Creating the PAM service the lock plugin uses ($FACE_PAM)"
sudo tee "$FACE_PAM" >/dev/null <<'PAM'
#%PAM-1.0
auth       required                    pam_howdy.so
account    include                     system-local-login
PAM
cat "$FACE_PAM"
# The plugin checks the password immediately; pam_howdy must not sit in the
# password stack or every typed password would wait for a camera scan first.
if grep -q pam_howdy.so /etc/pam.d/omarchy-lock-password 2>/dev/null; then
  warn "Removing pam_howdy from /etc/pam.d/omarchy-lock-password (the plugin runs it separately)"
  sudo sed -i '/pam_howdy\.so/d; /omarchy-hw-laptop-closed/d' /etc/pam.d/omarchy-lock-password
fi

if (( WITH_SDDM )); then
  step "Wiring pam_howdy into the SDDM login screen"
  if ! grep -q pam_howdy.so /etc/pam.d/sddm; then
    sudo sed -i "1i $HOWDY" /etc/pam.d/sddm
    sudo sed -i "/pam_howdy\.so/i $GATE" /etc/pam.d/sddm
  fi
  grep -n pam_howdy /etc/pam.d/sddm
fi

step "Installing the lock plugin"
if omarchy-plugin-list --json | jq -e --arg id "$PLUGIN_ID" 'any(.[]; .id == $id)' >/dev/null; then
  echo "$PLUGIN_ID already installed"
  omarchy plugin enable "$PLUGIN_ID" 2>/dev/null || true
else
  omarchy plugin add "$REPO" --yes --enable
fi
omarchy-shell -q shell ping || warn "omarchy-shell is not running; the plugin loads at next login"

kill $KEEPALIVE 2>/dev/null || true
echo -e "\n\e[32mFace unlock is set up.\e[0m"
echo "Lock the screen: it looks for your face on lock and again on each wake."
echo "Enter on the empty field retries; typing a password works at any time."
echo "Optional lid-open scan: see README, section 'Lid open'."
echo
read -r -p "Press Enter to lock the screen and try it (Ctrl+C to skip)... "
omarchy system lock
