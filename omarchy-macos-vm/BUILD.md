# Building the macOS VM stack (branch `macos-vm`)

This branch makes a fresh Omarchy Mac install able to come up as an [omvm](https://github.com/sapoepsilon/omvm) host. It is the owner's fork; nothing here goes to omacom.

## What is on this branch

| Path | What |
| --- | --- |
| `omarchy-macos-vm/` | New package: the first-boot hook (`omarchy-macos-vm-setup.service`, per-user `omarchy-macos-vm-user.service`). Meets the package contract (`install`, `test/all`, README, LICENSE, version). |
| `omarchy-macos-vm/pkgbuilds/linux-aurora-vmapple/` | Side kernel from the owner's fork `sapoepsilon/linux-aurora` branch `vmapple/kvm-macos-guest`, pinned to commit `f874ff3f`: linux-aurora integration/aurora `b798f2b` (7.2.11.aurora15, recipe files from omarchy-pkgs `73931c9b`, pinned by commit and sha256) plus four GPL-2.0 KVM commits, aquarat's `ac4f53c7` (MMIO load/store without a syndrome) and `5cff73a4` (Apple PAuth state under VHE), and the owner's `9ee27354` (deferred NISV MMIO writeback, respecting `KVM_CAP_ARM_NISV_TO_USER`) and `f874ff3f` (its `mmio_nisv_wb` selftest fix). The two newest are not on the public fork yet. The private bindgen's source archive (0.73.2) is a sha256-pinned source too. Own pkgbase, no `linux-asahi` provide, no headers package, ships `/usr/share/omarchy-mac-boot/side-kernels.d/linux-aurora-vmapple`. Version 7.2.11.aurora15vmapple-2: the same name as the -1 build the laptop runs, so pacman upgrades it in place, and the new pkgrel makes the kernel release `7.2.11-15vmapple-2-ARCH`, which omvm `c633dde5`'s Apple-services provider check (`share/apple-helpers.py`) does not accept yet; the basic tier does not use it. It gets its own UKI and Limine entry beside stock `linux-aurora`; with the macOS VM stack enabled the hook makes it the persistent default (`omarchy-macos-vm-boot-default enable`, recorded in `/etc/omarchy-mac-boot/default-side-kernel` and kept across kernel updates) and keeps stock `linux-aurora` selectable for recovery; `omarchy-macos-vm remove` restores the stock default. |
| `omarchy-macos-vm/pkgbuilds/qemu-vmapple/` | steelbrain/qemu-reims-vgpu `1b41f5f5` + omvm's qemu 0001-0007 and usb 0001, taken from omvm `c633dde5` (`patches/` is unchanged since `e75eff0`), the same eight commits as the laptop's `qemu-fairplay-dev/src` branch `sb-kvm-bdif-write` (`760d1d0d`); the uncommitted FairPlay/identity work there and the `qemu-ofr2` lab build the VMs use now are left out, linked to reims-vgpu `1fe0acb6` + metal2vulkan `219f0136` with omvm's patches, in `/usr/lib/qemu-vmapple`. `git am --committer-date-is-author-date` with a fixed committer gives the patched trees the same heads on every build. The three meson wraps configure resolves (keycodemapdb, berkeley-softfloat-3, berkeley-testfloat-3) are sources pinned to the revisions in qemu's `subprojects/*.wrap`, and `--disable-download` fails on any other. reims-vgpu is built with `-C target-cpu=apple-m1`, the M1/M2 floor, which has the LSE and RCpc its inline assembly needs, instead of the build host's `native`. `--with-pkgversion` fixes the version string to `qemu-vmapple 10.1.50.r1b41f5f5-4`, so `git describe` of the patched head stays out of it. |
| `omarchy-macos-vm/pkgbuilds/mesa-honeykrisp-vmapple/` | Mesa 26.2.6, pinned to commit `8e87a503` (what tag `mesa-26.2.6` names), built with `--wrap-mode=nodownload` so every dependency comes from the system, + `honeykrisp-vmapple.patch`, the exact diff of the laptop's `~/src/mesa-honeykrisp-sb` (aquarat's two 16-bit varying fixes + omvm's interlock patch; `asahi/16-bit-varyings` is the same two fixes on Mesa main, for the MR), two ICDs (`headless/`, `wayland/`) in `/usr/lib/mesa-honeykrisp-vmapple`, never in `/usr/share/vulkan/icd.d`. |
| `omarchy-macos-vm/pkgbuilds/omvm/` | The owner's `packaging/aur/PKGBUILD` from omvm `omarchy/must-fix`, built from omvm commit `c633dde5` (`macos-vm` `947787d5` plus four commits ending in the basic-tier VM profile, OMA-7; not on sapoepsilon/omvm yet): it finds the two packages above, adds `omvm prepare`, ships the udmabuf tmpfiles.d, lets `omvm ingest` use the read-only VMXFER mount the vmxfer service holds (no sudo), hands upstream's headless launchers (`omvm setup`, `run`, `start`) the packaged QEMU, and (`22abc8d`) logs the guest account in automatically with the password in `guest-password`, skipping the post-login Setup Assistant panes. The version is static, `0.1.0.r200.c633dde` (commits up to `c633dde5` and its 7-character hash, counted once on a full clone), and prepare() fails unless the checkout is that commit. `OMVM_GIT` can point makepkg at another clone of the same commit. |
| omarchy-mac `macos-vm` | `omarchy-macos-vm install\|remove\|status` and the Install/Remove > macOS menu rows beside Windows run the same service on a running system. |
| `omarchy-macos-vm/pkgbuilds/omarchy-macos-vm/` | The hook package, built from omarchy-mac-pkgs commit `1d52a266`, which holds every file it installs. A commit cannot name its own hash, so the pin trails the recipe by one commit and moves whenever the hook's files change. `OMARCHY_MAC_PKGS_GIT` can point makepkg at another clone of the same commit. |
| `omarchy-mac-boot/` | (1) Merges `m1n1-multiple-kernels` (m1n1's device trees come from linux-aurora's tree, not the newest one) and `fix/limine-cmdline-append`. (2) The boot check knows **side kernels**: a kernel package that declares itself in `/usr/share/omarchy-mac-boot/side-kernels.d/` may be running (checked as a pending reboot of the Apple kernel) or first in the Limine menu (its UKI must exist and the Apple kernel's entry must still be there; that entry is what gets checked). Undeclared second kernels fail as before. (3) First boot reads `macos_vm=1` from `install.conf` and writes `/etc/omarchy/macos-vm.enabled`, with the installer's macOS account from `omarchy/macos-vm-credentials` (then 0600; the ESP file is deleted). |

Why the boot check needed it: with a second kernel installed, `update-m1n1` built m1n1 with the side kernel's device trees whenever its module tree sorted newest (the check then refused `omarchy update`), a menu with the side kernel first failed "starts linux-aurora-vmapple first", and running the side kernel failed the non-update check. The first is the `m1n1-multiple-kernels` fix; the others are the side-kernel declaration.

## The contract with the installer (item c) and the image (item d)

- Installer: ticked box = a fourth line `macos_vm=1` in `omarchy/install.conf` on the Omarchy ESP (installer commit `c416c0c`). Unticked = the old three-line file.
- First boot (`omarchy-mac-boot`, this branch): `macos_vm=1` writes `/etc/omarchy/macos-vm.enabled` = `{"version":1,"requested_by":"installer"}`. Unknown values are logged and ignored; first boot never fails over them. The encrypt hook in the initramfs already ignores unknown keys.
- The macOS account (installer branch `dev/macos-vm-credentials`): with the box ticked the installer also writes `omarchy/macos-vm-credentials` on the ESP, `macos_vm_user=` and `macos_vm_password=` (defaults: the Omarchy username, `macos`). Not in `install.conf`, which the initramfs reads and first boot keeps 0644 on the root; FAT has no per-file permissions, so the password gets its own short-lived file. First boot validates it (username `^[a-z_][a-z0-9_-]{0,30}$`, password 1-64 printable ASCII without `'`), adds `"guest_user"`/`"guest_password"` to the marker, writes the marker 0600, and deletes the ESP file (also when `macos_vm` is not 1, or the file is invalid, in which case the marker has no account and the defaults apply). `omarchy-macos-vm-credentials` (run by the setup and every boot by the vmxfer service) moves them to the owner's `~/.config/omarchy/macos-vm-credentials` (0600) and drops the password from the marker (0644 again).
- `omarchy-macos-vm-setup.service` starts on that file (see [README.md](README.md)).

What the image (item d) must do to bake a payload with the stack:

1. Build the image with this branch's `omarchy-mac-boot` (the `platform_sources` mechanism in omarchy-mac-installer's image-builder takes `omarchy-mac-boot` from a commit of a platform repository; point it at `sapoepsilon/omarchy-mac-pkgs` `macos-vm`, or rebuild the package from it).
2. Install `omarchy-macos-vm` into `@` before the `@factory` seal and apply its preset (`80-omarchy-macos-vm.preset`), the way `--lab-access` writes its overlay. It is harmless without the marker.
3. Put the four stack packages in `/var/lib/omarchy/macos-vm/repo/` in `@` (or have the installer copy them to `omarchy/macos-vm/repo/` on the ESP). Without them the service looks in the configured repositories and fails, retrying every boot.
4. Such an image carries packages no Omarchy key signed, so the public inspection and `mac-release-guard` refuse it by design: build it with a private/lab profile.

## Build in a clean chroot (aarch64)

Every package is built on an aarch64 Arch Linux ARM host (the runner, an M1 Max) in a clean chroot, never against the host's installed packages. Builds take about 30-60 min (kernel), 15 min (QEMU), 10 min (Mesa).

- **Chroot**: a minimal ALARM root with `base-devel` and the five recipes' make dependencies, from `core`, `extra` and `alarm` only (no `[omarchy]` or `[asahi-alarm]`), `SigLevel = Required DatabaseOptional`, and its own keyring populated with `archlinuxarm` only. pacman runs with `--root`, `--gpgdir` and `--hookdir` inside the root, so the host's keyring and hooks stay out. It gets `rustup`, not `rust`: the kernel's prepare() installs Rust 1.85.0 and 1.99.0, and reims-vgpu's `rust-toolchain.toml` asks for 1.98.1. Record the sync databases' sha256 and the root's `pacman -Q`.
- **Build user**: an unprivileged `builduser` in the chroot. makepkg runs as it through `systemd-nspawn --register=no -D <root> -u builduser`, with the work, repository and log directories bound in under `/build`.
- **Network**: still needed for the rustup toolchains and the crates (`cargo fetch --locked` for reims-vgpu checks them against Cargo.lock).

Per package, inside the chroot as `builduser`:

```bash
cd /build/work/<package>    # its PKGBUILD and local files, copied from pkgbuilds/<package>
export PKGDEST=/build/repo SRCDEST=/build/work/srcdest-<package> BUILDDIR=/build/work/<package>/build LOGDEST=/build/logs/<package>
export RUSTUP_HOME=/build/work/<package>/home/rustup CARGO_HOME=/build/work/<package>/home/cargo
export PKGEXT=.pkg.tar.zst SOURCE_DATE_EPOCH=<committer time of the package's pinned commit>
makepkg --printsrcinfo > <package>.SRCINFO
makepkg --verifysource --noconfirm
makepkg -C --noconfirm --log      # omvm and omarchy-macos-vm: add -d
```

- `SOURCE_DATE_EPOCH` is fixed per package: the committer time (`git log -1 --format=%ct`) of `_commit` for the kernel, omvm and the hook, of `_qemu_commit` for qemu-vmapple and of `_mesa_commit` for Mesa. The kernel's is 1795495141 (`f874ff3f`).
- `-C` starts from an empty `$srcdir`; the kernel's prepare() refuses a leftover build tree. The kernel also reads `OMARCHY_BUILD_JOBS` (default 10).
- `-d` for omvm and the hook: their runtime depends (libvirt, hyprland, the two packages built here) are not in the chroot, and neither compiles anything.
- `PKGEXT` overrides the `.pkg.tar.xz` of the chroot's makepkg.conf.

Then `repo-add /build/repo/omarchy-macos-vm.db.tar.zst /build/repo/*.pkg.tar.zst`. Keep each package's `.SRCINFO`, the sha256 of its SRCDEST files, `rustc -Vv` of every toolchain it used and its logs beside the packages.

### Commits not on the public remotes yet

`sapoepsilon/linux-aurora` `f874ff3f`, `sapoepsilon/omvm` `c633dde5` and `sapoepsilon/omarchy-mac-pkgs` `1d52a266` are not pushed yet, so the builder gets them as bundles seeded into SRCDEST. makepkg keeps each git source as a bare clone in `$SRCDEST/<name>`, refuses one whose `remote.origin.url` is not the PKGBUILD's URL, runs `git fetch --all -p` in it, and checks it out through `git clone -s`, which carries only branches and tags. So the commit goes under a tag, and the fetch refspec is narrowed to branches so the prune cannot drop it. The names are `linux` (the kernel), `omvm` (omvm), `omvm-patches` (qemu-vmapple) and `omarchy-mac-pkgs` (the hook).

```bash
# Where the commit exists, against a base the builder's clone already has:
git bundle create omvm-c633dde.bundle 947787d58f55bcf813b1f2863a2a070b8bcd6830..oma-7-basic-tier-reconcile
# On the builder, for each source name that needs it (here omvm; the same for omvm-patches):
git clone --mirror https://github.com/sapoepsilon/omvm.git "$SRCDEST/omvm"   # or a local mirror
G="git -C $SRCDEST/omvm"
$G remote set-url origin https://github.com/sapoepsilon/omvm.git
$G config --unset remote.origin.mirror
$G config --replace-all remote.origin.fetch '+refs/heads/*:refs/heads/*'
$G fetch "$PWD/omvm-c633dde.bundle" 'refs/heads/oma-7-basic-tier-reconcile:refs/tags/pin/c633dde5'
$G cat-file -e 'c633dde5966f6e05cb0056ab12e67786c4ab7127^{commit}'
```

A shallow clone works as long as it holds the bundle's prerequisite commit (for the kernel, `5cff73a4`). The other sources can come from local mirrors the same way: clone one into `$SRCDEST/<name>` and set `remote.origin.url` back to the PKGBUILD's URL. `OMVM_GIT` and `OMARCHY_MAC_PKGS_GIT` change only the URL; the `#commit=` pin stays.

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

On the laptop, with the built packages copied to a directory `$PKGDEST`. It already runs omvm's own `linux-aurora-vmapple` 7.2.11.aurora15vmapple-1, which the -2 package upgrades in place:

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
grep -n 'linux-aurora' /boot/efi/limine.conf     # linux-aurora-vmapple first (the default), stock linux-aurora after it
cat /etc/omarchy-mac-boot/default-side-kernel    # linux-aurora-vmapple
```

`~/.local/bin/omvm` (the owner's checkout) comes before `/usr/bin/omvm` on `PATH`; call `/usr/bin/omvm` to test the package. Then reboot: Limine starts "linux-aurora-vmapple" by default from now on, and stock "linux-aurora" stays in the menu for recovery. Check `omvm doctor` reports the patched kernel and `omvm start macos` boots the existing VM on the packaged QEMU. `omarchy-macos-vm remove` puts stock `linux-aurora` back as the default. The end-to-end test is a fresh install with the box ticked (items c and d).

## Licence

The kernel's four KVM commits are GPL-2.0. Two are aquarat's: the PAuth one is an independent implementation (aquarat/apple-macos-arm64-vm-guest `15ea5eb`), and steelbrain released his original patches into the public domain on 2026-11-11 (steelbrain#1). The other two, the NISV MMIO writeback and its selftest fix, are the owner's. Nothing on this branch is unlicensed any more; omvm's `LICENSING.md` and `docs/upstream-drafts.md` still describe the old blocker. Nothing ships Apple software. An image with these packages stays private only because they are not signed by the Omarchy key.
