# omarchy-macos-vm

The first-boot hook that turns an install's "macOS VM" request into a working [omvm](https://github.com/sapoepsilon/omvm) host. It is small and carries none of the stack itself, so it can sit in every image; it does nothing until the request exists.

## The request

`/etc/omarchy/macos-vm.enabled`, JSON:

```json
{"version":1,"requested_by":"installer"}
```

The installer cannot write the root filesystem. When its macOS VM box is ticked it adds a fourth line, `macos_vm=1`, to `omarchy/install.conf` on the Omarchy EFI partition (`/boot/efi/omarchy/install.conf` once installed). At first boot `omarchy-mac-boot`'s `omarchy-mac-first-boot` consumes that file as before and, for `macos_vm=1`, writes the marker. A missing line, `macos_vm=0` or any other value writes nothing and never stops first boot; the three-line file is unchanged. A script install (`install.sh`) writes the same marker with `OMARCHY_MACOS_VM=1` (omarchy-mac `install/hardware/apple/macos-vm.sh`).

Optional keys, for a marker written by hand or by an image builder: `repo` (a directory of packages, or an `https://` pacman repository) and `user`.

## What it does

`omarchy-macos-vm-setup.service` (enabled by `80-omarchy-macos-vm.preset`, gated on the marker, ordered after `omarchy-mac-first-boot.service` and the network) runs `/usr/lib/omarchy-macos-vm/omarchy-macos-vm-setup`:

1. Installs `linux-aurora-vmapple`, `qemu-vmapple`, `mesa-honeykrisp-vmapple` and `omvm`, from the first of: the marker's `repo` directory, `/var/lib/omarchy/macos-vm/repo/`, `/boot/efi/omarchy/macos-vm/repo/`, the marker's `https://` repository (added as `[omarchy-macos-vm]`), or the repositories already configured. Then `virt-manager`, best effort.
2. Makes sure the side kernel has its UKI (`omarchy_linux-aurora-vmapple.efi`) and Limine entry, running `omarchy-mac-boot-update` once if the kernel's hooks did not, and runs `omarchy-apple-silicon-boot-check --boot-chain` as `omarchy update` does. `linux-aurora` stays the default entry.
3. Host side: applies what the omvm package ships (its `omvm` group and udmabuf limits; its libvirt hook is `/etc/libvirt/hooks/qemu.d/50-omvm`) and enables `omarchy-macos-vm-user.service` for every user.
4. Stages the one-time macOS step (`omvm macos-step`) and writes what is next to `/var/lib/omarchy/macos-vm/next-steps.txt`.
5. Writes `/var/lib/omarchy/macos-vm/done` with the installed versions and disables itself.

Any failure is logged to the journal (`journalctl -u omarchy-macos-vm-setup`) and `/var/lib/omarchy/macos-vm/last-error`, leaves no done stamp, and the next boot retries. At each user's first login after that, `omarchy-macos-vm-user.service` runs `omvm prepare` (SSH key, the pinned guest harness, `~/.config/omvm/gui.env`) and `omvm doctor`.

It never downloads Apple software, never creates a guest (that needs the macOS step) and never changes the default boot entry.

## Recipes

`pkgbuilds/` holds the recipes for the stack and for this package; [BUILD.md](../BUILD.md) has the commands. `linux-aurora-vmapple` builds the owner's fork branch `sapoepsilon/linux-aurora` `vmapple/kvm-macos-guest`, whose two KVM commits are GPL-2.0.

## Tests

`test/all` runs the setup script against a staged root with pacman, systemctl, omvm and the boot tools stubbed.
