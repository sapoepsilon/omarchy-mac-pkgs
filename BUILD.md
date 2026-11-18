# Building the macOS VM stack (branch `macos-vm`)

This branch makes a fresh Omarchy Mac install able to come up as an [omvm](https://github.com/sapoepsilon/omvm) host. It is the owner's fork; nothing here goes to omacom.

## What is on this branch

| Path | What |
| --- | --- |
| `omarchy-macos-vm/` | New package: the first-boot hook (`omarchy-macos-vm-setup.service`, per-user `omarchy-macos-vm-user.service`). Meets the package contract (`install`, `test/all`, README, LICENSE, version). |
| `omarchy-macos-vm/pkgbuilds/linux-aurora-vmapple/` | Side kernel from the owner's fork `sapoepsilon/linux-aurora` branch `vmapple/kvm-macos-guest` (`5cff73a4`): linux-aurora integration/aurora `b798f2b` (7.2.11.aurora15, recipe files from omarchy-pkgs `73931c9b`) plus aquarat's two GPL-2.0 KVM commits (MMIO load/store without a syndrome; Apple PAuth state under VHE). Own pkgbase, no `linux-asahi` provide, no headers package, ships `/usr/share/omarchy-mac-boot/side-kernels.d/linux-aurora-vmapple`. Same name and version (7.2.11.aurora15vmapple-1) as the kernel the laptop runs. |
| `omarchy-macos-vm/pkgbuilds/qemu-vmapple/` | steelbrain/qemu-reims-vgpu `1b41f5f5` + omvm's qemu 0001-0007 and usb 0001, the same eight commits as the laptop's `qemu-fairplay-dev/src` branch `sb-kvm-bdif-write` (`760d1d0d`); the uncommitted FairPlay/identity work there and the `qemu-ofr2` lab build the VMs use now are left out, linked to reims-vgpu `1fe0acb6` + metal2vulkan `219f0136` with omvm's patches, in `/usr/lib/qemu-vmapple`. |
| `omarchy-macos-vm/pkgbuilds/mesa-honeykrisp-vmapple/` | Mesa 26.2.6 + `honeykrisp-vmapple.patch`, the exact diff of the laptop's `~/src/mesa-honeykrisp-sb` (aquarat's two 16-bit varying fixes + omvm's interlock patch; `asahi/16-bit-varyings` is the same two fixes on Mesa main, for the MR), two ICDs (`headless/`, `wayland/`) in `/usr/lib/mesa-honeykrisp-vmapple`, never in `/usr/share/vulkan/icd.d`. |
| `omarchy-macos-vm/pkgbuilds/omvm/` | The owner's `packaging/aur/PKGBUILD` from omvm `omarchy/must-fix`, built from omvm branch `macos-vm` (`7021c4d`, two commits on `omarchy/must-fix` `0a1484c`): it finds the two packages above, adds `omvm prepare`, ships the udmabuf tmpfiles.d, and lets `omvm ingest` use the read-only VMXFER mount the vmxfer service holds (no sudo). That branch is local (it carries unpushed commits); `OMVM_GIT` points makepkg at a clone. |
| omarchy-mac `macos-vm` | `omarchy-macos-vm install\|remove\|status` and the Install/Remove > macOS menu rows beside Windows run the same service on a running system. |
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
4. Such an image carries packages no Omarchy key signed, so the public inspection and `mac-release-guard` refuse it by design: build it with a private/lab profile.

## Build on the laptop (Omarchy, aarch64)

`ssh omarchy-ts`, booted into Omarchy. Builds take about 30-60 min (kernel), 15 min (QEMU), 10 min (Mesa). Everything stays in `~/Work/omarchy-macos-vm-build`; nothing is installed.

```bash
B=~/Work/omarchy-macos-vm-build; mkdir -p $B && cd $B
git clone -b macos-vm https://github.com/sapoepsilon/omarchy-mac-pkgs
git clone --no-checkout ~/Work/omvm omvm && git -C omvm fetch omvm-macos-vm.bundle macos-vm:macos-vm && git -C omvm checkout macos-vm
export PKGDEST=$B/repo SRCDEST=$B/sources BUILDDIR=$B/work LOGDEST=$B/logs OMVM_GIT=git+file://$B/omvm
mkdir -p $PKGDEST $SRCDEST $BUILDDIR $LOGDEST
cd omarchy-mac-pkgs/omarchy-macos-vm/pkgbuilds
(cd omarchy-macos-vm && makepkg -f)
(cd omvm && makepkg -fd)                      # -d: its depends are the two packages below
(cd mesa-honeykrisp-vmapple && makepkg -f)
(cd qemu-vmapple && makepkg -f)
(cd linux-aurora-vmapple && OMARCHY_BUILD_JOBS=10 makepkg -fC)   # -C: its prepare refuses a leftover build tree
repo-add $PKGDEST/omarchy-macos-vm.db.tar.zst $PKGDEST/*.pkg.tar.*
```

The laptop has every make dependency already (`pacman -T` lists none missing), so plain `makepkg` works; on a fresh Mac use `makepkg -s`. `$B/build.sh` runs the five builds in order and appends to `$B/progress`.

## Hosting the packages

- **Local repo on the laptop** (for updates): add to `/etc/pacman.conf`:
  ```
  [omarchy-macos-vm]
  SigLevel = Optional TrustAll
  Server = file:///home/<user>/omarchy-macos-vm-repo/$arch
  ```
  then `sudo pacman -Sy`. Rebuild and `repo-add` again to update.
- **In the payload**: copy `$PKGDEST/*.pkg.tar.zst` to `/var/lib/omarchy/macos-vm/repo/` in the image root, or to `omarchy/macos-vm/repo/` on the ESP. The setup service takes the newest archive of each package from there with `pacman -U`.
- **Over the tailnet**: serve `$PKGDEST` over HTTPS and put `"repo":"https://.../aarch64"` in the marker.

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
echo '{"version":1,"requested_by":"manual"}' | sudo tee /etc/omarchy/macos-vm.enabled   # or: omarchy-macos-vm install
sudo systemctl start omarchy-macos-vm-setup.service; journalctl -u omarchy-macos-vm-setup -b
cat /var/lib/omarchy/macos-vm/done /var/lib/omarchy/macos-vm/next-steps.txt
grep -n 'linux-aurora' /boot/efi/limine.conf     # linux-aurora first, linux-aurora-vmapple after it
```

`~/.local/bin/omvm` (the owner's checkout) comes before `/usr/bin/omvm` on `PATH`; call `/usr/bin/omvm` to test the package. Then boot "linux-aurora-vmapple" from Limine once and check `omvm doctor` reports the patched kernel and `omvm start macos` boots the existing VM on the packaged QEMU. The end-to-end test is a fresh install with the box ticked (items c and d).

## Licence

The kernel's two KVM commits are aquarat's and GPL-2.0: the PAuth one is an independent implementation (aquarat/apple-macos-arm64-vm-guest `15ea5eb`), and steelbrain released his original patches into the public domain on 2026-11-11 (steelbrain#1). Nothing on this branch is unlicensed any more; omvm's `LICENSING.md` and `docs/upstream-drafts.md` still describe the old blocker. Nothing ships Apple software. An image with these packages stays private only because they are not signed by the Omarchy key.
