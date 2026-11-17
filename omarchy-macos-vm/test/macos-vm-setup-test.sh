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
stub systemctl 'echo "systemctl $*" >>"$TEST_CALLS"'
stub systemd-tmpfiles 'echo "systemd-tmpfiles $*" >>"$TEST_CALLS"'
stub systemd-sysusers 'echo "systemd-sysusers $*" >>"$TEST_CALLS"'
stub omvm 'echo "omvm $*" >>"$TEST_CALLS"; echo "The one-time macOS step"'
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
  env OMARCHY_MACOS_VM_ROOT="$root" OMARCHY_ESP="$root/boot/efi" OMARCHY_MACOS_VM_SKIP_HW=1 \
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
grep -Fxq boot-update "$calls" || fail "a missing side-kernel entry is built"
grep -q '^boot-check --boot-chain pending=1' "$calls" || fail "the boot chain is checked"
grep -q 'systemctl --global enable omarchy-macos-vm-user.service' "$calls" || fail "the user step is enabled"
grep -q '^omvm macos-step' "$calls" || fail "the macOS step is staged"
[[ ! -e $root/etc/libvirt/hooks/qemu ]] || fail "the libvirt hook is left to the omvm package"
grep -q '^package=omvm' "$root/var/lib/omarchy/macos-vm/done" || fail "the done stamp names the packages" "$(cat "$root/var/lib/omarchy/macos-vm/done")"
grep -q 'systemctl disable omarchy-macos-vm-setup.service' "$calls" || fail "the service disables itself"
grep -q 'BOOT_ORDER\|kernel default' "$calls" && fail "the default boot entry is never changed"
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

for unit in "$package"/files/usr/lib/systemd/system/*.service; do
  grep -Fq 'ConditionPathExists=/etc/omarchy/macos-vm.enabled' "$unit" || fail "$unit is gated on the marker"
done
pass "the system unit is gated on /etc/omarchy/macos-vm.enabled"
