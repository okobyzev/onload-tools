#!/bin/bash
#
# Self-contained tests for lib/onload_guard.sh and bin/launch_qtRobot1TT.sh.
#
# Builds fake /proc + /sys trees (no root, no real Onload/Solarflare
# hardware required) and exercises both the unit-level guard functions and
# the launcher script end-to-end (in CHECK_ONLY mode) against them.
#
# Usage: ./tests/test_launcher.sh
#
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)"
LAUNCHER="$REPO_DIR/bin/launch_qtRobot1TT.sh"

# shellcheck source=../lib/onload_guard.sh
source "$REPO_DIR/lib/onload_guard.sh"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
nok() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then ok "$desc"; else
    nok "$desc (expected [$expected], got [$actual])"
  fi
}

# --------------------------------------------------------------------------
# Fake environment builder.
#
# make_fake_env <root_dir>
#   sets up $root_dir/proc, $root_dir/sys with a helper to register:
#     - an onload stack (id, pid, and optionally its thread affinities)
#     - an sfc NIC interface with a given IRQ and smp_affinity_list
# --------------------------------------------------------------------------
fake_root=""

reset_fake_env() {
  fake_root="$(mktemp -d)"
  mkdir -p "$fake_root/proc/driver/onload" "$fake_root/proc/irq" \
    "$fake_root/sys/class/net" "$fake_root/sys/bus/fake/drivers/sfc_stub"
  : >"$fake_root/proc/driver/onload/stacks"
  : >"$fake_root/proc/interrupts"
}

# add_stack <stack_id> <pid> <cpus_allowed_list_or_empty>
add_stack() {
  local id="$1" pid="$2" cpus="${3:-}"
  # matches the real /proc/driver/onload/stacks layout: "id: pid uid ...".
  printf '%s: %s 1000 13 0 0 1 2 0 3 0 0 1 0 4 0 5 0 0 0 0 0 0 6 7\n' \
    "$id" "$pid" >>"$fake_root/proc/driver/onload/stacks"
  if [[ -n "$cpus" ]]; then
    mkdir -p "$fake_root/proc/$pid/task/$pid"
    {
      echo "Name:	fake_stack_owner"
      echo "Pid:	$pid"
      echo "Cpus_allowed_list:	$cpus"
    } >"$fake_root/proc/$pid/task/$pid/status"
  fi
  # else: pid intentionally left with no /proc/<pid> dir => orphan stack.
}

# add_nic <iface> <irq> <affinity_list>
add_nic() {
  local iface="$1" irq="$2" affinity="$3"
  mkdir -p "$fake_root/sys/class/net/$iface/device"
  ln -sfn "../../../../bus/fake/drivers/sfc_stub" \
    "$fake_root/sys/class/net/$iface/device/driver"
  printf ' %s:   111   222   0   0  IR-PCI-MSI-edge      %s-0\n' \
    "$irq" "$iface" >>"$fake_root/proc/interrupts"
  mkdir -p "$fake_root/proc/irq/$irq"
  printf '%s\n' "$affinity" >"$fake_root/proc/irq/$irq/smp_affinity_list"
}

run_launcher_check() {
  STACKS_PROC="$fake_root/proc/driver/onload/stacks" \
    PROC_ROOT="$fake_root/proc" \
    SYS_CLASS_NET="$fake_root/sys/class/net" \
    INTERRUPTS_PROC="$fake_root/proc/interrupts" \
    IRQ_PROC_ROOT="$fake_root/proc/irq" \
    CHECK_ONLY=1 \
    "$LAUNCHER" >"$fake_root/launcher.out" 2>&1
}

echo "== unit: expand_core_list =="
assert_eq "simple list" "$(printf '25\n26')" "$(onload_guard::expand_core_list '25,26')"
assert_eq "range" "$(printf '0\n1\n2\n3')" "$(onload_guard::expand_core_list '0-3')"
assert_eq "mixed range+list" "$(printf '0\n1\n8\n9\n10')" "$(onload_guard::expand_core_list '0-1,8-10')"
assert_eq "empty spec" "" "$(onload_guard::expand_core_list '')"

echo "== unit: cores_from_profile =="
tmp_profile="$(mktemp)"
cat >"$tmp_profile" <<'EOF'
# example profile
onload_set EF_POLL_USEC 100000
onload_set EF_IRQ_CORE 26
onload_set EF_TCP_FASTSTART_INIT 0
EOF
assert_eq "profile irq core parsed" "26" "$(onload_guard::cores_from_profile "$tmp_profile")"
rm -f "$tmp_profile"

tmp_profile2="$(mktemp)"
echo "EF_IRQ_CHANNEL=7" >"$tmp_profile2"
assert_eq "profile irq channel (= form) parsed" "7" "$(onload_guard::cores_from_profile "$tmp_profile2")"
rm -f "$tmp_profile2"

echo "== integration: launcher CHECK_ONLY, no existing stacks =="
reset_fake_env
if run_launcher_check; then
  ok "launch allowed when no stacks/irqs exist"
else
  nok "launch allowed when no stacks/irqs exist ($(cat "$fake_root/launcher.out"))"
fi

echo "== integration: launcher CHECK_ONLY, unrelated stack on unrelated core =="
reset_fake_env
add_stack 9 9001 "5"   # matches the sample data's stack "9", but on core 5, not 25/26
if run_launcher_check; then
  ok "launch allowed when existing stack is on an unrelated core"
else
  nok "launch allowed when existing stack is on an unrelated core ($(cat "$fake_root/launcher.out"))"
fi

echo "== integration: launcher CHECK_ONLY, conflicting stack on target core 26 =="
reset_fake_env
add_stack 2 9002 "26"
if run_launcher_check; then
  nok "launch blocked when existing stack occupies core 26"
else
  ok "launch blocked when existing stack occupies core 26"
  if grep -q "core 26" "$fake_root/launcher.out"; then
    ok "conflict message mentions core 26"
  else
    nok "conflict message mentions core 26"
  fi
fi

echo "== integration: launcher CHECK_ONLY, conflicting stack via range affinity =="
reset_fake_env
add_stack 16 9003 "20-30"
if run_launcher_check; then
  nok "launch blocked when existing stack's affinity range covers core 25"
else
  ok "launch blocked when existing stack's affinity range covers core 25"
fi

echo "== integration: launcher CHECK_ONLY, orphan stack (dead pid) is not a conflict =="
reset_fake_env
add_stack 3 9999999 ""   # no /proc/<pid> created => orphan
if run_launcher_check; then
  ok "launch allowed when only an orphaned/zombie stack is present"
else
  nok "launch allowed when only an orphaned/zombie stack is present ($(cat "$fake_root/launcher.out"))"
fi

echo "== integration: launcher CHECK_ONLY, NIC IRQ already on target core while a stack is live =="
reset_fake_env
add_stack 8 9004 "5"                 # live stack, but its own thread isn't on 25/26
add_nic eth0 77 "26"                 # NIC IRQ for an onload-capable NIC is on core 26
if run_launcher_check; then
  nok "launch blocked when NIC IRQ for onload-capable NIC sits on target core with a live stack"
else
  ok "launch blocked when NIC IRQ for onload-capable NIC sits on target core with a live stack"
fi

echo "== integration: launcher CHECK_ONLY, NIC IRQ on target core but NO live stack =="
reset_fake_env
add_nic eth0 78 "26"                 # IRQ steering alone, no onload stacks active at all
if run_launcher_check; then
  ok "launch allowed when NIC IRQ is on target core but no onload stack is active"
else
  nok "launch allowed when NIC IRQ is on target core but no onload stack is active ($(cat "$fake_root/launcher.out"))"
fi

echo "== integration: launcher CHECK_ONLY, non-sfc NIC on target core is ignored =="
reset_fake_env
add_stack 5 9005 "5"
mkdir -p "$fake_root/sys/class/net/eth1/device" "$fake_root/sys/bus/fake/drivers/e1000e_stub"
ln -sfn "../../../../bus/fake/drivers/e1000e_stub" "$fake_root/sys/class/net/eth1/device/driver"
printf ' 99:   1   2   0   0  IR-PCI-MSI-edge      eth1-0\n' >>"$fake_root/proc/interrupts"
mkdir -p "$fake_root/proc/irq/99"
echo "26" >"$fake_root/proc/irq/99/smp_affinity_list"
if run_launcher_check; then
  ok "non-onload (non-sfc) NIC IRQ on target core does not block the launch"
else
  nok "non-onload (non-sfc) NIC IRQ on target core does not block the launch ($(cat "$fake_root/launcher.out"))"
fi

rm -rf "$fake_root"

echo
echo "== summary: $PASS passed, $FAIL failed =="
((FAIL == 0))
