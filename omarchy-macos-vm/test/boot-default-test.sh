#!/bin/bash
# omarchy-macos-vm-boot-default against a staged root and ESP:
# - enable makes linux-aurora-vmapple the persistent default Limine boot entry
#   while keeping stock linux-aurora installed and selectable for recovery;
# - survives normal reboots (no oneshot-restore unit) and limine.conf
#   regeneration / package updates via BOOT_ORDER + omarchy-mac-limine-boot-order;
# - cleans up legacy oneshot-armed state and aligns stale default_entry;
# - disable restores stock linux-aurora cleanly as the default boot entry.

set -euo pipefail

package=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
repo=$(cd -- "$package/.." && pwd)
boot_default=$package/bin/omarchy-macos-vm-boot-default
boot_order_bin=$repo/omarchy-mac-boot/bin/omarchy-mac-limine-boot-order
mac_kernel_bin=$repo/omarchy-mac-boot/bin/omarchy-mac-kernel

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

printf '#!/bin/bash\n[[ -z ${TEST_NOT_LIMINE:-} ]]\n' >"$stub_bin/omarchy-mac-limine-active"
cat >"$stub_bin/pacman" <<'SH'
#!/bin/bash
case $1 in
  -Qq) cat "$TEST_INSTALLED" ;;
  -Q) grep -Fxq -- "$2" "$TEST_INSTALLED" && echo "$2 1-1" ;;
  *) exit 1 ;;
esac
SH
# Simulate real omarchy-mac-boot-update + limine-update: run real
# omarchy-mac-limine-boot-order (when present), then regenerate limine.conf
# ordering //entries according to BOOT_ORDER in /etc/default/limine.
cat >"$stub_bin/omarchy-mac-boot-update" <<'SH'
#!/bin/bash
echo "boot-update" >>"$TEST_CALLS"
if command -v omarchy-mac-limine-boot-order >/dev/null 2>&1; then
  omarchy-mac-limine-boot-order || exit 1
fi
order=$(sed -n -E 's/^[[:space:]]*BOOT_ORDER="([^"]*)".*/\1/p' "$OMARCHY_LIMINE_DEFAULT" | tail -n 1)
first_tok=$(printf '%s\n' "$order" | cut -d, -f1 | tr -d '[:space:]')
mkdir -p "$OMARCHY_ESP/EFI/Linux"
: >"$OMARCHY_ESP/EFI/Linux/omarchy_linux-aurora.efi"
echo uki >"$OMARCHY_ESP/EFI/Linux/omarchy_linux-aurora.efi"
has_side=0
if grep -Fxq linux-aurora-vmapple "$TEST_INSTALLED"; then
  has_side=1
  echo uki >"$OMARCHY_ESP/EFI/Linux/omarchy_linux-aurora-vmapple.efi"
fi
# Preserve existing default_entry if set (as limine-entry-tool preserves menu header).
def=$(sed -n 's/^default_entry:[[:space:]]*//p' "$OMARCHY_ESP/limine.conf" 2>/dev/null | head -1)
{
  printf 'timeout: 1\n'
  printf 'default_entry: %s\n' "${def:-2}"
  printf 'interface_branding: Omarchy Bootloader\n\n'
  printf '/+Omarchy\n'
  printf 'comment: machine-id=d5588c5f\n'
  if (( has_side )) && [[ $first_tok == linux-aurora-vmapple ]]; then
    printf '  //linux-aurora-vmapple\n  protocol: efi\n  path: boot():/EFI/Linux/omarchy_linux-aurora-vmapple.efi\n'
    printf '  //linux-aurora\n  protocol: efi\n  path: boot():/EFI/Linux/omarchy_linux-aurora.efi\n'
  else
    printf '  //linux-aurora\n  protocol: efi\n  path: boot():/EFI/Linux/omarchy_linux-aurora.efi\n'
    if (( has_side )); then
      printf '  //linux-aurora-vmapple\n  protocol: efi\n  path: boot():/EFI/Linux/omarchy_linux-aurora-vmapple.efi\n'
    fi
  fi
} >"$OMARCHY_ESP/limine.conf"
SH
chmod +x "$stub_bin/omarchy-mac-limine-active" "$stub_bin/pacman" "$stub_bin/omarchy-mac-boot-update"
ln -s "$boot_order_bin" "$stub_bin/omarchy-mac-limine-boot-order"
ln -s "$mac_kernel_bin" "$stub_bin/omarchy-mac-kernel"

new_root() {
  root=$test_tmp/root
  rm -rf "$root"
  mkdir -p "$root/boot/efi/EFI/Linux" "$root/etc/default" \
    "$root/usr/share/omarchy-mac-boot/side-kernels.d" "$root/var/lib/omarchy/macos-vm"
  : >"$calls"
  printf 'linux-aurora\nlinux-aurora-vmapple\n' >"$test_tmp/installed"
  : >"$root/usr/share/omarchy-mac-boot/side-kernels.d/linux-aurora-vmapple"
  echo uki >"$root/boot/efi/EFI/Linux/omarchy_linux-aurora.efi"
  echo uki >"$root/boot/efi/EFI/Linux/omarchy_linux-aurora-vmapple.efi"
  cat >"$root/etc/default/limine" <<'CONF'
TARGET_OS_NAME="Omarchy"
ENABLE_UKI=yes
ESP_PATH="/boot/efi"
BOOT_ORDER="linux-aurora, *, *fallback, Snapshots"
KERNEL_CMDLINE[default]+="root=UUID=r rw quiet"
CONF
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
}

first_kernel() {
  awk '{ sub(/^[[:space:]]+/, "") } /^\/\/[^\/]/ { print substr($0, 3); exit }' "$root/boot/efi/limine.conf"
}
run() {
  set +e
  env OMARCHY_MACOS_VM_ROOT="$root" OMARCHY_ESP="$root/boot/efi" \
    OMARCHY_LIMINE_DEFAULT="$root/etc/default/limine" \
    OMARCHY_MAC_DEFAULT_SIDE_KERNEL="$root/etc/omarchy-mac-boot/default-side-kernel" \
    OMARCHY_MAC_SIDE_KERNELS_DIR="$root/usr/share/omarchy-mac-boot/side-kernels.d" \
    TEST_INSTALLED="$test_tmp/installed" TEST_CALLS="$calls" \
    PATH="${TEST_PATH:-$stub_bin}:$PATH" bash "$boot_default" "$@" >"$test_tmp/out" 2>&1
  status=$?
  set -e
}

# 1. Persistent default selection of linux-aurora-vmapple with stock linux-aurora kept selectable.
new_root
run enable
(( status == 0 )) || fail "enable succeeds" "$(cat "$test_tmp/out")"
[[ $(<"$root/etc/omarchy-mac-boot/default-side-kernel") == linux-aurora-vmapple ]] ||
  fail "enable writes /etc/omarchy-mac-boot/default-side-kernel"
grep -Fxq 'BOOT_ORDER="linux-aurora-vmapple, linux-aurora, *, *fallback, Snapshots"' "$root/etc/default/limine" ||
  fail "enable updates BOOT_ORDER with linux-aurora-vmapple first and linux-aurora second" "$(cat "$root/etc/default/limine")"
[[ $(first_kernel) == linux-aurora-vmapple ]] ||
  fail "limine.conf puts linux-aurora-vmapple first" "$(cat "$root/boot/efi/limine.conf")"
grep -Eq '^[[:space:]]*//linux-aurora[[:space:]]*$' "$root/boot/efi/limine.conf" ||
  fail "stock linux-aurora remains selectable in limine.conf" "$(cat "$root/boot/efi/limine.conf")"
grep -Fxq 'default_entry: 2' "$root/boot/efi/limine.conf" ||
  fail "default_entry points at entry 2 (linux-aurora-vmapple)" "$(cat "$root/boot/efi/limine.conf")"
pass "enable makes linux-aurora-vmapple persistent default while keeping stock linux-aurora selectable"

# 2. Idempotent across normal reboots (no oneshot restore reverting it) and limine.conf regeneration.
: >"$calls"
run enable
(( status == 0 )) && [[ ! -s $calls ]] ||
  fail "subsequent reboot enable is a fast no-op without unnecessary boot-update" "$(cat "$calls"; cat "$test_tmp/out")"
# Simulate a package update / limine.conf regeneration (omarchy-mac-boot-update):
OMARCHY_LIMINE_DEFAULT="$root/etc/default/limine" OMARCHY_ESP="$root/boot/efi" \
  OMARCHY_MAC_BOOT_ROOT="$root" \
  OMARCHY_MAC_DEFAULT_SIDE_KERNEL="$root/etc/omarchy-mac-boot/default-side-kernel" \
  OMARCHY_MAC_SIDE_KERNELS_DIR="$root/usr/share/omarchy-mac-boot/side-kernels.d" \
  TEST_INSTALLED="$test_tmp/installed" TEST_CALLS="$calls" \
  PATH="$stub_bin:$PATH" omarchy-mac-boot-update || fail "simulated update succeeds"
[[ $(first_kernel) == linux-aurora-vmapple ]] &&
  grep -Eq '^[[:space:]]*//linux-aurora[[:space:]]*$' "$root/boot/efi/limine.conf" &&
  grep -Fxq 'default_entry: 2' "$root/boot/efi/limine.conf" ||
  fail "persistent default survives limine.conf regeneration / package update" "$(cat "$root/boot/efi/limine.conf")"
pass "persistent default survives normal reboots and limine.conf regeneration"

# 3. Migration from legacy oneshot-armed + default_entry: 3 aligns cleanly to entry 2.
new_root
sed -i 's/^default_entry: 2$/default_entry: 3/' "$root/boot/efi/limine.conf"
printf 'previous=2\nset=3\narmed=2026-11-17T00:00:00Z\n' >"$root/var/lib/omarchy/macos-vm/oneshot-armed"
printf '1\n' >"$root/var/lib/omarchy/macos-vm/oneshot-tries"
run enable
(( status == 0 )) && [[ ! -e $root/var/lib/omarchy/macos-vm/oneshot-armed && ! -e $root/var/lib/omarchy/macos-vm/oneshot-tries ]] &&
  [[ $(first_kernel) == linux-aurora-vmapple ]] &&
  grep -Fxq 'default_entry: 2' "$root/boot/efi/limine.conf" ||
  fail "enable migrates legacy oneshot-armed state and aligns default_entry to entry 2" "$(cat "$test_tmp/out"; cat "$root/boot/efi/limine.conf")"
pass "enable cleanly migrates legacy oneshot-armed state and stale default_entry"

# 4. Clean restoration back to stock linux-aurora default on disable (even while side kernel is still installed).
run disable
(( status == 0 )) || fail "disable succeeds" "$(cat "$test_tmp/out")"
[[ ! -e $root/etc/omarchy-mac-boot/default-side-kernel ]] ||
  fail "disable removes /etc/omarchy-mac-boot/default-side-kernel"
grep -Fxq 'BOOT_ORDER="linux-aurora, *, *fallback, Snapshots"' "$root/etc/default/limine" ||
  fail "disable restores stock BOOT_ORDER" "$(cat "$root/etc/default/limine")"
[[ $(first_kernel) == linux-aurora ]] && grep -Fxq 'default_entry: 2' "$root/boot/efi/limine.conf" ||
  fail "disable puts stock linux-aurora back first as default" "$(cat "$root/boot/efi/limine.conf")"
pass "disable cleanly restores stock linux-aurora as the default boot entry"

# 5. Fallback path when older omarchy-mac-boot lacks omarchy-mac-limine-boot-order.
new_root
fallback_bin=$test_tmp/fallback-bin
mkdir -p "$fallback_bin"
for cmd in omarchy-mac-limine-active pacman omarchy-mac-boot-update omarchy-mac-kernel; do
  cp "$stub_bin/$cmd" "$fallback_bin/$cmd"
done
TEST_PATH="$fallback_bin" run enable
(( status == 0 )) && grep -Fxq 'BOOT_ORDER="linux-aurora-vmapple, linux-aurora, *, *fallback, Snapshots"' "$root/etc/default/limine" &&
  [[ $(first_kernel) == linux-aurora-vmapple ]] ||
  fail "fallback BOOT_ORDER update works without omarchy-mac-limine-boot-order" "$(cat "$test_tmp/out"; cat "$root/etc/default/limine")"
TEST_PATH="$fallback_bin" run disable
(( status == 0 )) && grep -Fxq 'BOOT_ORDER="linux-aurora, *, *fallback, Snapshots"' "$root/etc/default/limine" &&
  [[ $(first_kernel) == linux-aurora ]] ||
  fail "fallback BOOT_ORDER restore works without omarchy-mac-limine-boot-order" "$(cat "$test_tmp/out"; cat "$root/etc/default/limine")"
pass "inline BOOT_ORDER fallback works when omarchy-mac-limine-boot-order is absent"

# 6. Safe no-ops without Limine or without declared/installed side kernel.
new_root
TEST_NOT_LIMINE=1 run enable
(( status == 0 )) && [[ ! -e $root/etc/omarchy-mac-boot/default-side-kernel ]] && [[ $(first_kernel) == linux-aurora ]] ||
  fail "non-Limine Mac is left untouched"
rm -f "$root/usr/share/omarchy-mac-boot/side-kernels.d/linux-aurora-vmapple"
run enable
(( status == 0 )) && [[ ! -e $root/etc/omarchy-mac-boot/default-side-kernel ]] && [[ $(first_kernel) == linux-aurora ]] ||
  fail "undeclared side kernel is not promoted"
pass "non-Limine Macs and undeclared side kernels are safely left untouched"

# 7. Legacy oneshot units/scripts are gone and package install scriptlet is wired.
[[ ! -e $package/bin/omarchy-macos-vm-oneshot-boot ]] &&
  [[ ! -e $package/files/usr/lib/systemd/system/omarchy-macos-vm-oneshot-restore.service ]] &&
  ! grep -q 'oneshot-restore' "$package/files/usr/lib/systemd/system-preset/80-omarchy-macos-vm.preset" &&
  ! grep -q 'oneshot-restore' "$package/files/usr/lib/systemd/system/omarchy-macos-vm-vmxfer.service" ||
  fail "no legacy oneshot-boot or oneshot-restore unit remains in the package"
grep -Fxq 'install=omarchy-macos-vm.install' "$package/pkgbuilds/omarchy-macos-vm/PKGBUILD" &&
  bash -n "$package/pkgbuilds/omarchy-macos-vm/omarchy-macos-vm.install" ||
  fail "PKGBUILD wires a valid omarchy-macos-vm.install scriptlet"
pass "legacy oneshot restore is removed and package install scriptlet is valid"
