#!/bin/bash
# omarchy-macos-vm-credentials against a staged root: the installer's account
# moves from the 0600 marker to the owner's 0600 file, and only then leaves
# the marker.

set -euo pipefail

package=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
helper=$package/bin/omarchy-macos-vm-credentials
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

fail() {
  printf 'not ok - %s\n' "$1"
  [[ -z ${2:-} ]] || printf '%s\n' "$2" | sed 's/^/# /'
  exit 1
}
pass() { printf 'ok - %s\n' "$1"; }

uid=$(id -u) gid=$(id -g)
new_root() {
  root=$test_tmp/root-$1
  mkdir -p "$root/etc/omarchy" "$root/var/lib/omarchy/macos-vm"
  printf 'root:x:0:0::/root:/bin/bash\n' >"$root/etc/passwd"
  marker=$root/etc/omarchy/macos-vm.enabled
  (umask 077 && printf '%s\n' '{"version":1,"requested_by":"installer","guest_user":"izzy","guest_password":"ab\"c\\d e"}' >"$marker")
}
add_owner() { # NAME: an account with this test's uid and a home in the root
  printf '%s:x:%s:%s::/home/%s:/bin/bash\n' "$1" "$uid" "$gid" "$1" >>"$root/etc/passwd"
  mkdir -p "$root/home/$1"
}
run_helper() {
  set +e
  OMARCHY_MACOS_VM_ROOT="$root" bash "$helper" >"$test_tmp/out" 2>&1
  status=$?
  set -e
}

# No owner yet: nothing moves, the pending flag says to wait.
new_root none
run_helper
(( status == 0 )) || fail "no owner is not an error" "$(cat "$test_tmp/out")"
grep -q guest_password "$marker" && [[ -e $root/var/lib/omarchy/macos-vm/credentials-pending ]] ||
  fail "without an owner the password stays in the marker and the hand-over is pending"
[[ $(stat -c %a "$marker") == 600 ]] || fail "the marker stays 0600 while it holds the password"
pass "with no owner account yet, the account waits in the 0600 marker (credentials-pending)"

# The owner exists: the file is written 0600, the marker loses the password and is 0644 again.
add_owner izzy
run_helper
(( status == 0 )) || fail "the hand-over succeeds" "$(cat "$test_tmp/out")"
file=$root/home/izzy/.config/omarchy/macos-vm-credentials
[[ $(<"$file") == $'USERNAME=izzy\nPASSWORD=ab"c\\d e' ]] || fail "the owner's file holds the account as typed" "$(cat "$file")"
[[ $(stat -c %a "$file") == 600 && $(stat -c %u "$file") == "$uid" ]] || fail "the owner's file is 0600 and theirs"
! grep -q guest_password "$marker" || fail "the password leaves the marker"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d == {"version":1,"requested_by":"installer","guest_user":"izzy"}, d' "$marker" ||
  fail "the marker keeps its other keys" "$(cat "$marker")"
[[ $(stat -c %a "$marker") == 644 && ! -e $root/var/lib/omarchy/macos-vm/credentials-pending ]] ||
  fail "the marker is 0644 again and nothing is pending"
run_helper
(( status == 0 )) || fail "a second run is a no-op"
pass "the owner gets a 0600 credentials file and the marker drops the password"

# The marker's "user" picks the owner; an existing file is kept.
new_root user
printf 'other:x:%s:%s::/home/other:/bin/bash\n' "$uid" "$gid" >>"$root/etc/passwd"; mkdir -p "$root/home/other"
add_owner izzy
python3 - "$marker" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["user"] = "izzy"; json.dump(d, open(sys.argv[1], "w"))
PY
mkdir -p "$root/home/izzy/.config/omarchy"
printf 'USERNAME=mine\nPASSWORD=kept\n' >"$root/home/izzy/.config/omarchy/macos-vm-credentials"
run_helper
(( status == 0 )) && [[ ! -e $root/home/other/.config ]] && grep -Fxq 'PASSWORD=kept' "$root/home/izzy/.config/omarchy/macos-vm-credentials" &&
  ! grep -q guest_password "$marker" || fail "the marker's user is the owner and their own file is kept" "$(cat "$test_tmp/out")"
pass "the marker's user is the owner, and an account they already stored is kept"

# A symlink in the owner's tree is refused; the password stays put.
new_root symlink
add_owner izzy
mkdir -p "$root/home/izzy/.config" "$test_tmp/elsewhere"
ln -s "$test_tmp/elsewhere" "$root/home/izzy/.config/omarchy"
run_helper
(( status == 1 )) && [[ -z $(ls -A "$test_tmp/elsewhere") ]] && grep -q guest_password "$marker" ||
  fail "a symlinked ~/.config/omarchy is refused" "$(cat "$test_tmp/out")"
pass "a symlink in the owner's config is refused"

# A marker without credentials (menu install, script install) is left alone.
new_root plain
printf '{"version":1,"requested_by":"menu"}\n' >"$marker"; chmod 644 "$marker"
add_owner izzy
run_helper
(( status == 0 )) && [[ ! -e $root/home/izzy/.config && $(<"$marker") == '{"version":1,"requested_by":"menu"}' ]] ||
  fail "a marker without an account changes nothing"
pass "a marker without the installer's account changes nothing"
