# Building the macOS VM stack (branch `macos-vm`)

This branch makes a fresh Omarchy Mac install able to come up as an [omvm](https://github.com/sapoepsilon/omvm) host. It is the owner's fork; nothing here goes to omacom.

## What is on this branch

| Path | What |
| --- | --- |
| `omarchy-macos-vm/` | New package: the first-boot hook (`omarchy-macos-vm-setup.service`, per-user `omarchy-macos-vm-user.service`). Meets the package contract (`install`, `test/all`, README, LICENSE, version). |
| `omarchy-macos-vm/pkgbuilds/linux-aurora-vmapple/` | Side kernel from the owner's fork `sapoepsilon/linux-aurora`, pinned to commit `f874ff3f`, the tip of its public branch `codex/oma5-nisv-writeback` (the recipe's `url` still names `vmapple/kvm-macos-guest`, which ends at `5cff73a4` and lacks the two newest commits): linux-aurora integration/aurora `b798f2b` (7.2.11.aurora15, recipe files from omarchy-pkgs `73931c9b`, pinned by commit and sha256) plus four GPL-2.0 KVM commits, aquarat's `ac4f53c7` (MMIO load/store without a syndrome) and `5cff73a4` (Apple PAuth state under VHE), and the owner's `9ee27354` (deferred NISV MMIO writeback, respecting `KVM_CAP_ARM_NISV_TO_USER`) and `f874ff3f` (its `mmio_nisv_wb` selftest fix). The private bindgen's source archive (0.73.2) is a sha256-pinned source too. Own pkgbase, no `linux-asahi` provide, no headers package, ships `/usr/share/omarchy-mac-boot/side-kernels.d/linux-aurora-vmapple`. Version 7.2.11.aurora15vmapple-2: the same name as the -1 build the laptop runs, so pacman upgrades it in place, and the new pkgrel makes the kernel release `7.2.11-15vmapple-2-ARCH`, which omvm `c633dde5`'s Apple-services provider check does not accept yet (`share/apple-helpers.py:122` requires exactly `7.2.11-15vmapple-1-ARCH`); the basic tier does not use it. It gets its own UKI and Limine entry beside stock `linux-aurora`; with the macOS VM stack enabled the hook makes it the persistent default (`omarchy-macos-vm-boot-default enable`, recorded in `/etc/omarchy-mac-boot/default-side-kernel` and kept across kernel updates) and keeps stock `linux-aurora` selectable for recovery; `omarchy-macos-vm remove` restores the stock default. |
| `omarchy-macos-vm/pkgbuilds/qemu-vmapple/` | steelbrain/qemu-reims-vgpu `1b41f5f5` + omvm's qemu 0001-0007 and usb 0001, taken from omvm `c633dde5` (`patches/` is unchanged since `e75eff0`), the same eight commits as the laptop's `qemu-fairplay-dev/src` branch `sb-kvm-bdif-write` (`760d1d0d`); the uncommitted FairPlay/identity work there and the `qemu-ofr2` lab build the VMs use now are left out, linked to reims-vgpu `1fe0acb6` + metal2vulkan `219f0136` with omvm's patches, in `/usr/lib/qemu-vmapple`. `git am --committer-date-is-author-date` with a fixed committer gives the patched trees the same heads on every build. The three meson wraps configure resolves (keycodemapdb, berkeley-softfloat-3, berkeley-testfloat-3) are sources pinned to the revisions in qemu's `subprojects/*.wrap`, and `--disable-download` fails on any other. reims-vgpu is built with `-C target-cpu=apple-m1`, the M1/M2 floor, which has the LSE and RCpc its inline assembly needs, instead of the build host's `native`. Its crates are built with one codegen unit each (`CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1`): with the default 16, rustc's crate-local ThinLTO names promoted local symbols after a hash of each unit's bitcode, which LLVM 22.1.8 does not emit the same on every run, so two clean builds differed in `.strtab` and the build-id of `libreims_vgpu.so` and `qemu-system-aarch64`. pkgver takes 11.1.50 from qemu's `VERSION` at `1b41f5f5`, and `--with-pkgversion` fixes the version string to `qemu-vmapple 11.1.50.r1b41f5f5-1`, so `git describe` of the patched head stays out of it. configure's offline `mkvenv` installs qemu's `python/` package with the system's setuptools and wheel (`pythondeps.toml` group `tooling`), so both are makedepends. |
| `omarchy-macos-vm/pkgbuilds/mesa-honeykrisp-vmapple/` | Mesa 26.2.6, pinned to commit `8e87a503` (what tag `mesa-26.2.6` names), built with `--wrap-mode=nodownload` so every dependency comes from the system, + `honeykrisp-vmapple.patch`, the exact diff of the laptop's `~/src/mesa-honeykrisp-sb` (aquarat's two 16-bit varying fixes + omvm's interlock patch; `asahi/16-bit-varyings` is the same two fixes on Mesa main, for the MR), two ICDs (`headless/`, `wayland/`) in `/usr/lib/mesa-honeykrisp-vmapple`, never in `/usr/share/vulkan/icd.d`. |
| `omarchy-macos-vm/pkgbuilds/omvm/` | The owner's `packaging/aur/PKGBUILD` from omvm `omarchy/must-fix`, built from omvm commit `c633dde5` (`macos-vm` `947787d5` plus four commits ending in the basic-tier VM profile, OMA-7; the tip of sapoepsilon/omvm's public branch `codex/oma7-basic-tier`, not on `main`): it finds the two packages above, adds `omvm prepare`, ships the udmabuf tmpfiles.d, lets `omvm ingest` use the read-only VMXFER mount the vmxfer service holds (no sudo), hands upstream's headless launchers (`omvm setup`, `run`, `start`) the packaged QEMU, and (`22abc8d`) logs the guest account in automatically with the password in `guest-password`, skipping the post-login Setup Assistant panes. The version is static, `0.1.0.r200.c633dde` (commits up to `c633dde5` and its 7-character hash, counted once on a full clone), and prepare() fails unless the checkout is that commit. `OMVM_GIT` can point makepkg at another clone of the same commit. |
| Desktop runtime `5b87312d` | The omacom/omarchy runtime the stack is matched with: two commits on quattro `94a8c3c3` (the Install/Remove > macOS menu rows beside Windows, which run `omarchy-macos-vm install`/`remove`, and the Apple Silicon hardware install leaf), on the owner's fork `sapoepsilon/omarchy-mac` branch `codex/oma11-basic-vm-menu`. There is no `sapoepsilon/omarchy`. |
| `omarchy-macos-vm/pkgbuilds/omarchy-macos-vm/` | The hook package, built from omarchy-mac-pkgs commit `1d52a266`, which holds every file it installs. A commit cannot name its own hash, so the pin trails the recipe by one commit and moves whenever the hook's files change. `OMARCHY_MAC_PKGS_GIT` can point makepkg at another clone of the same commit. |
| `omarchy-mac-boot/` | (1) Merges `m1n1-multiple-kernels` (m1n1's device trees come from linux-aurora's tree, not the newest one) and `fix/limine-cmdline-append`. (2) The boot check knows **side kernels**: a kernel package that declares itself in `/usr/share/omarchy-mac-boot/side-kernels.d/` may be running (checked as a pending reboot of the Apple kernel) or first in the Limine menu (its UKI must exist and the Apple kernel's entry must still be there; that entry is what gets checked). Undeclared second kernels fail as before. (3) First boot reads `macos_vm=1` from `install.conf` and writes `/etc/omarchy/macos-vm.enabled`, with the installer's macOS account from `omarchy/macos-vm-credentials` (then 0600; the ESP file is deleted). |

Why the boot check needed it: with a second kernel installed, `update-m1n1` built m1n1 with the side kernel's device trees whenever its module tree sorted newest (the check then refused `omarchy update`), a menu with the side kernel first failed "starts linux-aurora-vmapple first", and running the side kernel failed the non-update check. The first is the `m1n1-multiple-kernels` fix; the others are the side-kernel declaration.

## The contract with the installer (item c) and the image (item d)

- Installer: ticked box = a fourth line `macos_vm=1` in `omarchy/install.conf` on the Omarchy ESP (installer commit `c416c0c`). Unticked = the old three-line file.
- First boot (`omarchy-mac-boot`, this branch): `macos_vm=1` writes `/etc/omarchy/macos-vm.enabled` = `{"version":1,"requested_by":"installer"}`. Unknown values are logged and ignored; first boot never fails over them. The encrypt hook in the initramfs already ignores unknown keys.
- The macOS account (installer branch `dev/macos-vm-credentials`): with the box ticked the installer also writes `omarchy/macos-vm-credentials` on the ESP, `macos_vm_user=` and `macos_vm_password=` (defaults: the Omarchy username, `macos`). Not in `install.conf`, which the initramfs reads and first boot keeps 0644 on the root; FAT has no per-file permissions, so the password gets its own short-lived file. First boot validates it (username `^[a-z_][a-z0-9_-]{0,30}$`, password 1-64 printable ASCII without `'`), adds `"guest_user"`/`"guest_password"` to the marker, writes the marker 0600, and deletes the ESP file (also when `macos_vm` is not 1, or the file is invalid, in which case the marker has no account and the defaults apply). `omarchy-macos-vm-credentials` (run by the setup and every boot by the vmxfer service) moves them to the owner's `~/.config/omarchy/macos-vm-credentials` (0600) and drops the password from the marker (0644 again).
- `omarchy-macos-vm-setup.service` starts on that file (see [README.md](README.md)).

What the image (item d) must do to bake a payload with the stack:

1. Beside the five packages here, the payload's runtime inputs are `omarchy-mac-boot` and `omarchy-mac` built from boot final `8750b164` (`sapoepsilon/omarchy-mac-pkgs` branch `codex/oma6-basic-vm-boot`) and `omarchy` and `omarchy-settings` built from the desktop runtime `5b87312d`, all four from the recipes on the public `sapoepsilon/omarchy-pkgs` branch `codex/oma12-runtime-recipes` (`b828a2e4`). That `omarchy-mac-boot` keeps the boot order the hook's persistent default writes across kernel updates and `limine.conf` rebuilds (`omarchy-mac-limine-boot-order`, OMA-6), which older boot packages do not, so never pair this hook with older boot or runtime packages. The `platform_sources` mechanism in omarchy-mac-installer's image-builder takes them from those commits.
2. Install `omarchy-macos-vm` into `@` before the `@factory` seal and apply its preset (`80-omarchy-macos-vm.preset`), the way `--lab-access` writes its overlay. It is harmless without the marker.
3. Put the four stack packages in `/var/lib/omarchy/macos-vm/repo/` in `@` and their signatures in `/var/lib/omarchy/macos-vm/signatures/`, the copy the developer image's verifier checks (see below). Without them the service looks in the configured repositories and fails, retrying every boot.
4. Such an image carries packages no Omarchy key signed, so the public inspection and `mac-release-guard` refuse it by design. The developer-only signed path below is the only way to build it.

## Build in a clean chroot (aarch64)

Every package is built on an aarch64 Arch Linux ARM host (the runner, an M1 Max) in a clean chroot, never against the host's installed packages. Builds take about 30-60 min (kernel), 25 min (QEMU), 10 min (Mesa).

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

### Commits not on the public remotes

Every commit the recipes pin is on a public branch: the kernel `f874ff3f` and omvm `c633dde5` (also qemu-vmapple's `omvm-patches`) on the branches named above, the desktop runtime `5b87312d`, and the hook recipe's `_commit` in this repository on `sapoepsilon/omarchy-mac-pkgs` branch `codex/oma9-pins`. So makepkg fetches them all from the recipes' default URLs. A bundle is needed only while a pinned commit is not pushed, as the hook's `1d52a266` was for the first builds of these packages. makepkg keeps each git source as a bare clone in `$SRCDEST/<name>`, refuses one whose `remote.origin.url` is not the PKGBUILD's URL, runs `git fetch --all -p` in it, and checks it out through `git clone -s`, which carries only branches and tags. So the commit goes under a tag, and the fetch refspec is narrowed to branches so the prune cannot drop it. The hook's source name is `omarchy-mac-pkgs`.

```bash
# Example, the hook's 1d52a266 before it was pushed, against the published 8750b164:
git tag pin/1d52a266 1d52a26604ec156e754f95b9e5fbd588e41321cc
git bundle create omarchy-mac-pkgs-1d52a266.bundle 8750b164b076c391ac657aa084beec3e3d8fd84e..pin/1d52a266
# On the builder:
git clone --mirror https://github.com/sapoepsilon/omarchy-mac-pkgs.git "$SRCDEST/omarchy-mac-pkgs"   # or a local mirror
G="git -C $SRCDEST/omarchy-mac-pkgs"
$G remote set-url origin https://github.com/sapoepsilon/omarchy-mac-pkgs.git
$G config --unset remote.origin.mirror
$G config --replace-all remote.origin.fetch '+refs/heads/*:refs/heads/*'
$G fetch "$PWD/omarchy-mac-pkgs-1d52a266.bundle" 'refs/tags/pin/1d52a266:refs/tags/pin/1d52a266'
$G cat-file -e '1d52a26604ec156e754f95b9e5fbd588e41321cc^{commit}'
```

A shallow clone works as long as it holds the bundle's prerequisite commit, `8750b164`. The other sources can come from local mirrors the same way: clone one into `$SRCDEST/<name>` and set `remote.origin.url` back to the PKGBUILD's URL. `OMVM_GIT` and `OMARCHY_MAC_PKGS_GIT` change only the URL; the `#commit=` pin stays.

## Hosting the packages

The packages and their repository database are signed by a developer-only key, never by the Omarchy key: detached signatures (`<archive>.sig`, and `omarchy-macos-vm.db.tar.zst.sig` for the database archive, which is the file the developer image's verifier checks; `repo-add --sign` also links `omarchy-macos-vm.db.sig` to it for pacman) by `FDBEEC154C82FDF0F6E1B2BED912D095848C2F1C`, whose UID reads `Omarchy VM Beta developer signer (DEVELOPER-ONLY, not for public release)`. Its public key is `omarchy-vm-beta-dev-signing.pub.asc`, sha256 `73f24636f1ca86b16be9a306f7061fcb705c6a05798449e3dc86f7e7cbfe4f9a`. The owner signs on their Mac; keys never go to the build host. The accepted archives are signed one by one as they are accepted, and the repository database and the candidate receipt are signed with the same key once the full candidate is assembled. What else carries a signature: the developer catalog's Ed25519 signature authenticates the image payload's hashes, and the installer app inside the DMG is code-signed with an Apple Development identity. The image and the DMG file are not themselves signed: the DMG helper produces an unsigned DMG next to an unsigned checksum manifest, and the DMG is verified by its SHA-256. There is no Developer ID or notarization. This is not OMA12 or public acceptance: the public inspection and `mac-release-guard` still refuse an image carrying these packages or this key.

- **Local repo on a developer laptop** (for updates): trust the key on that machine explicitly and require signatures from the repository.
  ```
  sudo pacman-key --add omarchy-vm-beta-dev-signing.pub.asc
  sudo pacman-key --lsign-key FDBEEC154C82FDF0F6E1B2BED912D095848C2F1C
  ```
  Then add to `/etc/pacman.conf`:
  ```
  [omarchy-macos-vm]
  SigLevel = Required
  Server = file:///home/<user>/omarchy-macos-vm-repo/$arch
  ```
  and run `sudo pacman -Sy`. pacman's keyring is not scoped to a repository, so the local signature trusts the key wherever pacman checks signatures: do this only on a developer machine, and `sudo pacman-key --delete FDBEEC154C82FDF0F6E1B2BED912D095848C2F1C` takes it back. To update, rebuild, `repo-add` again and have the owner sign the new archives and database.
- **In the payload** (a developer image): omarchy-mac-installer's image-builder, given the developer trust (`build-mac-image --developer-trust DIR --macos-vm`; on the owner's private `sapoepsilon/omarchy-mac-installer` branch `codex/oma12-candidate-integration`, not merged upstream), stages the four archives and the database in `/var/lib/omarchy/macos-vm/repo/` in `@` and their signatures in `/var/lib/omarchy/macos-vm/signatures/`, and seals the developer public key, its policy and the signed manifest in `/usr/lib/omarchy/developer-trust/`, never in the image's pacman keyring. The drop-in `/etc/systemd/system/omarchy-macos-vm-setup.service.d/50-omarchy-developer-verify.conf` runs `verify-macos-vm` as `ExecStartPre`: gpgv checks the manifest, every staged archive and the database against the sealed key alone, and a bad, missing or foreign signature fails the unit before the setup's `pacman -U`, with no unsigned fallback. It is tested against signed fixtures, not yet on a booted image.
- **Over the tailnet**: a marker `"repo":"https://.../aarch64"` makes the setup add `[omarchy-macos-vm]` with `SigLevel = Optional TrustAll` (`add_repository` in `omarchy-macos-vm-setup`), so it is not the signed path, and the developer image's verifier refuses a marker that names a `repo`.

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
/usr/lib/qemu-vmapple/qemu-system-aarch64 --version          # QEMU emulator version 11.1.50 (qemu-vmapple 11.1.50.r1b41f5f5-1)
/usr/lib/qemu-vmapple/qemu-system-aarch64 -device help | grep apple-gfx-pci
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

reims-vgpu is linked statically into `qemu-system-aarch64` (about 21,000 reims symbols, no `NEEDED` entry), so `ldd` never lists it, and the `lib/libreims_vgpu.so` the package also ships is not loaded; `apple-gfx-pci` is the display device it backs, which upstream QEMU builds only on macOS hosts. `~/.local/bin/omvm` (the owner's checkout) comes before `/usr/bin/omvm` on `PATH`; call `/usr/bin/omvm` to test the package. Then reboot: Limine starts "linux-aurora-vmapple" by default from now on, and stock "linux-aurora" stays in the menu for recovery. Check `omvm doctor` reports the patched kernel and `omvm start macos` boots the existing VM on the packaged QEMU. `omarchy-macos-vm remove` puts stock `linux-aurora` back as the default. The end-to-end test is a fresh install with the box ticked (items c and d).

## Licence

The kernel's four KVM commits are GPL-2.0. Two are aquarat's: the PAuth one is an independent implementation (aquarat/apple-macos-arm64-vm-guest `15ea5eb`), and steelbrain released his original patches into the public domain on 2026-11-11 (steelbrain#1). The other two, the NISV MMIO writeback and its selftest fix, are the owner's. Nothing on this branch is unlicensed any more; omvm's `LICENSING.md` and `docs/upstream-drafts.md` still describe the old blocker. Nothing ships Apple software. An image with these packages stays private only because they are not signed by the Omarchy key.
