#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

script="$ROOT/bin/omarchy-mac-limine-boot-order"
hook="$ROOT/files/etc/boot/hooks/pre.d/25-omarchy-mac-boot-order"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

[[ -x $hook ]] && grep -Fq '/usr/bin/omarchy-mac-limine-boot-order' "$hook" ||
  fail "the Limine pre-hook invokes omarchy-mac-limine-boot-order"
pass "25-omarchy-mac-boot-order pre-hook is staged executable"

stub_bin="$test_tmp/bin"
root="$test_tmp/root"
mkdir -p "$stub_bin" "$root/etc/default" "$root/etc/omarchy-mac-boot" "$root/usr/share/omarchy-mac-boot/side-kernels.d"

cat >"$stub_bin/pacman" <<'SH'
#!/bin/bash
[[ $1 == -Qq ]] || exit 1
cat "$TEST_INSTALLED"
SH
chmod +x "$stub_bin/pacman"
ln -s "$ROOT/bin/omarchy-mac-kernel" "$stub_bin/omarchy-mac-kernel"

limine="$root/etc/default/limine"
default_side="$root/etc/omarchy-mac-boot/default-side-kernel"
side_dir="$root/usr/share/omarchy-mac-boot/side-kernels.d"
installed="$test_tmp/installed"

run() {
  OMARCHY_MAC_BOOT_ROOT="$root" \
    OMARCHY_LIMINE_DEFAULT="$limine" \
    OMARCHY_MAC_DEFAULT_SIDE_KERNEL="$default_side" \
    OMARCHY_MAC_SIDE_KERNELS_DIR="$side_dir" \
    TEST_INSTALLED="$installed" \
    PATH="$stub_bin:$PATH" \
    bash "$script" "$@"
}

reset_limine() {
  cat >"$limine" <<'CONF'
TARGET_OS_NAME="Omarchy"
ENABLE_UKI=yes
ESP_PATH="/boot/efi"
BOOT_ORDER="linux-aurora, *, *fallback, Snapshots"
KERNEL_CMDLINE[default]+="root=UUID=abc rw quiet"
CONF
}

# Without default-side-kernel: no-op, touches nothing.
reset_limine
cp "$limine" "$test_tmp/before"
rm -f "$default_side"
run || fail "without default-side-kernel boot-order succeeds"
cmp -s "$limine" "$test_tmp/before" || fail "without default-side-kernel /etc/default/limine is unchanged"
pass "without default-side-kernel, BOOT_ORDER is untouched"

# Declared, installed side kernel: put first, stock linux-aurora second, rest preserved.
printf 'linux-aurora\nlinux-aurora-vmapple\n' >"$installed"
: >"$side_dir/linux-aurora-vmapple"
printf 'linux-aurora-vmapple\n' >"$default_side"
run || fail "reconciling with declared side kernel succeeds"
grep -Fxq 'BOOT_ORDER="linux-aurora-vmapple, linux-aurora, *, *fallback, Snapshots"' "$limine" ||
  fail "BOOT_ORDER puts linux-aurora-vmapple first and keeps linux-aurora second" "$(cat "$limine")"
grep -Fxq 'TARGET_OS_NAME="Omarchy"' "$limine" &&
  grep -Fxq 'KERNEL_CMDLINE[default]+="root=UUID=abc rw quiet"' "$limine" ||
  fail "other keys in /etc/default/limine stay intact" "$(cat "$limine")"
# Idempotent on repeat runs (e.g. every limine-update / package update).
cp "$limine" "$test_tmp/after-enable"
run || fail "second reconcile succeeds"
cmp -s "$limine" "$test_tmp/after-enable" || fail "reconcile is idempotent"
pass "declared installed side kernel leads BOOT_ORDER with stock linux-aurora second"

# Missing BOOT_ORDER line is appended cleanly.
cat >"$limine" <<'CONF'
TARGET_OS_NAME="Omarchy"
ESP_PATH="/boot/efi"
CONF
run || fail "reconciling without an existing BOOT_ORDER line succeeds"
grep -Fxq 'BOOT_ORDER="linux-aurora-vmapple, linux-aurora, *, *fallback, Snapshots"' "$limine" ||
  fail "missing BOOT_ORDER is added with side kernel first and stock second" "$(cat "$limine")"
pass "missing BOOT_ORDER is created cleanly"

# Uninstalled side kernel (e.g. pacman -R linux-aurora-vmapple): stock kernel restored first.
printf 'linux-aurora\n' >"$installed"
rm -f "$side_dir/linux-aurora-vmapple"
run || fail "reconciling after side-kernel uninstall succeeds"
grep -Fxq 'BOOT_ORDER="linux-aurora, *, *fallback, Snapshots"' "$limine" ||
  fail "removing the side kernel restores stock linux-aurora first" "$(cat "$limine")"
pass "uninstalled side kernel falls back cleanly to stock linux-aurora first"

# Undeclared side kernel (installed but missing side-kernels.d marker) is not promoted.
printf 'linux-aurora\nlinux-aurora-vmapple\n' >"$installed"
rm -f "$side_dir/linux-aurora-vmapple"
run || fail "reconciling with undeclared side kernel succeeds"
grep -Fxq 'BOOT_ORDER="linux-aurora, *, *fallback, Snapshots"' "$limine" ||
  fail "undeclared side kernel does not lead BOOT_ORDER" "$(cat "$limine")"
pass "undeclared side kernel is not made default"

# Explicit --restore drops side kernel even while it is still installed, preserving custom entries.
: >"$side_dir/linux-aurora-vmapple"
cat >"$limine" <<'CONF'
ESP_PATH="/boot/efi"
BOOT_ORDER="linux-aurora-vmapple, linux-aurora, linux-zen, *, Snapshots"
CONF
run --restore linux-aurora-vmapple || fail "--restore succeeds"
grep -Fxq 'BOOT_ORDER="linux-aurora, linux-zen, *, Snapshots"' "$limine" ||
  fail "--restore removes side kernel and keeps stock kernel first with custom entries" "$(cat "$limine")"
pass "--restore puts stock linux-aurora first and preserves other entries"

# Write failure aborts limine-entry-tool pre-hook with status >= 100.
reset_limine
printf '#!/bin/bash\nexit 1\n' >"$stub_bin/install"
chmod +x "$stub_bin/install"
status=0
run 2>/dev/null || status=$?
rm -f "$stub_bin/install"
(( status >= 100 )) || fail "a failed write aborts the pre-hook with status >= 100 (got $status)"
pass "write failures abort the UKI rebuild"
