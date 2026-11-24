#!/bin/bash
# omarchy-macos-vm's progress: create records its stage, the launcher shows it
# while the VM is being made, and the progress view ends at each wait or result.

set -euo pipefail

package=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
command=$package/cli/omarchy-macos-vm
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
stub_bin=$test_tmp/bin
log=$test_tmp/calls
mkdir -p "$stub_bin"

fail() {
  printf 'not ok - %s\n' "$1"
  [[ -z ${2:-} ]] || printf '%s\n' "$2" | sed 's/^/# /'
  exit 1
}
pass() { printf 'ok - %s\n' "$1"; }
stub() { printf '#!/bin/bash\n%s\n' "$2" >"$stub_bin/$1"; chmod +x "$stub_bin/$1"; }

state=$test_tmp/state
vm=$test_tmp/vm
home=$test_tmp/home
images=$home/.local/share/omvm/images
kvm_param=$test_tmp/emulate_nisv_ldst
progress=$home/.local/state/omarchy-macos-vm/progress
default_side=$test_tmp/default-side-kernel
marker=$test_tmp/macos-vm.enabled

stub omarchy-notification-send 'printf "notify %s\n" "$*" >>"$TEST_LOG"'
stub systemd-run 'echo "systemd-run $*" >>"$TEST_LOG"'
stub systemctl 'echo "systemctl $*" >>"$TEST_LOG"; [[ $* != *is-active* || -n ${TEST_CREATING:-} ]]'
stub virsh 'cat "$TEST_VMDIR/state" 2>/dev/null'
stub omvm 'echo "omvm $*" >>"$TEST_LOG"
case $1 in
  mode) [[ -e $TEST_VMDIR/exists ]] && echo remote ;;
  ingest) echo "== verifying transfer checksums"; echo "== unpacking bundle"; echo "== wrote vm.env"
          mkdir -p "$OMVM_IMAGES/b-restore" && touch "$OMVM_IMAGES/b-restore/.ingested" ;;
  setup) echo "==> creating guest account x"; [[ -z ${TEST_SETUP_FAIL:-} ]] || exit 1; mkdir -p "$OMVM_IMAGES/b-v0" ;;
  virt) touch "$TEST_VMDIR/exists" ;;
esac'

run_cmd() {
  : >"$log"
  set +e
  env PATH="$stub_bin:$PATH" TEST_LOG="$log" TEST_VMDIR="$vm" \
    HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$home/.local/state" XDG_DATA_HOME="$home/.local/share" \
    XDG_RUNTIME_DIR="$test_tmp/run" OMVM_IMAGES="$images" OMARCHY_MACOS_VM_STATE="$state" \
    OMARCHY_MACOS_VM_MARKER="$marker" OMARCHY_MAC_DEFAULT_SIDE_KERNEL="$default_side" \
    OMARCHY_MACOS_VM_BOOT_DEFAULT="${TEST_BOOT_DEFAULT:-$stub_bin/boot-default}" \
    OMARCHY_MACOS_VM_APPLE_SEP_CONF="$test_tmp/no-sep-conf" \
    OMARCHY_MACOS_VM_APPLE_TEMPLATE="$test_tmp/no-apple-template" \
    OMVM_APPLE_QEMU="$test_tmp/no-apple-qemu" \
    OMARCHY_MACOS_VM_APPLE_HELPER="$test_tmp/no-apple-helper" \
    OMARCHY_MACOS_VM_KVM_PARAM="$kvm_param" OMARCHY_MACOS_VM_REQUIRED_GB=0 OMARCHY_MACOS_VM_NOTIFY_WAIT=0 \
    OMARCHY_MACOS_VM_NO_LAUNCH=1 OMARCHY_MACOS_VM_PROGRESS_POLL=0 \
    bash "$command" "$@" >"$test_tmp/out" 2>&1
  status=$?
  set -e
}
reset() { rm -rf "$state" "$vm" "$home" "$kvm_param" "$default_side" "$marker" "$test_tmp/run"; mkdir -p "$state" "$vm" "$test_tmp/run"; }
value() { sed -n "s/^$1=//p" "$progress"; }

# create on the stock kernel: the import moves the progress on, then waits for the restart.
reset
touch "$state/done" "$state/vmxfer-ready"
printf 'linux-aurora-vmapple\n' >"$default_side"
run_cmd create --auto
(( status == 2 )) || fail "create on the stock kernel stops for the restart (exit 2)" "$(cat "$test_tmp/out")"
[[ $(value stage) == restart-needed && $(value percent) == 35 ]] || fail "the progress says a restart is needed" "$(cat "$progress")"
grep -Fxq '== unpacking bundle' "$home/.local/state/omarchy-macos-vm/create.log" || fail "omvm's output goes to the create log"
grep -q '^notify .*restart to finish Restart once: Omarchy starts linux-aurora-vmapple by default' "$log" || fail "create asks for one restart" "$(cat "$log")"
run_cmd progress
(( status == 0 )) && grep -Fq '[x] Importing' "$test_tmp/out" && grep -Fq '[>] Restart needed' "$test_tmp/out" &&
  grep -Fq 'Restart needed. Restart once: Omarchy starts linux-aurora-vmapple by default' "$test_tmp/out" || fail "the progress view ends at Restart needed" "$(cat "$test_tmp/out")"
pass "create records Importing, then Restart needed, and the progress view says so"

# On the side kernel: Setting up, then Ready.
touch "$kvm_param"
run_cmd create --auto
(( status == 0 )) && [[ $(value stage) == ready && $(value percent) == 100 ]] || fail "create ends Ready at 100%" "$(cat "$test_tmp/out")"
grep -q '^notify macOS VM ready — open it from Super+Space' "$log" || fail "create says the VM is ready" "$(cat "$log")"
run_cmd progress
(( status == 0 )) && grep -Fq 'macOS VM ready: open it from Super + Space' "$test_tmp/out" || fail "the progress view ends at Ready" "$(cat "$test_tmp/out")"
pass "on the side kernel create records Setting up and Ready"

# The account: create --auto without one stored uses this user's name and "macos",
# keeps them 0600 for the owner, hands them to omvm, and shows them when Ready.
creds=$home/.config/omarchy/macos-vm-credentials
me=$(id -un); [[ $me =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || me=macos
[[ $(<"$creds") == $'USERNAME='"$me"$'\nPASSWORD=macos' ]] || fail "create --auto stores the default account" "$(cat "$creds")"
[[ $(stat -c %a "$creds") == 600 ]] || fail "the credentials file is 0600"
[[ $(<"$home/.local/share/omvm/guest-password") == macos && $(stat -c %a "$home/.local/share/omvm/guest-password") == 600 ]] ||
  fail "omvm gets the password in its 0600 guest-password"
grep -Fxq "OMVM_GUEST_USER=$me" "$home/.config/omvm/gui.env" || fail "omvm gets the username in gui.env"
grep -Fq "  Username:  $me" "$test_tmp/out" && grep -Fq '  Password:  macos' "$test_tmp/out" ||
  fail "the Ready screen shows the username and password" "$(cat "$test_tmp/out")"
pass "create --auto defaults to this user's name and the password macos, 0600, and Ready shows them"

# The installer's account (handed over by omarchy-macos-vm-credentials) wins.
reset
touch "$state/done" "$kvm_param"
mkdir -p "$images/b-restore" "${creds%/*}"; touch "$images/b-restore/.ingested"
printf 'USERNAME=izzy\nPASSWORD=pa ss=word\n' >"$creds"; chmod 600 "$creds"
run_cmd create --auto
(( status == 0 )) || fail "create with the installer's account" "$(cat "$test_tmp/out")"
[[ $(<"$home/.local/share/omvm/guest-password") == 'pa ss=word' ]] && grep -Fxq 'OMVM_GUEST_USER=izzy' "$home/.config/omvm/gui.env" ||
  fail "omvm gets the installer's account" "$(cat "$home/.config/omvm/gui.env")"
stub gum 'shift; while [[ $1 == --* ]]; do shift 2; done; printf "%s\n" "$@"'
printf 'running\n' >"$vm/state"
run_cmd status
grep -Fxq 'Username:  izzy' "$test_tmp/out" && grep -Fxq 'Password:  pa ss=word' "$test_tmp/out" ||
  fail "status shows the username and password" "$(cat "$test_tmp/out")"
rm -f "$stub_bin/gum" "$vm/state"
pass "a stored account goes to omvm as is, and status shows it"

# Handed over at the next boot: create waits instead of making the account with defaults.
reset
touch "$state/done" "$kvm_param" "$state/credentials-pending"
mkdir -p "$images/b-restore"; touch "$images/b-restore/.ingested"
run_cmd create --auto
(( status == 2 )) && ! grep -q '^omvm setup' "$log" && [[ ! -e $creds ]] ||
  fail "create waits for the installer's account" "$(cat "$test_tmp/out"; cat "$log")"
pass "with the installer's account still to be handed over, create waits for the restart"

reset
touch "$state/done" "$kvm_param"
mkdir -p "$images/b-restore"; touch "$images/b-restore/.ingested"
TEST_SETUP_FAIL=1 run_cmd create --auto
(( status == 1 )) && [[ $(value stage) == failed ]] || fail "a failed setup is recorded" "$(cat "$progress")"
run_cmd progress
(( status == 1 )) && grep -Fq 'Retry: omarchy-macos-vm create' "$test_tmp/out" || fail "the progress view ends at a failure" "$(cat "$test_tmp/out")"
pass "a failed step ends the progress view with how to retry"

# The launcher while the VM is being made: where it is, and the progress view.
reset
touch "$state/done" "$state/vmxfer-ready"
mkdir -p "${progress%/*}"; printf 'stage=importing\npercent=10\ndetail=Unpacking\n' >"$progress"
TEST_CREATING=1 WAYLAND_DISPLAY=wayland-1 run_cmd launch
(( status == 0 )) || fail "launch while creating is not an error" "$(cat "$test_tmp/out")"
grep -q "^notify macOS VM Still setting up (Importing, 10%)… --exec omarchy-launch-floating-terminal-with-presentation 'omarchy-macos-vm progress'" "$log" &&
  grep -q '^systemd-run --user --unit=omarchy-macos-vm-progress-view .*omarchy-macos-vm progress' "$log" && ! grep -q '^omvm \(start\|show\)' "$log" ||
  fail "launch while creating shows the stage and opens the progress view" "$(cat "$log")"
reset
printf 'stage=waiting-for-internet\n' >"$state/status"
run_cmd launch
(( status == 0 )) && grep -q '^notify macOS VM Still setting up (Waiting for internet)…' "$log" ||
  fail "launch while the stack waits for internet says so" "$(cat "$log")"
rm -f "$state/status"
run_cmd launch
(( status == 1 )) && grep -q '^notify .*not set up yet' "$log" || fail "launch with nothing running still says what is next" "$(cat "$log")"
pass "the macOS launcher, clicked while the VM is being made, shows the stage and the progress view"

# remove restores stock linux-aurora default via omarchy-macos-vm-boot-default disable.
reset
touch "$marker" "$state/done" "$state/vmxfer-ready" "$state/oneshot-armed" "$state/oneshot-tries"
printf 'linux-aurora-vmapple\n' >"$default_side"
stub gum 'exit 0'
stub sudo 'exec "$@"'
stub omarchy-pkg-present 'echo "pkg-present $*" >>"$TEST_LOG"; exit 0'
stub omarchy-pkg-remove 'echo "pkg-remove $*" >>"$TEST_LOG"; exit 0'
stub boot-default 'echo "boot-default $*" >>"$TEST_LOG"; [[ $1 == disable ]] && rm -f "$OMARCHY_MAC_DEFAULT_SIDE_KERNEL"'
run_cmd remove
(( status == 0 )) || fail "remove succeeds" "$(cat "$test_tmp/out")"
grep -Fxq 'boot-default disable' "$log" || fail "remove calls boot-default disable" "$(cat "$log")"
[[ ! -e $default_side && ! -e $marker && ! -e $state/done && ! -e $state/oneshot-armed ]] ||
  fail "remove cleans up default-side-kernel, marker and state" "$(cat "$log")"
pass "remove disables persistent side-kernel boot default and cleans up state"
