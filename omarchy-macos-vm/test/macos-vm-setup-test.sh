#!/bin/bash
# omarchy-macos-vm-setup against a staged root with stubbed pacman, systemctl,
# omvm and boot tools; the script under test is the real one.

set -euo pipefail

package=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
setup=$package/bin/omarchy-macos-vm-setup
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
stub_bin=$test_tmp/bin
calls=$test_tmp/calls
mkdir -p "$stub_bin"

fail() {
  printf 'not ok - %s\n' "$1"
  [[ -z ${2:-} ]] || printf '%s\n' "$2" | sed 's/^/# /'
  exit 1
}
pass() { printf 'ok - %s\n' "$1"; }

stub() {
  printf '#!/bin/bash\n%s\n' "$2" >"$stub_bin/$1"
  chmod +x "$stub_bin/$1"
}
stub pacman 'echo "pacman $*" >>"$TEST_CALLS"
case $1 in
  -Q) for p in "${@:2}"; do grep -Fxq "$p" "$TEST_INSTALLED" || exit 1; echo "$p 1-1"; done ;;
  -U) [[ -z ${TEST_PACMAN_FAIL:-} ]] || exit 1
      for f in "${@:4}"; do b=${f##*/}; echo "${b%-*-*-*}" >>"$TEST_INSTALLED"; done ;;
  -S) [[ -z ${TEST_PACMAN_FAIL:-} ]] || exit 1 ;;
esac'
stub systemctl 'echo "systemctl $*" >>"$TEST_CALLS"; [[ $* != *is-active* || -n ${TEST_ACTIVE:-} ]]'
stub systemd-run 'echo "systemd-run $*" >>"$TEST_CALLS"'
# No VMXFER unless a test says so: the host running the tests may have one.
stub lsblk 'exit 0'
stub systemd-tmpfiles 'echo "systemd-tmpfiles $*" >>"$TEST_CALLS"'
stub systemd-sysusers 'echo "systemd-sysusers $*" >>"$TEST_CALLS"'
stub omvm 'echo "omvm $* home=${HOME:-}" >>"$TEST_CALLS"; echo "The one-time macOS step"'
stub omarchy-mac-limine-active 'exit 0'
stub omarchy-mac-boot-update 'echo "boot-update" >>"$TEST_CALLS"; printf "/+Omarchy\n  //linux-aurora\n  //linux-aurora-vmapple\n" >"$OMARCHY_ESP/limine.conf"; mkdir -p "$OMARCHY_ESP/EFI/Linux"; echo uki >"$OMARCHY_ESP/EFI/Linux/omarchy_linux-aurora-vmapple.efi"'
stub omarchy-apple-silicon-boot-check 'echo "boot-check $* pending=$OMARCHY_BOOT_CHECK_ALLOW_PENDING_REBOOT" >>"$TEST_CALLS"; [[ -z ${TEST_BOOT_CHECK_FAIL:-} ]]'

new_root() {
  root=$test_tmp/root-$1
  mkdir -p "$root/etc/omarchy" "$root/var/lib/pacman" "$root/boot/efi/omarchy/macos-vm/repo"
  : >"$test_tmp/installed"
  : >"$calls"
  printf '[options]\n' >"$root/etc/pacman.conf"
}
add_archives() {
  local p
  for p in linux-aurora-vmapple qemu-vmapple mesa-honeykrisp-vmapple omvm; do
    : >"$1/$p-1.0-1-aarch64.pkg.tar.zst"
  done
  : >"$1/linux-aurora-vmapple-headers-1.0-1-aarch64.pkg.tar.zst"
}
run_setup() {
  set +e
  env -u HOME OMARCHY_MACOS_VM_ROOT="$root" OMARCHY_ESP="$root/boot/efi" OMARCHY_MACOS_VM_SKIP_HW=1 \
    TEST_CALLS="$calls" TEST_INSTALLED="$test_tmp/installed" PATH="$stub_bin:$PATH" \
    bash "$setup" >"$test_tmp/out" 2>&1
  status=$?
  set -e
}

new_root none
run_setup
(( status == 0 )) || fail "no marker exits 0" "$(cat "$test_tmp/out")"
[[ ! -s $calls && ! -e $root/var/lib/omarchy/macos-vm ]] || fail "no marker does nothing" "$(cat "$calls")"
pass "without /etc/omarchy/macos-vm.enabled nothing runs"

new_root esp
printf '{"version":1,"requested_by":"installer"}\n' >"$root/etc/omarchy/macos-vm.enabled"
add_archives "$root/boot/efi/omarchy/macos-vm/repo"
run_setup
(( status == 0 )) || fail "a marker with packages on the ESP succeeds" "$(cat "$test_tmp/out")"
grep -q '^pacman -U --needed --noconfirm .*linux-aurora-vmapple-1.0-1-aarch64.pkg.tar.zst' "$calls" || fail "the ESP packages are installed" "$(cat "$calls")"
! grep -q 'headers' "$calls" || fail "a headers archive is not taken for the kernel" "$(cat "$calls")"
sync_line=$(grep -n '^pacman -Sy' "$calls" | cut -d: -f1 | head -1)
install_line=$(grep -n '^pacman -U' "$calls" | cut -d: -f1 | head -1)
[[ -n $sync_line ]] && (( sync_line < install_line )) || fail "the sync databases are refreshed before pacman -U" "$(cat "$calls")"
grep -q '^omvm macos-step home=/' "$calls" || fail "omvm runs with HOME set" "$(cat "$calls")"
grep -Fxq boot-update "$calls" || fail "a missing side-kernel entry is built"
grep -q '^boot-check --boot-chain pending=1' "$calls" || fail "the boot chain is checked"
grep -q 'systemctl --global enable omarchy-macos-vm-user.service' "$calls" || fail "the user step is enabled"
grep -q '^omvm macos-step' "$calls" || fail "the macOS step is staged"
[[ ! -e $root/etc/libvirt/hooks/qemu ]] || fail "the libvirt hook is left to the omvm package"
grep -q '^package=omvm' "$root/var/lib/omarchy/macos-vm/done" || fail "the done stamp names the packages" "$(cat "$root/var/lib/omarchy/macos-vm/done")"
grep -q 'systemctl disable omarchy-macos-vm-setup.service' "$calls" || fail "the service disables itself"
grep -q 'BOOT_ORDER\|kernel default' "$calls" && fail "the default boot entry is never changed"
grep -q '^systemctl start --no-block omarchy-macos-vm-vmxfer.service' "$calls" || fail "the setup looks on VMXFER right away" "$(cat "$calls")"
pass "a marker installs the ESP packages, builds the side-kernel entry, checks the boot chain and stages the macOS step"

: >"$calls"
run_setup
(( status == 0 )) && ! grep -q pacman "$calls" || fail "a second run does nothing" "$(cat "$calls")"
pass "a finished setup does not run again"

new_root fails
: >"$root/etc/omarchy/macos-vm.enabled"
add_archives "$root/boot/efi/omarchy/macos-vm/repo"
TEST_PACMAN_FAIL=1 run_setup
(( status == 1 )) || fail "a failed install fails the unit"
[[ ! -e $root/var/lib/omarchy/macos-vm/done && -s $root/var/lib/omarchy/macos-vm/last-error ]] ||
  fail "a failed install leaves no done stamp, only the error"
pass "a failed install is retried at the next boot"

new_root boot-check
: >"$root/etc/omarchy/macos-vm.enabled"
add_archives "$root/boot/efi/omarchy/macos-vm/repo"
TEST_BOOT_CHECK_FAIL=1 run_setup
(( status == 1 )) && [[ ! -e $root/var/lib/omarchy/macos-vm/done ]] || fail "a failing boot check stops before done"
pass "a failing boot check stops the setup before it is marked done"

new_root repo
printf '{"version":1,"requested_by":"installer","repo":"https://example.invalid/aarch64"}\n' >"$root/etc/omarchy/macos-vm.enabled"
rm -rf "$root/boot/efi/omarchy/macos-vm/repo"
run_setup
grep -Fq 'Server = https://example.invalid/aarch64' "$root/etc/pacman.d/omarchy-macos-vm.conf" || fail "a repository URL is configured" "$(cat "$test_tmp/out")"
grep -Fqx 'Include = /etc/pacman.d/omarchy-macos-vm.conf' "$root/etc/pacman.conf" || fail "pacman.conf includes it"
grep -q '^pacman -S --needed --noconfirm linux-aurora-vmapple qemu-vmapple' "$calls" || fail "packages come from the repository" "$(cat "$calls")"
pass "a marker's https repo becomes the omarchy-macos-vm pacman repository"

# The installer already put the restored VM on VMXFER: next steps are one restart.
new_root installer-vm
: >"$root/etc/omarchy/macos-vm.enabled"
add_archives "$root/boot/efi/omarchy/macos-vm/repo"
mkdir -p "$test_tmp/esp-xfer"
: >"$test_tmp/esp-xfer/vmxfer.sha256"; : >"$test_tmp/esp-xfer/tahoe-26.4-25E246-restore.tar.gz"
stub lsblk 'printf "/dev/nvme0n1p3 VMXFER\n"'
OMARCHY_MACOS_VM_VMXFER_DIR=$test_tmp/esp-xfer run_setup
stub lsblk 'exit 0'
next=$root/var/lib/omarchy/macos-vm/next-steps.txt
(( status == 0 )) && grep -q 'restored macOS VM is on VMXFER' "$next" && grep -q 'Restart once' "$next" &&
  ! grep -q '^omvm macos-step' "$calls" && ! grep -qi xcode "$next" ||
  fail "with the installer's VM on VMXFER the next steps are a login and one restart" "$(cat "$test_tmp/out" "$next")"
pass "with the installer's VM on VMXFER there is no macOS step, only one restart"

for unit in "$package"/files/usr/lib/systemd/system/*.service; do
  grep -Fq 'ConditionPathExists=/etc/omarchy/macos-vm.enabled' "$unit" || fail "$unit is gated on the marker"
  grep -Fxq 'Environment=HOME=/root' "$unit" || fail "$unit gives omvm a HOME"
done
pass "the system unit is gated on /etc/omarchy/macos-vm.enabled"

user_setup=$package/bin/omarchy-macos-vm-user-setup
user_home=$test_tmp/home
: >"$calls"
stub omarchy-macos-vm 'exit 0'
env -u XDG_STATE_HOME -u XDG_DATA_HOME HOME="$user_home" TEST_CALLS="$calls" PATH="$stub_bin:$PATH" \
  bash "$user_setup" >"$test_tmp/out" 2>&1 || fail "the user step succeeds" "$(cat "$test_tmp/out")"
entry=$user_home/.local/share/applications/macos-vm.desktop
grep -Fxq 'Name=macOS' "$entry" && grep -Fxq 'Exec=uwsm app -- omarchy-macos-vm launch' "$entry" ||
  fail "the user step adds the macOS launcher entry" "$(cat "$entry" 2>&1)"
grep -q '^omvm prepare' "$calls" && [[ -s $user_home/.local/state/omarchy-macos-vm/done ]] ||
  fail "the user step prepares omvm" "$(cat "$calls")"
pass "the user step adds the macOS launcher entry and prepares omvm"

# omarchy-macos-vm-vmxfer: the stamp follows what the macOS step left on VMXFER.
vmxfer=$package/bin/omarchy-macos-vm-vmxfer
xfer=$test_tmp/xfer
mkdir -p "$xfer"
stub findmnt 'exit 0'
stub oneshot 'echo "oneshot $*" >>"$TEST_CALLS"'
run_vmxfer() {
  : >"$calls"
  set +e
  env OMARCHY_MACOS_VM_ROOT="$root" OMARCHY_MACOS_VM_VMXFER_DIR="$xfer" PATH="$stub_bin:$PATH" \
    OMARCHY_MACOS_VM_ONESHOT="$stub_bin/oneshot" TEST_CALLS="$calls" \
    bash "$vmxfer" >"$test_tmp/out" 2>&1
  status=$?
  set -e
}
new_root vmxfer
stub lsblk 'printf "/dev/nvme0n1p2 \n/dev/nvme0n1p3 VMXFER\n"'
run_vmxfer
(( status == 0 )) && [[ ! -e $root/var/lib/omarchy/macos-vm/vmxfer-ready ]] && ! grep -q oneshot "$calls" ||
  fail "an empty VMXFER is not ready and arms nothing" "$(cat "$test_tmp/out")"
: >"$xfer/vmxfer.sha256"; : >"$xfer/tahoe-26.4-25E246-restore.tar.gz"
run_vmxfer
grep -q '^device=/dev/nvme0n1p3' "$root/var/lib/omarchy/macos-vm/vmxfer-ready" &&
  grep -Fxq "mount=$xfer" "$root/var/lib/omarchy/macos-vm/vmxfer-ready" ||
  fail "the macOS step's output makes VMXFER ready and names its mount" "$(cat "$test_tmp/out")"
grep -Fxq 'oneshot arm' "$calls" || fail "a ready VMXFER arms the side kernel's one-time boot" "$(cat "$calls")"
stub lsblk 'printf "/dev/nvme0n1p2 \n"'
run_vmxfer
(( status == 0 )) && [[ ! -e $root/var/lib/omarchy/macos-vm/vmxfer-ready ]] || fail "no VMXFER clears the stamp"
grep -Fq 'ConditionPathExists=/var/lib/omarchy/macos-vm/done' "$package/files/usr/lib/systemd/system/omarchy-macos-vm-vmxfer.service" &&
  grep -Fxq 'enable omarchy-macos-vm-vmxfer.service' "$package/files/usr/lib/systemd/system-preset/80-omarchy-macos-vm.preset" ||
  fail "the VMXFER check runs at boot once the stack is installed"
pass "omarchy-macos-vm-vmxfer marks VMXFER ready only when the macOS step's VM is on it"

# omarchy-macos-vm-login: at login, finish the VM in a terminal once it can be.
login=$package/bin/omarchy-macos-vm-login
lstate=$test_tmp/lstate
limages=$test_tmp/limages
kvm=$test_tmp/kvm-param
stub omvm 'echo "omvm $*" >>"$TEST_CALLS"; [[ $1 != mode || -n ${TEST_VM:-} ]]'
stub omarchy-notification-send 'echo "notify $*" >>"$TEST_CALLS"'
stub omarchy-launch-floating-terminal-with-presentation 'echo "terminal $*" >>"$TEST_CALLS"'
run_login() {
  : >"$calls"
  set +e
  env -u XDG_STATE_HOME -u XDG_DATA_HOME HOME="$user_home" TEST_CALLS="$calls" PATH="$stub_bin:$PATH" \
    OMARCHY_MACOS_VM_STATE="$lstate" OMVM_IMAGES="$limages" OMARCHY_MACOS_VM_KVM_PARAM="$kvm" \
    bash "$login" >"$test_tmp/out" 2>&1
  status=$?
  set -e
}
rm -rf "$lstate" "$limages" "$kvm" "$user_home/.local/state/omarchy-macos-vm/vm-created"
mkdir -p "$lstate"
run_login
(( status == 0 )) && ! grep -q '^\(notify\|terminal\)' "$calls" || fail "before the macOS step login does nothing" "$(cat "$calls")"
touch "$lstate/vmxfer-ready"
run_login
grep -q "^systemd-run --user --unit=omarchy-macos-vm-creating .*$stub_bin/omarchy-macos-vm create --auto" "$calls" &&
  grep -q '^notify Creating the macOS VM' "$calls" && ! grep -q '^terminal' "$calls" ||
  fail "with the VM on VMXFER login runs omarchy-macos-vm create --auto in the background" "$(cat "$calls")"
TEST_ACTIVE=1 run_login
! grep -q '^systemd-run' "$calls" || fail "a create already running is not started twice" "$(cat "$calls")"
mkdir -p "$limages/b-restore"; touch "$limages/b-restore/.ingested"
run_login
grep -q '^notify .*restart to finish Boot linux-aurora-vmapple from the Limine menu' "$calls" && ! grep -q '^systemd-run' "$calls" ||
  fail "imported on the stock kernel login only asks for the side kernel" "$(cat "$calls")"
touch "$lstate/oneshot-armed"
run_login
grep -q '^notify .*restart to finish Restart once: Omarchy starts linux-aurora-vmapple by itself' "$calls" ||
  fail "with the one-time boot armed login asks only for a restart" "$(cat "$calls")"
touch "$kvm"
run_login
grep -q '^systemd-run .*create --auto' "$calls" || fail "on the side kernel login finishes the VM" "$(cat "$calls")"
TEST_VM=1 run_login
! grep -q '^systemd-run' "$calls" && [[ -s $user_home/.local/state/omarchy-macos-vm/vm-created ]] ||
  fail "once the VM exists login stops for good" "$(cat "$calls")"
unit=$package/files/usr/lib/systemd/user/omarchy-macos-vm-create.service
grep -Fq 'ConditionPathExists=!%h/.local/state/omarchy-macos-vm/vm-created' "$unit" && grep -Fxq 'WantedBy=graphical-session.target' "$unit" ||
  fail "the login unit runs at graphical login until the VM is created"
pass "omarchy-macos-vm-login finishes the VM in the background at login, asking only for one restart"
