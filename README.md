# Face unlock for Omarchy

An [Omarchy](https://omarchy.org) lock screen plugin that unlocks with your face
through [Howdy](https://github.com/boltgolt/howdy), next to the stock password
and fingerprint flows.

It was created as a replacement for fingerprint unlock, which is not an option
for Omarchy on T2 MacBooks: the Touch ID sensor is tied to Apple's Secure
Enclave and has no Linux driver. Face unlock through the built-in camera gives
those machines a similarly convenient login and unlock. It works on any Omarchy
laptop with a webcam, though.

**This is convenience, not security.** A webcam face check can be fooled with a
photo. The setup deliberately leaves `sudo` and polkit on passwords and only
puts face unlock on the lock screen, plus optionally the SDDM login screen.

## How it behaves

- On lock, the camera looks for you once. On every wake of a blanked lock
  screen it looks again, up to three automatic attempts with a cooldown.
- The password field shows what is happening: "Looking for your face…",
  "No face found", and a face icon that pulses while the camera runs.
- Enter on the empty field retries face unlock. Typing a password works at any
  time and is checked immediately; it never waits for the camera.
- The display stays on while a scan runs and blanks afterwards as usual.
- After a resume from suspend it waits six seconds before the first scan, with
  a countdown in the field, so a camera that is still waking up does not eat
  the attempt.
- Optional: a lid-open binding lights the screen and scans once.

Everything runs inside the long-lived `omarchy-shell` process. Nothing loops
on the camera: an unattended lock screen keeps the camera and CPU idle.

## Install

```sh
git clone https://github.com/orkitec/omarchy-face-unlock.git
cd omarchy-face-unlock
./setup/install.sh            # add --sddm to also cover the login screen
```

The script builds `python-dlib` (CPU only) and `howdy-git` from the AUR, which
takes 10 to 20 minutes the first time, picks the first camera that delivers a
frame (override with `CAMERA=/dev/videoN`), enrolls your face, creates the PAM
service `/etc/pam.d/omarchy-lock-face`, and installs the plugin with
`omarchy plugin add`.

Add a face model for every lighting situation you regularly sit in; Howdy
matches against all of them:

```sh
sudo howdy add        # label it, e.g. "daylight" or "desk-lamp"
sudo howdy list
sudo howdy test       # live view with the match score
```

If matching is flaky in some light, raise `certainty` in
`/etc/howdy/config.ini` a little (3.5 to 4 makes it more lenient).

### Lid open

Omarchy binds the lid switch to its clamshell handler. Hyprland runs every
binding on a switch, so a second one can trigger a scan when the lid opens.
Add to `~/.config/hypr/bindings.lua`:

```lua
o.bind("switch:off:Lid Switch", nil, "omarchy-shell -q lock faceRetry", { locked = true })
```

### T2 MacBooks

The FaceTime camera on the T2 bridge (`t2bce_vhci`) can wedge the bridge when
it goes through USB runtime suspend after a lid-close sleep. When that happens
every camera open hangs and the internal keyboard and trackpad die with it,
until a reboot. A udev rule keeps the camera powered:

```sh
./t2-macbook/camera-no-autosuspend.sh
```

The camera also has no mmap support, so the installer switches Howdy to the
ffmpeg recorder when OpenCV cannot read frames.

## Dependencies

| Dependency | Source | Purpose |
|------------|--------|---------|
| [howdy-git](https://aur.archlinux.org/packages/howdy-git) | AUR, pinned to a reviewed commit in `setup/install.sh` | face recognition PAM module |
| [python-dlib](https://aur.archlinux.org/packages/python-dlib) | AUR, pinned likewise, built CPU-only | face detection library used by Howdy |
| python-opencv, ffmpeg, v4l-utils, boost, cmake, meson, ninja, jq | Arch repos | camera capture and build tools |

Building the AUR packages runs `makepkg` as your user and installs the result
with `sudo pacman`. The pinned commits are the PKGBUILD revisions that were
reviewed for this repository; bump them yourself after reading the diff.

## What the installer changes

All of it is shown on screen as it happens, and all of it needs your sudo
password:

- Installs the packages above.
- Edits `/etc/howdy/config.ini`: `device_path`, `timeout`, and
  `recording_plugin` when OpenCV cannot read the camera.
- Creates `/etc/pam.d/omarchy-lock-face` and, if a previous setup put
  `pam_howdy` into `/etc/pam.d/omarchy-lock-password`, removes it from there.
- With `--sddm`: prepends `pam_howdy` to `/etc/pam.d/sddm`.
- Installs the plugin through `omarchy plugin add`, which disables the stock
  lock screen while this one is enabled.

It does not touch `sudo`, polkit, your Hyprland config, or any other user
configuration. The optional lid binding is a line you add yourself.

## Uninstall

```sh
./setup/uninstall.sh
```

Removes the plugin, the PAM service, the SDDM line and the udev rule. Howdy and
the enrolled models stay; `sudo pacman -Rns howdy-git python-dlib` drops them.

## How it fits Omarchy

The plugin is a modified copy of Omarchy's first-party lock plugin
(`shell/plugins/lock`, Omarchy 4.0.2). Its manifest declares it as cloned from
`omarchy.lock`, which makes the shell swap it in for the built-in lock screen
and, on current Omarchy, grants it the authentication capability that lock
plugins need. Face unlock is a separate PAM service, so the password and
fingerprint stacks are untouched.

Being a fork, it does not follow upstream changes to the lock plugin on its
own. `omarchy-shell lock status` shows which version is loaded and whether face
unlock is configured. The plugin id is `com.orkitec.face-unlock`; disable it
with `omarchy plugin disable com.orkitec.face-unlock` to get the stock lock
screen back.

## Files

| Path | Purpose |
|------|---------|
| `manifest.json`, `Service.qml`, `LockView.qml` | the plugin |
| `setup/install.sh` | Howdy build, enrollment, PAM service, plugin install |
| `setup/uninstall.sh` | the reverse |
| `t2-macbook/` | camera autosuspend udev rule and installer |

## License

MIT. `Service.qml` and `LockView.qml` derive from Omarchy, also MIT, copyright
David Heinemeier Hansson.

---

Made by [Orkitec](https://github.com/orkitec).
