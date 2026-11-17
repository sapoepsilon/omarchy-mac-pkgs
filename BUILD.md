# Building the macOS VM stack (branch `macos-vm`)

This branch makes a fresh Omarchy Mac install able to come up as an [omvm](https://github.com/sapoepsilon/omvm) host. It is the owner's private fork; nothing here goes to omacom, and the kernel package never leaves the owner's machines (see Licence).

## What is on this branch

| Path | What |
| --- | --- |
| `omarchy-macos-vm/` | New package: the first-boot hook (`omarchy-macos-vm-setup.service`, per-user `omarchy-macos-vm-user.service`). Meets the package contract (`install`, `test/all`, README, LICENSE, version). |
| `omarchy-macos-vm/pkgbuilds/linux-aurora-vmapple/` | Side kernel: linux-aurora 7.2.11.aurora15 (omarchy-pkgs `73931c9b`) plus the PAC VM-key and NISV MMIO KVM patches (downloaded from aquarat/apple-macos-arm64-vm-guest `2ec3cb87` at build time). Own pkgbase, no `linux-asahi` provide, no headers package, ships `/usr/share/omarchy-mac-boot/side-kernels.d/linux-aurora-vmapple`. Same package and version omvm's `omvm kernel build` makes. |
| `omarchy-macos-vm/pkgbuilds/qemu-vmapple/` | steelbrain/qemu-reims-vgpu `1b41f5f5` + omvm's qemu 0001-0007 and usb 0001 (the owner's `qemu-sb-bdifw`), linked to reims-vgpu `1fe0acb6` + metal2vulkan `219f0136` with omvm's patches, in `/usr/lib/qemu-vmapple`. |
| `omarchy-macos-vm/pkgbuilds/mesa-honeykrisp-vmapple/` | Mesa 26.2.6 + aquarat's two 16-bit varying fixes + omvm's interlock patch, two ICDs (`headless/`, `wayland/`) in `/usr/lib/mesa-honeykrisp-vmapple`, never in `/usr/share/vulkan/icd.d`. |
| `omarchy-macos-vm/pkgbuilds/omvm/` | omvm at its `macos-vm` branch (`928f70c`), which finds the two packages above. |
| `omarchy-macos-vm/pkgbuilds/omarchy-macos-vm/` | The hook package, built from this checkout. |
| `omarchy-mac-boot/` | (1) Merges `m1n1-multiple-kernels` (m1n1's device trees come from linux-aurora's tree, not the newest one) and `fix/limine-cmdline-append`. (2) The boot check knows **side kernels**: a kernel package that declares itself in `/usr/share/omarchy-mac-boot/side-kernels.d/` may be running (checked as a pending reboot of the Apple kernel) or first in the Limine menu (its UKI must exist and the Apple kernel's entry must still be there; that entry is what gets checked). Undeclared second kernels fail as before. (3) First boot reads `macos_vm=1` from `install.conf` and writes `/etc/omarchy/macos-vm.enabled`. |

Why the boot check needed it: with a second kernel installed, `update-m1n1` built m1n1 with the side kernel's device trees whenever its module tree sorted newest (the check then refused `omarchy update`), a menu with the side kernel first failed "starts linux-aurora-vmapple first", and running the side kernel failed the non-update check. The first is the `m1n1-multiple-kernels` fix; the others are the side-kernel declaration.

## The contract with the installer (item c) and the image (item d)

- Installer: ticked box = a fourth line `macos_vm=1` in `omarchy/install.conf` on the Omarchy ESP (installer commit `c416c0c`). Unticked = the old three-line file.
- First boot (`omarchy-mac-boot`, this branch): `macos_vm=1` writes `/etc/omarchy/macos-vm.enabled` = `{"version":1,"requested_by":"installer"}`. Unknown values are logged and ignored; first boot never fails over them. The encrypt hook in the initramfs already ignores unknown keys.
- `omarchy-macos-vm-setup.service` starts on that file (see `omarchy-macos-vm/README.md`).

What the image (item d) must do to bake a payload with the stack:

1. Build the image with this branch's `omarchy-mac-boot` (the `platform_sources` mechanism in omarchy-mac-installer's image-builder takes `omarchy-mac-boot` from a commit of a platform repository; point it at `sapoepsilon/omarchy-mac-pkgs` `macos-vm`, or rebuild the package from it).
2. Install `omarchy-macos-vm` into `@` before the `@factory` seal and apply its preset (`80-omarchy-macos-vm.preset`), the way `--lab-access` writes its overlay. It is harmless without the marker.
3. Put the four stack packages in `/var/lib/omarchy/macos-vm/repo/` in `@` (or have the installer copy them to `omarchy/macos-vm/repo/` on the ESP). Without them the service looks in the configured repositories and fails, retrying every boot.
4. Such an image is **private**: it carries `linux-aurora-vmapple` and packages no Omarchy key signed, so the public inspection and `mac-release-guard` refuse it by design. Use a private/lab profile and never publish it.

## Build on the laptop (Omarchy, aarch64)

`ssh omarchy-ts`, booted into Omarchy. Builds take about 30-60 min (kernel), 15 min (QEMU), 10 min (Mesa).

```bash
git clone -b macos-vm https://github.com/sapoepsilon/omarchy-mac-pkgs ~/src/omarchy-mac-pkgs
cd ~/src/omarchy-mac-pkgs/omarchy-macos-vm/pkgbuilds
export PKGDEST=~/omarchy-macos-vm-repo/aarch64 SRCDEST=~/.cache/omarchy-macos-vm/sources
mkdir -p "$PKGDEST" "$SRCDEST"
sudo pacman -S --needed base-devel git rustup
rustup toolchain list | grep -q . || rustup default stable

(cd omarchy-macos-vm && makepkg -f)
(cd mesa-honeykrisp-vmapple && makepkg -sf --noconfirm)
(cd qemu-vmapple && makepkg -sf --noconfirm)
(cd omvm && makepkg -df)            # -d: its depends are the two packages just built
(cd linux-aurora-vmapple && OMARCHY_BUILD_JOBS=10 makepkg -sf --noconfirm)

repo-add "$PKGDEST/omarchy-macos-vm.db.tar.zst" "$PKGDEST"/*.pkg.tar.zst
```

Run the long kernel build in the background (`hc` or `nohup`), and check it every few minutes.

## Hosting the packages

- **Local repo on the laptop** (for updates): add to `/etc/pacman.conf`:
  ```
  [omarchy-macos-vm]
  SigLevel = Optional TrustAll
  Server = file:///home/<user>/omarchy-macos-vm-repo/$arch
  ```
  then `sudo pacman -Sy`. Rebuild and `repo-add` again to update.
- **In the payload**: copy `$PKGDEST/*.pkg.tar.zst` to `/var/lib/omarchy/macos-vm/repo/` in the image root, or to `omarchy/macos-vm/repo/` on the ESP. The setup service takes the newest archive of each package from there with `pacman -U`.
- **Over the tailnet**: serve `$PKGDEST` over HTTPS and put `"repo":"https://.../aarch64"` in the marker. Never on a public host.

## Test

In this repository (any Linux, or an Arch container): `omarchy-mac-boot/test/all` and `omarchy-macos-vm/test/all` (CI runs every package's suite).

On the laptop, which already runs omvm's own `linux-aurora-vmapple` (same name and version, so pacman replaces it in place):

```bash
cd ~/src/omarchy-mac-pkgs
# The boot check from this branch, against the live system (read-only):
sudo install -Dm644 /dev/null /usr/share/omarchy-mac-boot/side-kernels.d/linux-aurora-vmapple
sudo OMARCHY_BOOT_CHECK_ALLOW_PENDING_REBOOT=1 bash omarchy-mac-boot/bin/omarchy-apple-silicon-boot-check --boot-chain
# The packages:
sudo pacman -U "$PKGDEST"/{qemu-vmapple,mesa-honeykrisp-vmapple,omvm,linux-aurora-vmapple}-*.pkg.tar.zst
ldd /usr/lib/qemu-vmapple/qemu-system-aarch64 | grep reims
OMVM_QEMU=/usr/lib/qemu-vmapple/qemu-system-aarch64 /usr/bin/omvm doctor
# The hook, by hand (as first boot would after macos_vm=1):
sudo pacman -U "$PKGDEST"/omarchy-macos-vm-*.pkg.tar.zst
sudo install -d /var/lib/omarchy/macos-vm/repo && sudo cp "$PKGDEST"/*.pkg.tar.zst /var/lib/omarchy/macos-vm/repo/
echo '{"version":1,"requested_by":"manual"}' | sudo tee /etc/omarchy/macos-vm.enabled
sudo systemctl start omarchy-macos-vm-setup.service; journalctl -u omarchy-macos-vm-setup -b
cat /var/lib/omarchy/macos-vm/done /var/lib/omarchy/macos-vm/next-steps.txt
grep -n 'linux-aurora' /boot/efi/limine.conf     # linux-aurora first, linux-aurora-vmapple after it
```

`~/.local/bin/omvm` (the owner's checkout) comes before `/usr/bin/omvm` on `PATH`; call `/usr/bin/omvm` to test the package. Then boot "linux-aurora-vmapple" from Limine once and check `omvm doctor` reports the patched kernel and `omvm start macos` boots the existing VM on the packaged QEMU. The end-to-end test is a fresh install with the box ticked (items c and d).

## Licence

`linux-aurora-vmapple` applies steelbrain's PAC VM-key patch, which has no licence ([steelbrain#1](https://github.com/steelbrain/experiment-macOS-arm64-on-asahi-linux-arm64/issues/1)). The recipe downloads it at build time and this repository copies none of it, but the **built kernel package, any repository serving it and any image carrying it must stay private**. Everything else here is MIT or GPL-2.0-or-later and ships no Apple software.
