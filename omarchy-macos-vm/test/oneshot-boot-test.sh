#!/bin/bash
# omarchy-macos-vm-oneshot-boot against a staged ESP: arm points Limine's
# default entry at linux-aurora-vmapple once, restore puts it back.

set -euo pipefail

package=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
oneshot=$package/bin/omarchy-macos-vm-oneshot-boot
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
stub_bin=$test_tmp/bin
mkdir -p "$stub_bin"
fail() {
  printf 'not ok - %s\n' "$1"
  [[ -z ${2:-} ]] || printf '%s\n' "$2" | sed 's/^/# /'
  exit 1
}
pass() { printf 'ok - %s\n' "$1"; }
printf '#!/bin/bash\n[[ -z ${TEST_NOT_LIMINE:-} ]]\n' >"$stub_bin/omarchy-mac-limine-active"
chmod +x "$stub_bin/omarchy-mac-limine-active"

# The laptop's limine.conf, trimmed: a folder, the stock kernel, the side kernel.
new_esp() {
  root=$test_tmp/root
  rm -rf "$root"
  mkdir -p "$root/boot/efi" "$root/home/alice/.local/share/omvm/images"
  cat >"$root/boot/efi/limine.conf" <<'CONF'
timeout: 1
default_entry: 2
interface_branding: Omarchy Bootloader

/+Omarchy
comment: machine-id=d5588c5f
  //linux-aurora
  protocol: efi
  path: boot():/EFI/Linux/omarchy_linux-aurora.efi
  //linux-aurora-vmapple
  protocol: efi
  path: boot():/EFI/Linux/omarchy_linux-aurora-vmapple.efi
CONF
  cp "$root/boot/efi/limine.conf" "$test_tmp/original.conf"
}
run() {
  set +e
  env OMARCHY_MACOS_VM_ROOT="$root" OMARCHY_ESP="$root/boot/efi" OMARCHY_MACOS_VM_KVM_PARAM="$test_tmp/kvm" \
    PATH="$stub_bin:$PATH" bash "$oneshot" "$@" >"$test_tmp/out" 2>&1
  status=$?
  set -e
}
conf() { cat "$root/boot/efi/limine.conf"; }
state=root/var/lib/omarchy/macos-vm

new_esp
run arm
(( status == 0 )) && grep -Fxq 'default_entry: 3' "$root/boot/efi/limine.conf" &&
  grep -Fxq 'previous=2' "$root/var/lib/omarchy/macos-vm/oneshot-armed" ||
  fail "arm points the default entry at linux-aurora-vmapple" "$(cat "$test_tmp/out"; conf)"
diff <(grep -v '^default_entry:' "$test_tmp/original.conf") <(grep -v '^default_entry:' "$root/boot/efi/limine.conf") >/dev/null ||
  fail "arm changes only the default_entry line"
run arm
(( status == 0 )) && [[ $(cat "$root/var/lib/omarchy/macos-vm/oneshot-tries") == 1 ]] || fail "arming twice is one try"
run restore
(( status == 0 )) && cmp -s "$test_tmp/original.conf" "$root/boot/efi/limine.conf" &&
  [[ ! -e $root/var/lib/omarchy/macos-vm/oneshot-armed ]] ||
  fail "restore puts limine.conf back exactly" "$(cat "$test_tmp/out"; conf)"
pass "arm boots linux-aurora-vmapple once; restore puts linux-aurora back"

run arm
sed -i 's/^default_entry: 3/default_entry: 2/' "$root/boot/efi/limine.conf"
run restore
grep -Fxq 'default_entry: 2' "$root/boot/efi/limine.conf" && [[ ! -e $root/var/lib/omarchy/macos-vm/oneshot-armed ]] ||
  fail "restore leaves a regenerated limine.conf alone"
run arm
(( status == 0 )) && grep -Fxq 'default_entry: 2' "$root/boot/efi/limine.conf" && grep -q 'armed 2 times' "$test_tmp/out" ||
  fail "after two tries arm leaves the menu to the owner" "$(cat "$test_tmp/out")"
pass "a regenerated limine.conf is left alone and there are at most two tries"

new_esp
touch "$test_tmp/kvm"
run arm
grep -Fxq 'default_entry: 2' "$root/boot/efi/limine.conf" || fail "on the side kernel arm does nothing"
rm -f "$test_tmp/kvm"
mkdir -p "$root/home/alice/.local/share/omvm/images/b-v1"
run arm
grep -Fxq 'default_entry: 2' "$root/boot/efi/limine.conf" || fail "with a VM set up arm does nothing"
rm -rf "$root/home/alice/.local/share/omvm/images/b-v1"
TEST_NOT_LIMINE=1 run arm
(( status == 0 )) && grep -Fxq 'default_entry: 2' "$root/boot/efi/limine.conf" || fail "a Mac without Limine is left alone"
sed -i '/linux-aurora-vmapple/d' "$root/boot/efi/limine.conf"
run arm
(( status == 0 )) && grep -Fxq 'default_entry: 2' "$root/boot/efi/limine.conf" || fail "without a side-kernel entry nothing changes"
pass "arm does nothing on the side kernel, once a VM is set up, without Limine or without the entry"
