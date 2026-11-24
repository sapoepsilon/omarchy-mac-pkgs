#!/bin/bash
# Fail-closed readiness tests for omarchy-macos-vm (OMA-8):
# Every failed or skipped stage must exit non-zero, never write done/vm-created
# or mark progress ready, and record actionable diagnostics. Basic-tier and
# Apple-services-tier full runs report ready only after every required stage
# succeeds and passes verification.

set -euo pipefail

package=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cli=$package/cli/omarchy-macos-vm
setup_bin=$package/bin/omarchy-macos-vm-setup
user_setup_bin=$package/bin/omarchy-macos-vm-user-setup
vmxfer_bin=$package/bin/omarchy-macos-vm-vmxfer
login_bin=$package/bin/omarchy-macos-vm-login

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
stub() { printf '#!/bin/bash\n%s\n' "$2" >"$stub_bin/$1"; chmod +x "$stub_bin/$1"; }

# --- Part 1: system setup, user-setup, and vmxfer fail-closed checks ---------

stub pacman 'echo "pacman $*" >>"$TEST_CALLS"
case $1 in
  -Q) for p in "${@:2}"; do grep -Fxq "$p" "$TEST_INSTALLED" || exit 1; echo "$p 1-1"; done ;;
  -U) [[ -z ${TEST_PACMAN_FAIL:-} ]] || exit 1
      if [[ -z ${TEST_PACMAN_SKIP:-} ]]; then
        for f in "${@:4}"; do b=${f##*/}; echo "${b%-*-*-*}" >>"$TEST_INSTALLED"; done
      fi ;;
  -S) [[ -z ${TEST_PACMAN_FAIL:-} ]] || exit 1
      if [[ -z ${TEST_PACMAN_SKIP:-} ]]; then
        for p in "${@:4}"; do echo "$p" >>"$TEST_INSTALLED"; done
      fi ;;
esac'
stub pacman-conf 'if [[ $1 == --repo-list ]]; then echo core; else echo "https://mirror.example.invalid/aarch64/core"; fi'
stub getent 'exit 0'
stub curl 'printf 404'
stub lsblk 'if [[ -n ${TEST_VMXFER_DEV:-} ]]; then printf "%s VMXFER\n" "$TEST_VMXFER_DEV"; fi'
stub findmnt 'exit 0'
stub mount 'echo "mount $*" >>"$TEST_CALLS"; [[ -z ${TEST_MOUNT_FAIL:-} ]]'
stub umount 'exit 0'
stub systemd-tmpfiles 'exit 0'
stub systemd-sysusers 'exit 0'
stub systemctl 'echo "systemctl $*" >>"$TEST_CALLS"; [[ $* != *is-active* || -n ${TEST_CREATING:-} ]]'
stub systemd-run 'echo "systemd-run $*" >>"$TEST_CALLS"'
stub omarchy-mac-limine-active 'exit 0'
stub omarchy-mac-boot-update 'printf "/+Omarchy\n  //linux-aurora\n  //linux-aurora-vmapple\n" >"$OMARCHY_ESP/limine.conf"
if [[ -z ${TEST_SKIP_UKI:-} ]]; then
  mkdir -p "$OMARCHY_ESP/EFI/Linux"; echo uki >"$OMARCHY_ESP/EFI/Linux/omarchy_linux-aurora-vmapple.efi"
fi'
stub omarchy-apple-silicon-boot-check 'exit 0'
stub users 'echo "users $*" >>"$TEST_CALLS"'
stub credentials 'echo "credentials $*" >>"$TEST_CALLS"'
stub omvm 'echo "omvm $*" >>"$TEST_CALLS"
case $1 in
  macos-step) [[ -z ${TEST_MACOS_STEP_FAIL:-} ]] || { echo "macos-step boom"; exit 1; }; echo "The one-time macOS step" ;;
  prepare) [[ -z ${TEST_PREPARE_FAIL:-} ]] || exit 1 ;;
  doctor) exit 0 ;;
  mode) [[ -e $TEST_VMDIR/exists ]] && echo remote ;;
  ingest)
    [[ -z ${TEST_INGEST_FAIL:-} ]] || exit 1
    echo "== verifying transfer checksums"
    echo "== unpacking bundle"
    if [[ -z ${TEST_INGEST_SKIP:-} ]]; then
      mkdir -p "$OMVM_IMAGES/b-restore" && touch "$OMVM_IMAGES/b-restore/.ingested"
    fi ;;
  setup)
    [[ -z ${TEST_SETUP_FAIL:-} ]] || exit 1
    echo "==> creating guest account x"
    if [[ -z ${TEST_SETUP_SKIP:-} ]]; then
      mkdir -p "$OMVM_IMAGES/b-v0"
    fi ;;
  virt)
    if [[ $* == *--experimental-apple-services* ]]; then
      [[ -z ${TEST_APPLE_VIRT_FAIL:-} ]] || exit 1
      if [[ -z ${TEST_APPLE_VIRT_SKIP:-} ]]; then
        mkdir -p "$OMVM_IMAGES/vms/$2"
        touch "$OMVM_IMAGES/vms/$2/apple_services"
        touch "$TEST_VMDIR/apple_xml"
      fi
    else
      [[ -z ${TEST_VIRT_FAIL:-} ]] || exit 1
      if [[ -z ${TEST_VIRT_SKIP:-} ]]; then
        touch "$TEST_VMDIR/exists"
      fi
    fi ;;
  ssh)
    if [[ $3 == true ]]; then
      [[ -z ${TEST_SSH_FAIL:-} ]] || exit 1
    else
      echo "\"IOPlatformUUID\" = \"11111111-2222-3333-4444-555555555555\""
    fi ;;
  stop) exit 0 ;;
esac'
stub virsh 'echo "virsh $*" >>"$TEST_CALLS"
case "$*" in
  *domstate*) echo "${TEST_VM_STATE:-running}" ;;
  *dumpxml*)
    if [[ -e $TEST_VMDIR/apple_xml ]]; then
      echo "relay-socket=/run/omvm-fairplay-managed-macos/fp.sock"
    fi ;;
  *start*) echo running >"$TEST_VMDIR/state" ;;
esac'
stub sudo '"$@"'
stub omarchy-notification-send 'printf "notify %s\n" "$*" >>"$TEST_CALLS"'
stub gum 'shift; while [[ $1 == --* ]]; do shift 2; done; printf "%s\n" "$@"'

# 1a. Stack install silent skip (pacman exits 0 without installing packages)
root=$test_tmp/root-skip-pkg
mkdir -p "$root/etc/omarchy" "$root/var/lib/pacman" "$root/boot/efi"
printf '[options]\n' >"$root/etc/pacman.conf"
printf '{"version":1,"requested_by":"installer"}\n' >"$root/etc/omarchy/macos-vm.enabled"
: >"$test_tmp/installed"
set +e
env -u HOME OMARCHY_MACOS_VM_ROOT="$root" OMARCHY_ESP="$root/boot/efi" OMARCHY_MACOS_VM_SKIP_HW=1 \
  OMARCHY_MACOS_VM_USERS="$stub_bin/users" OMARCHY_MACOS_VM_CREDENTIALS="$stub_bin/credentials" \
  OMARCHY_MACOS_VM_NETWORK_WAIT=0 TEST_CALLS="$calls" TEST_INSTALLED="$test_tmp/installed" \
  TEST_PACMAN_SKIP=1 PATH="$stub_bin:$PATH" bash "$setup_bin" >"$test_tmp/out" 2>&1
status=$?
set -e
(( status == 75 )) && [[ ! -e $root/var/lib/omarchy/macos-vm/done ]] &&
  grep -Fq 'stack=failed' "$root/var/lib/omarchy/macos-vm/stages" &&
  grep -Fq 'missing after install' "$root/var/lib/omarchy/macos-vm/last-error" ||
  fail "skipped pacman install fails closed without writing done" "status=$status $(cat "$test_tmp/out")"
pass "stack install silent skip exits non-zero, records stack=failed and leaves no done stamp"

# 1b. Missing side-kernel UKI fails closed
root=$test_tmp/root-skip-uki
mkdir -p "$root/etc/omarchy" "$root/var/lib/pacman" "$root/boot/efi"
printf '[options]\n' >"$root/etc/pacman.conf"
printf '{"version":1,"requested_by":"installer"}\n' >"$root/etc/omarchy/macos-vm.enabled"
: >"$test_tmp/installed"
set +e
env -u HOME OMARCHY_MACOS_VM_ROOT="$root" OMARCHY_ESP="$root/boot/efi" OMARCHY_MACOS_VM_SKIP_HW=1 \
  OMARCHY_MACOS_VM_USERS="$stub_bin/users" OMARCHY_MACOS_VM_CREDENTIALS="$stub_bin/credentials" \
  OMARCHY_MACOS_VM_NETWORK_WAIT=0 TEST_CALLS="$calls" TEST_INSTALLED="$test_tmp/installed" \
  TEST_SKIP_UKI=1 PATH="$stub_bin:$PATH" bash "$setup_bin" >"$test_tmp/out" 2>&1
status=$?
set -e
(( status == 1 )) && [[ ! -e $root/var/lib/omarchy/macos-vm/done ]] &&
  grep -Fq 'boot=failed' "$root/var/lib/omarchy/macos-vm/stages" &&
  grep -Fq 'missing linux-aurora-vmapple UKI' "$root/var/lib/omarchy/macos-vm/last-error" ||
  fail "missing side-kernel UKI fails closed without writing done" "status=$status $(cat "$test_tmp/out")"
pass "missing side-kernel UKI exits 1, records boot=failed and leaves no done stamp"

# 1c. Failed omvm macos-step fails closed
root=$test_tmp/root-fail-step
mkdir -p "$root/etc/omarchy" "$root/var/lib/pacman" "$root/boot/efi"
printf '[options]\n' >"$root/etc/pacman.conf"
printf '{"version":1,"requested_by":"installer"}\n' >"$root/etc/omarchy/macos-vm.enabled"
: >"$test_tmp/installed"
set +e
env -u HOME OMARCHY_MACOS_VM_ROOT="$root" OMARCHY_ESP="$root/boot/efi" OMARCHY_MACOS_VM_SKIP_HW=1 \
  OMARCHY_MACOS_VM_USERS="$stub_bin/users" OMARCHY_MACOS_VM_CREDENTIALS="$stub_bin/credentials" \
  OMARCHY_MACOS_VM_NETWORK_WAIT=0 TEST_CALLS="$calls" TEST_INSTALLED="$test_tmp/installed" \
  TEST_MACOS_STEP_FAIL=1 PATH="$stub_bin:$PATH" bash "$setup_bin" >"$test_tmp/out" 2>&1
status=$?
set -e
(( status == 1 )) && [[ ! -e $root/var/lib/omarchy/macos-vm/done ]] &&
  grep -Fq 'macos_step=failed' "$root/var/lib/omarchy/macos-vm/stages" &&
  grep -Fq 'omvm macos-step failed' "$root/var/lib/omarchy/macos-vm/last-error" ||
  fail "failed omvm macos-step fails closed" "status=$status $(cat "$test_tmp/out")"
pass "failed omvm macos-step exits 1, records macos_step=failed and leaves no done stamp"

# 1d. Per-user setup launcher failure fails closed
uhome=$test_tmp/uhome-launcher-fail
mkdir -p "$uhome/.local/share/applications/macos-vm.desktop"
set +e
env -u XDG_STATE_HOME -u XDG_DATA_HOME HOME="$uhome" TEST_CALLS="$calls" PATH="$stub_bin:$PATH" \
  bash "$user_setup_bin" >"$test_tmp/out" 2>&1
status=$?
set -e
(( status == 1 )) && [[ ! -e $uhome/.local/state/omarchy-macos-vm/done ]] &&
  grep -Fq 'could not create or verify launcher' "$uhome/.local/state/omarchy-macos-vm/user-setup-error" ||
  fail "user-setup launcher failure must not write done" "status=$status $(cat "$test_tmp/out")"
pass "omarchy-macos-vm-user-setup fails closed when launcher creation fails"

# 1e. VMXFER mount failure clears stale vmxfer-ready and exits non-zero
root=$test_tmp/root-vmxfer-fail
mkdir -p "$root/var/lib/omarchy/macos-vm"
touch "$root/var/lib/omarchy/macos-vm/vmxfer-ready"
set +e
env OMARCHY_MACOS_VM_ROOT="$root" OMARCHY_MACOS_VM_VMXFER_MNT="$test_tmp/vmxfer-mnt" \
  OMARCHY_MACOS_VM_CREDENTIALS="$stub_bin/credentials" TEST_CALLS="$calls" \
  TEST_VMXFER_DEV=/dev/nvme0n1p3 TEST_MOUNT_FAIL=1 PATH="$stub_bin:$PATH" \
  bash "$vmxfer_bin" >"$test_tmp/out" 2>&1
status=$?
set -e
(( status == 1 )) && [[ ! -e $root/var/lib/omarchy/macos-vm/vmxfer-ready ]] &&
  grep -Fq 'cannot mount /dev/nvme0n1p3' "$root/var/lib/omarchy/macos-vm/vmxfer-error" ||
  fail "vmxfer mount failure must clear stale stamp and exit non-zero" "status=$status $(cat "$test_tmp/out")"
pass "omarchy-macos-vm-vmxfer mount failure clears stale stamp, records error and exits 1"

# --- Part 2: CLI create / progress / status / launch / login fail-closed -----

state=$test_tmp/state
vm=$test_tmp/vm
home=$test_tmp/home
images=$home/.local/share/omvm/images
kvm_param=$test_tmp/emulate_nisv_ldst
marker=$test_tmp/marker
apple_sep_conf=$test_tmp/apple/sep-identity.conf
apple_template=$test_tmp/apple/apple-helpers.template.json
apple_qemu=$test_tmp/apple/qemu-system-aarch64
apple_helper=$test_tmp/apple/apple-helper
user_state=$home/.local/state/omarchy-macos-vm
progress=$user_state/progress
stages=$user_state/stages
vm_created=$user_state/vm-created
desktop_file=$home/.local/share/applications/macos-vm.desktop

reset_cli() {
  rm -rf "$state" "$vm" "$home" "$kvm_param" "$marker" "$test_tmp/apple" "$test_tmp/run"
  mkdir -p "$state" "$vm" "$home" "$test_tmp/run"
  : >"$calls"
}

run_cli() {
  : >"$calls"
  set +e
  env PATH="$stub_bin:$PATH" TEST_CALLS="$calls" TEST_VMDIR="$vm" \
    HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$home/.local/state" XDG_DATA_HOME="$home/.local/share" \
    XDG_RUNTIME_DIR="$test_tmp/run" OMVM_IMAGES="$images" OMARCHY_MACOS_VM_STATE="$state" \
    OMARCHY_MACOS_VM_MARKER="$marker" \
    OMARCHY_MACOS_VM_APPLE_SEP_CONF="$apple_sep_conf" \
    OMARCHY_MACOS_VM_APPLE_TEMPLATE="$apple_template" \
    OMVM_APPLE_QEMU="$apple_qemu" \
    OMARCHY_MACOS_VM_APPLE_HELPER="$apple_helper" \
    OMARCHY_MACOS_VM_KVM_PARAM="$kvm_param" OMARCHY_MACOS_VM_REQUIRED_GB=0 OMARCHY_MACOS_VM_NOTIFY_WAIT=0 \
    OMARCHY_MACOS_VM_NO_LAUNCH=1 OMARCHY_MACOS_VM_PROGRESS_POLL=0 \
    bash "$cli" "$@" >"$test_tmp/out" 2>&1
  status=$?
  set -e
}

run_login_cli() {
  : >"$calls"
  set +e
  env PATH="$stub_bin:$PATH" TEST_CALLS="$calls" TEST_VMDIR="$vm" \
    HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$home/.local/state" XDG_DATA_HOME="$home/.local/share" \
    OMVM_IMAGES="$images" OMARCHY_MACOS_VM_STATE="$state" \
    OMARCHY_MACOS_VM_MARKER="$marker" \
    OMARCHY_MACOS_VM_APPLE_SEP_CONF="$apple_sep_conf" \
    OMARCHY_MACOS_VM_APPLE_TEMPLATE="$apple_template" \
    OMVM_APPLE_QEMU="$apple_qemu" \
    OMARCHY_MACOS_VM_KVM_PARAM="$kvm_param" OMARCHY_MACOS_VM_NOTIFY_WAIT=0 \
    bash "$login_bin" >"$test_tmp/login_out" 2>&1
  login_status=$?
  set -e
}

pval() { sed -n "s/^$1=//p" "$progress" 2>/dev/null | tail -1; }
sval() { sed -n "s/^$1=//p" "$stages" 2>/dev/null | tail -1; }

assert_not_ready() {
  local label=$1
  [[ ! -e $vm_created ]] || fail "$label: vm-created must not exist" "$(cat "$test_tmp/out")"
  ! grep -q '^notify macOS VM ready' "$calls" || fail "$label: must not send ready notification" "$(cat "$calls")"
  [[ $(pval stage) != ready ]] || fail "$label: progress stage must not be ready" "$(cat "$progress")"
}

install_apple_prereqs() {
  mkdir -p "$test_tmp/apple" "$home/.config/omvm/apple-services"
  echo 'SEP_IDENTITY_PUBLIC_KEY=/var/lib/sep.pub' >"$apple_sep_conf"
  echo '{"provider":{}}' >"$apple_template"
  echo '{"socket":"/run/omvm-identity/sep.sock"}' >"$home/.config/omvm/apple-services/identity-provider.json"
  printf '#!/bin/bash\nexit 0\n' >"$apple_qemu"; chmod +x "$apple_qemu"
  printf '#!/bin/bash\necho "apple-helper $*" >>"$TEST_CALLS"\n[[ -z ${TEST_APPLE_HELPER_FAIL:-} ]]\n' >"$apple_helper"
  chmod +x "$apple_helper"
}

# 2a. Stack not installed -> create fails closed
reset_cli
printf 'stage=failed\nfailed_stage=stack\n' >"$state/status"
printf 'pacman -U failed\n' >"$state/last-error"
run_cli create --auto
(( status == 1 )) && [[ $(pval stage) == failed && $(pval failed_stage) == stack && $(sval stack) == failed ]] &&
  grep -Fq 'pacman -U failed' "$test_tmp/out" ||
  fail "missing stack done must fail closed with stack diagnostic" "status=$status $(cat "$test_tmp/out"; cat "$progress")"
assert_not_ready "missing stack"
run_cli progress
(( status == 1 )) && grep -Fq 'pacman -U failed' "$test_tmp/out" && ! grep -Fq 'macOS VM ready' "$test_tmp/out" ||
  fail "progress must show stack failure" "$(cat "$test_tmp/out")"
run_cli status
(( status == 1 )) && grep -Fq 'pacman -U failed' "$test_tmp/out" || fail "status must report stack failure" "$(cat "$test_tmp/out")"
pass "stack install failure stops create, progress, and status with diagnostics"

# 2b. VMXFER ingest failure & silent skip
reset_cli
touch "$state/done" "$state/vmxfer-ready" "$kvm_param"
TEST_INGEST_FAIL=1 run_cli create --auto
(( status == 1 )) && [[ $(pval stage) == failed && $(pval failed_stage) == ingest && $(sval ingest) == failed ]] ||
  fail "omvm ingest failure must fail closed" "status=$status $(cat "$test_tmp/out"; cat "$progress")"
assert_not_ready "ingest fail"

reset_cli
touch "$state/done" "$state/vmxfer-ready" "$kvm_param"
TEST_INGEST_SKIP=1 run_cli create --auto
(( status == 1 )) && [[ $(pval stage) == failed && $(pval failed_stage) == ingest && $(sval ingest) == skipped ]] &&
  grep -Fq '.ingested' "$progress" ||
  fail "omvm ingest silent skip must fail closed" "status=$status $(cat "$test_tmp/out"; cat "$progress")"
assert_not_ready "ingest skip"
pass "vmxfer ingest failure and silent skip both fail closed with ingest diagnostics"

# 2c. Wrong kernel (not on side kernel)
reset_cli
touch "$state/done" "$state/vmxfer-ready"
run_cli create --auto
(( status == 2 )) && [[ $(pval stage) == restart-needed && $(sval kernel) == restart-needed ]] ||
  fail "wrong kernel must stop non-zero with restart-needed" "status=$status $(cat "$test_tmp/out"; cat "$progress")"
assert_not_ready "wrong kernel"
run_cli progress
(( status == 0 )) && grep -Fq 'Restart needed' "$test_tmp/out" && ! grep -Fq 'macOS VM ready' "$test_tmp/out" ||
  fail "progress on wrong kernel must never claim ready" "$(cat "$test_tmp/out")"
pass "wrong kernel exits non-zero (2), records kernel=restart-needed and never reports ready"

# 2d. omvm setup failure & silent skip
reset_cli
touch "$state/done" "$state/vmxfer-ready" "$kvm_param"
TEST_SETUP_FAIL=1 run_cli create --auto
(( status == 1 )) && [[ $(pval stage) == failed && $(pval failed_stage) == setup && $(sval setup) == failed ]] ||
  fail "omvm setup failure must fail closed" "status=$status $(cat "$test_tmp/out"; cat "$progress")"
assert_not_ready "setup fail"

reset_cli
touch "$state/done" "$state/vmxfer-ready" "$kvm_param"
TEST_SETUP_SKIP=1 run_cli create --auto
(( status == 1 )) && [[ $(pval stage) == failed && $(pval failed_stage) == setup && $(sval setup) == skipped ]] &&
  grep -Fq '*-v0' "$progress" ||
  fail "omvm setup silent skip must fail closed" "status=$status $(cat "$test_tmp/out"; cat "$progress")"
assert_not_ready "setup skip"
pass "omvm setup failure and silent skip both fail closed with setup diagnostics"

# 2e. omvm virt failure & silent skip
reset_cli
touch "$state/done" "$state/vmxfer-ready" "$kvm_param"
TEST_VIRT_FAIL=1 run_cli create --auto
(( status == 1 )) && [[ $(pval stage) == failed && $(pval failed_stage) == virt && $(sval virt) == failed ]] ||
  fail "omvm virt failure must fail closed" "status=$status $(cat "$test_tmp/out"; cat "$progress")"
assert_not_ready "virt fail"

reset_cli
touch "$state/done" "$state/vmxfer-ready" "$kvm_param"
TEST_VIRT_SKIP=1 run_cli create --auto
(( status == 1 )) && [[ $(pval stage) == failed && $(pval failed_stage) == virt && $(sval virt) == skipped ]] &&
  grep -Fq 'without defining VM' "$progress" ||
  fail "omvm virt silent skip must fail closed" "status=$status $(cat "$test_tmp/out"; cat "$progress")"
assert_not_ready "virt skip"
pass "omvm virt failure and silent skip both fail closed with virt diagnostics"

# 2f. Launcher creation failure (even though vm_exists is now true!)
reset_cli
touch "$state/done" "$state/vmxfer-ready" "$kvm_param"
mkdir -p "$desktop_file"
run_cli create --auto
(( status == 1 )) && [[ $(pval stage) == failed && $(pval failed_stage) == launcher && $(sval launcher) == failed ]] ||
  fail "launcher creation failure must fail closed" "status=$status $(cat "$test_tmp/out"; cat "$progress")"
assert_not_ready "launcher fail"
run_cli progress
(( status == 1 )) && grep -Fq 'Failed (launcher)' "$test_tmp/out" && ! grep -Fq 'macOS VM ready' "$test_tmp/out" ||
  fail "progress must NOT report ready when launcher failed despite vm_exists" "$(cat "$test_tmp/out")"
run_cli status
(( status == 1 )) && grep -Fq 'stage: launcher' "$test_tmp/out" ||
  fail "status must fail when launcher failed despite vm_exists" "$(cat "$test_tmp/out")"
run_cli launch
(( status == 1 )) && grep -Fq 'failed at launcher' "$test_tmp/out" ||
  fail "launch must refuse incomplete VM when launcher failed" "$(cat "$test_tmp/out")"
run_login_cli
(( login_status == 1 )) && [[ ! -e $vm_created ]] ||
  fail "login helper must NOT write vm-created when launcher failed" "status=$login_status $(cat "$test_tmp/login_out")"
# Fix launcher collision and retry -> succeeds cleanly
rmdir "$desktop_file"
run_cli create --auto
(( status == 0 )) && [[ -s $vm_created && $(pval stage) == ready && $(sval launcher) == ok ]] ||
  fail "retrying create after fixing launcher must finish ready" "status=$status $(cat "$test_tmp/out"; cat "$progress")"
pass "launcher creation failure fails closed across create/progress/status/launch/login and recovers on retry"

# 2g. Requested Apple services skipped due to missing prerequisites (flag, marker, and partial files)
reset_cli
touch "$state/done" "$state/vmxfer-ready" "$kvm_param"
run_cli create --auto --apple-services
(( status == 1 )) && [[ $(pval stage) == failed && $(pval failed_stage) == apple_services && $(pval tier) == apple-services && $(sval apple_services) == skipped ]] &&
  grep -Fq 'prerequisites are missing' "$progress" && grep -Fq 'apple-services import' "$progress" ||
  fail "requested apple-services with missing prereqs must fail closed" "status=$status $(cat "$test_tmp/out"; cat "$progress")"
assert_not_ready "apple-services missing prereqs via flag"
run_cli progress
(( status == 1 )) && grep -Fq 'Failed (apple_services)' "$test_tmp/out" && ! grep -Fq 'macOS VM ready' "$test_tmp/out" ||
  fail "progress must NOT report ready when requested apple-services was skipped" "$(cat "$test_tmp/out")"
run_cli status
(( status == 1 )) && grep -Fq 'stage: apple_services' "$test_tmp/out" ||
  fail "status must fail when requested apple-services was skipped" "$(cat "$test_tmp/out")"
run_cli launch
(( status == 1 )) || fail "launch must fail when requested apple-services was skipped" "$(cat "$test_tmp/out")"
run_login_cli
(( login_status == 1 )) && [[ ! -e $vm_created ]] ||
  fail "login helper must NOT write vm-created when apple-services was skipped" "status=$login_status"

# Partial host apple-services files (only sep-identity.conf present) must also fail closed, never silently skip
reset_cli
touch "$state/done" "$state/vmxfer-ready" "$kvm_param"
mkdir -p "$test_tmp/apple"
echo 'SEP_IDENTITY_PUBLIC_KEY=/var/lib/sep.pub' >"$apple_sep_conf"
run_cli create --auto
(( status == 1 )) && [[ $(pval stage) == failed && $(pval failed_stage) == apple_services && $(sval apple_services) == skipped ]] ||
  fail "partial apple-services prereqs must fail closed instead of silently skipping" "status=$status $(cat "$test_tmp/out"; cat "$progress")"
assert_not_ready "partial apple-services prereqs"

# Marker-requested apple-services with missing prereqs must also fail closed
reset_cli
touch "$state/done" "$state/vmxfer-ready" "$kvm_param"
printf '{"version":1,"requested_by":"installer","apple_services":true}\n' >"$marker"
run_cli create --auto
(( status == 1 )) && [[ $(pval stage) == failed && $(pval failed_stage) == apple_services && $(sval apple_services) == skipped ]] ||
  fail "marker-requested apple-services with missing prereqs must fail closed" "status=$status $(cat "$test_tmp/out"; cat "$progress")"
assert_not_ready "marker apple-services missing prereqs"
pass "requested/partial Apple services with missing prerequisites fails closed across all views"

# 2h. Requested Apple services enablement fails (helper error) & silent skip (virt omits apple_services)
reset_cli
touch "$state/done" "$state/vmxfer-ready" "$kvm_param"
install_apple_prereqs
TEST_APPLE_HELPER_FAIL=1 run_cli create --auto --apple-services
(( status == 1 )) && [[ $(pval stage) == failed && $(pval failed_stage) == apple_services && $(sval apple_services) == failed ]] ||
  fail "apple-services enablement error must fail closed" "status=$status $(cat "$test_tmp/out"; cat "$progress")"
assert_not_ready "apple-services helper fail"
run_cli progress
(( status == 1 )) && grep -Fq 'Apple services enablement' "$test_tmp/out" && ! grep -Fq 'macOS VM ready' "$test_tmp/out" ||
  fail "progress must show Apple services failure" "$(cat "$test_tmp/out")"

reset_cli
touch "$state/done" "$state/vmxfer-ready" "$kvm_param"
install_apple_prereqs
TEST_APPLE_VIRT_SKIP=1 run_cli create --auto --apple-services
(( status == 1 )) && [[ $(pval stage) == failed && $(pval failed_stage) == apple_services ]] ||
  fail "apple-services silent skip (no relay XML / marker) must fail closed" "status=$status $(cat "$test_tmp/out"; cat "$progress")"
assert_not_ready "apple-services silent skip"

# Retry with working Apple services -> completes cleanly with Apple services tier ready
run_cli create --auto --apple-services
(( status == 0 )) && [[ -s $vm_created && $(pval stage) == ready && $(pval percent) == 100 &&
  $(pval tier) == apple-services && $(sval apple_services) == ok && $(sval launcher) == ok ]] ||
  fail "clean apple-services retry must succeed and report ready" "status=$status $(cat "$test_tmp/out"; cat "$progress"; cat "$stages")"
run_cli progress
(( status == 0 )) && grep -Fq 'macOS VM ready: open it from Super + Space' "$test_tmp/out" &&
  grep -Fq 'Apple services: enabled' "$test_tmp/out" ||
  fail "progress must show ready with Apple services enabled" "$(cat "$test_tmp/out")"
run_cli status
(( status == 0 )) && grep -Fq 'Apple services: enabled' "$test_tmp/out" ||
  fail "status must show Apple services enabled" "$(cat "$test_tmp/out")"
pass "Apple services failure/skip fails closed, and clean Apple services run reports ready only after verification"

# 2i. Stale stage=ready must still fail closed if a required artifact disappears
rm -f "$desktop_file"
run_cli progress
(( status == 1 )) && grep -Fq 'VM is not ready' "$test_tmp/out" && ! grep -Fq 'macOS VM ready' "$test_tmp/out" ||
  fail "progress must not trust stale stage=ready when launcher is missing" "$(cat "$test_tmp/out")"
run_cli status
(( status == 1 )) && grep -Fq 'incomplete' "$test_tmp/out" ||
  fail "status must fail closed when launcher is missing" "$(cat "$test_tmp/out")"
pass "progress and status fail closed even if progress file has stale stage=ready"

# 2j. Clean full basic-tier setup run (no Apple services requested/present)
reset_cli
touch "$state/done" "$state/vmxfer-ready" "$kvm_param"
run_cli create --auto
(( status == 0 )) || fail "clean basic-tier create must succeed" "status=$status $(cat "$test_tmp/out")"
[[ -s $vm_created && $(pval stage) == ready && $(pval percent) == 100 && $(pval tier) == basic ]] ||
  fail "clean basic-tier run must write vm-created and ready progress" "$(cat "$progress")"
for st in stack credentials ingest kernel setup virt launcher; do
  [[ $(sval "$st") == ok ]] || fail "clean basic-tier run must record $st=ok" "$(cat "$stages")"
done
[[ $(sval apple_services) == not-requested ]] || fail "clean basic-tier run must record apple_services=not-requested" "$(cat "$stages")"
grep -q '^notify macOS VM ready — open it from Super+Space' "$calls" ||
  fail "clean basic-tier run must send ready notification" "$(cat "$calls")"
run_cli progress
(( status == 0 )) && grep -Fq 'macOS VM ready: open it from Super + Space' "$test_tmp/out" &&
  ! grep -Fq 'Apple services: enabled' "$test_tmp/out" ||
  fail "clean basic-tier progress must report basic ready without claiming Apple services" "$(cat "$test_tmp/out")"
run_cli status
(( status == 0 )) && ! grep -Fq 'Apple services: enabled' "$test_tmp/out" ||
  fail "clean basic-tier status must succeed without claiming Apple services" "$(cat "$test_tmp/out")"
pass "clean full basic-tier run writes ready only after all required basic stages succeed"
