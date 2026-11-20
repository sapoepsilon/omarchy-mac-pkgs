# omarchy-macos-vm

The first-boot hook that turns an install's "macOS VM" request into a working [omvm](https://github.com/sapoepsilon/omvm) host. It is small and carries none of the stack itself, so it can sit in every image; it does nothing until the request exists.

## The request

`/etc/omarchy/macos-vm.enabled`, JSON:

```json
{"version":1,"requested_by":"installer"}
```

The installer cannot write the root filesystem. When its macOS VM box is ticked it adds a fourth line, `macos_vm=1`, to `omarchy/install.conf` on the Omarchy EFI partition (`/boot/efi/omarchy/install.conf` once installed). At first boot `omarchy-mac-boot`'s `omarchy-mac-first-boot` consumes that file as before and, for `macos_vm=1`, writes the marker. A missing line, `macos_vm=0` or any other value writes nothing and never stops first boot; the three-line file is unchanged. A script install (`install.sh`) writes the same marker with `OMARCHY_MACOS_VM=1` (omarchy-mac `install/hardware/apple/macos-vm.sh`).

Optional keys, for a marker written by hand or by an image builder: `repo` (a directory of packages, or an `https://` pacman repository) and `user`.

From the installer the marker can also carry the macOS account the owner chose under the "Set up a macOS VM" tick: `guest_user` and `guest_password` (first boot copies them from the ESP's `omarchy/macos-vm-credentials`, deletes that file and makes the marker 0600). `omarchy-macos-vm-credentials` (root; run by the setup and by `omarchy-macos-vm-vmxfer.service` at every boot until it has worked) writes them to the owner's `~/.config/omarchy/macos-vm-credentials` (0600, `USERNAME=`/`PASSWORD=`, like the Windows VM's `~/.config/windows/credentials`) and removes the password from the marker. The owner is the marker's `user`, else the first account with a UID from 1000; until that account exists `/var/lib/omarchy/macos-vm/credentials-pending` makes `create --auto` wait instead of using the defaults.

## The macOS account

Like `omarchy-windows-vm`, the account has a username and a password with defaults: the wizard (Install › macOS) asks for both, a blank username is this Omarchy user's name and a blank password is `macos`; `create --auto` uses the stored account (the installer's or the wizard's) or the same defaults. The account is kept in `~/.config/omarchy/macos-vm-credentials` (0600) and handed to omvm (`OMVM_GUEST_USER` in `~/.config/omvm/gui.env`, the password in `~/.local/share/omvm/guest-password`, 0600) before `omvm setup` creates it. omvm logs it in automatically (loginwindow's `autoLoginUser` and `/etc/kcpassword`) and marks the post-login Setup Assistant panes seen, so the VM opens on the desktop; the password unlocks the screen and works for sudo. `omarchy-macos-vm status` and the progress view's Ready screen show the username and password. A VM made before this keeps its generated password (status shows it from omvm's `guest-password`); `omvm autologin macos` turns the automatic login on in it.

## What it does

`omarchy-macos-vm-setup.service` (enabled by `80-omarchy-macos-vm.preset`, gated on the marker, ordered after `omarchy-mac-first-boot.service` and the network) runs `/usr/lib/omarchy-macos-vm/omarchy-macos-vm-setup`:

1. Installs `linux-aurora-vmapple`, `qemu-vmapple`, `mesa-honeykrisp-vmapple` and `omvm`, from the first of: the marker's `repo` directory, `/var/lib/omarchy/macos-vm/repo/`, `/boot/efi/omarchy/macos-vm/repo/`, the marker's `https://` repository (added as `[omarchy-macos-vm]`), or the repositories already configured. Then `virt-manager`, best effort.
2. Makes sure the side kernel has its UKI (`omarchy_linux-aurora-vmapple.efi`) and Limine entry, running `omarchy-mac-boot-update` once if the kernel's hooks did not, and runs `omarchy-apple-silicon-boot-check --boot-chain` as `omarchy update` does. `linux-aurora` stays the default entry.
3. Host side: applies what the omvm package ships (its `omvm` group and udmabuf limits; its libvirt hook is `/etc/libvirt/hooks/qemu.d/50-omvm`) and enables `omarchy-macos-vm-user.service`, `omarchy-macos-vm-create.service` and `omarchy-macos-vm-create.path` for every user.
4. Writes what is next to `/var/lib/omarchy/macos-vm/next-steps.txt`: when VMXFER already holds the restored VM (the developer installer's "Set up a macOS VM" step makes it on macOS before the first boot), one login and one restart; otherwise it stages the one-time macOS step (`omvm macos-step`).
5. Writes `/var/lib/omarchy/macos-vm/done` with the installed versions, disables itself and starts `omarchy-macos-vm-vmxfer.service` right away. A user who logged in before this point gets the per-user units started in their running session (`omarchy-macos-vm-users kick`: `daemon-reload`, then the user step, the path unit and the create step), so nothing waits for the next login.

Before pacman it waits up to 15 minutes (`OMARCHY_MACOS_VM_NETWORK_WAIT`, in seconds) until every package mirror resolves and answers HTTPS, since the first boot often comes before Wi-Fi is joined; while it waits, the users logged in get a "waiting for internet" notification. `/var/lib/omarchy/macos-vm/status` names the stage (`waiting-for-internet`, `installing`, `retrying`, `failed`, `done`). No internet, a pacman failure (a mirror's 404) or a held pacman lock exits 75, and the unit restarts itself (`Restart=on-failure`, backing off from 30 s to 10 minutes, no start limit); `/usr/lib/NetworkManager/dispatcher.d/90-omarchy-macos-vm` starts it at once when a link comes up. A hard failure (not an Apple Silicon Mac, a failing boot check) exits 1 and waits for the next boot. Every failure is logged to the journal (`journalctl -u omarchy-macos-vm-setup`) and `/var/lib/omarchy/macos-vm/last-error`, and leaves no done stamp. At each user's first login after that, `omarchy-macos-vm-user.service` adds the "macOS" launcher entry (`~/.local/share/applications/macos-vm.desktop`, running `omarchy-macos-vm launch`) and runs `omvm prepare` (SSH key, the pinned guest harness, `~/.config/omvm/gui.env`) and `omvm doctor`.

Once the restored VM is on VMXFER the rest is automatic; the owner only restarts once:

- `omarchy-macos-vm-vmxfer.service` (root; every boot once the stack is installed, right after the setup, and from `omarchy-macos-vm install`) writes `/var/lib/omarchy/macos-vm/vmxfer-ready` when `vmxfer.sha256` and the restore bundle are on VMXFER, keeps VMXFER mounted read-only at `/run/omarchy-macos-vm/vmxfer` (the stamp's `mount=`) so `omvm ingest` needs no sudo password, and arms one boot of `linux-aurora-vmapple` (`omarchy-macos-vm-oneshot-boot arm`: limine.conf's `default_entry` points at it, the old value is kept; at most two tries).
- `omarchy-macos-vm-oneshot-restore.service` (root, early on the next boot, whichever kernel started) puts `default_entry` back, so `linux-aurora` stays the default.
- At each graphical login until the VM exists, and during a session when `done` or `vmxfer-ready` changes (`omarchy-macos-vm-create.path`; `omarchy-macos-vm-vmxfer` also kicks running sessions), `omarchy-macos-vm-create.service` (user) starts `omarchy-macos-vm create --auto` in the background (transient unit `omarchy-macos-vm-creating`, where exit 2, "restart needed", counts as success): `omvm ingest`, then on `linux-aurora-vmapple` (which `omvm setup` needs) `omvm setup` and `omvm virt macos`, choosing the guest account (this user), RAM and cores unless `omarchy-macos-vm install` already did. On the stock kernel it stops after the import and a notification asks for the restart. The "macOS" launcher entry then opens the VM.
- Like the Windows VM install, the progress is visible: the create step opens a floating terminal (`omarchy-launch-floating-terminal-with-presentation`, in the transient unit `omarchy-macos-vm-progress-view`) running `omarchy-macos-vm progress`, which shows the stages (Importing, Restart needed, Setting up, Ready), a percentage taken from the steps omvm prints, the current step and the last lines of `~/.local/state/omarchy-macos-vm/create.log`. The stage is kept in `~/.local/state/omarchy-macos-vm/progress`. The "macOS" launcher clicked while the stack or the VM is still being made sends "Still setting up (stage, percent)…" and opens the same view instead of an error; at the end a notification says "macOS VM ready — open it from Super+Space".

The package also ships `/usr/bin/omarchy-macos-vm` (`install`, `create [--auto]`, `progress`, `launch`, `stop`, `status`, `remove`; it started in omarchy-mac's `macos-vm` branch, which stock Omarchy images do not carry). `create --auto` opens the VM once it is defined (`omarchy-macos-vm launch` in the transient unit `omarchy-macos-vm-launch`). Notifications wait up to 90 s for the notification daemon, since the login step can start before Omarchy's shell; each one is also written to the journal.

The stack setup itself never downloads Apple software and never creates a guest (that needs the macOS side). The default boot entry changes only for the one armed boot.

## Recipes

`pkgbuilds/` holds the recipes for the stack and for this package; [BUILD.md](../BUILD.md) has the commands. `linux-aurora-vmapple` builds the owner's fork branch `sapoepsilon/linux-aurora` `vmapple/kvm-macos-guest`, whose two KVM commits are GPL-2.0.

## Tests

`test/all` runs the setup script against a staged root with pacman, systemctl, omvm and the boot tools stubbed, and `omarchy-macos-vm`'s progress, launcher and progress view against stubbed omvm and systemd.
