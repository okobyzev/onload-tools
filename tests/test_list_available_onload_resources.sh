#!/bin/bash
#
# Tests for bin/list_available_onload_resources.sh.
#
# Reuses the same fake /proc fixture builder as tests/test_launcher.sh (see
# tests/fake_proc_fixtures.sh) so both suites agree on what a fake onload
# stack / accelerated NIC IRQ looks like. No root or real Onload/Solarflare
# hardware required.
#
# Usage: ./tests/test_list_available_onload_resources.sh
#
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)"
TOOL="$REPO_DIR/bin/list_available_onload_resources.sh"

# shellcheck source=./fake_proc_fixtures.sh
source "$SCRIPT_DIR/fake_proc_fixtures.sh"

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

# run_tool [extra_args...]
#
# Runs the tool against the current fake_root, capturing stdout in
# $fake_root/tool.out. Always exits 0 (the tool reports, it never blocks).
run_tool() {
  STACKS_PROC="$fake_root/proc/driver/onload/stacks" \
    PROC_ROOT="$fake_root/proc" \
    PATH="$fake_root/bin:$PATH" \
    INTERRUPTS_PROC="$fake_root/proc/interrupts" \
    IRQ_PROC_ROOT="$fake_root/proc/irq" \
    CPUINFO_PROC="$fake_root/proc/cpuinfo" \
    "$TOOL" "$@" >"$fake_root/tool.out" 2>&1
}

summary_line() {
  local key="$1"
  grep "^${key}:" "$fake_root/tool.out" | tail -1 | cut -d: -f2-
}

echo "== unit: onload_guard::all_cores =="
tmp_cpuinfo="$(mktemp)"
cat >"$tmp_cpuinfo" <<'EOF'
processor	: 0
vendor_id	: FakeCPU

processor	: 1
vendor_id	: FakeCPU

processor	: 3
vendor_id	: FakeCPU
EOF
# shellcheck source=../lib/onload_guard.sh
source "$REPO_DIR/lib/onload_guard.sh"
assert_eq "parses non-contiguous processor ids, sorted+unique" "$(printf '0\n1\n3')" \
  "$(onload_guard::all_cores "$tmp_cpuinfo")"
assert_eq "missing cpuinfo file yields nothing" "" "$(onload_guard::all_cores "/no/such/file")"
rm -f "$tmp_cpuinfo"

echo "== unit: onload_guard::iface_irqs =="
tmp_interrupts="$(mktemp)"
cat >"$tmp_interrupts" <<'EOF'
 77:   111   222   0   0  IR-PCI-MSI-edge      eth0-0
 78:     1     2   0   0  IR-PCI-MSI-edge      eth0-1
 99:     5     6   0   0  IR-PCI-MSI-edge      eth1-0
EOF
declare -a parsed_irqs=()
onload_guard::iface_irqs "eth0" "$tmp_interrupts" parsed_irqs
assert_eq "finds every IRQ line matching the interface" "77 78" "${parsed_irqs[*]}"
rm -f "$tmp_interrupts"

echo "== integration: no cores excluded, no stacks/irqs -> every core free =="
reset_fake_env
write_fake_cpuinfo 4
if run_tool; then
  ok "tool exits 0 (report-only, never blocks)"
else
  nok "tool exits 0 ($(cat "$fake_root/tool.out"))"
fi
assert_eq "all 4 cores reported free" "0 1 2 3" "$(summary_line free_cores)"
assert_eq "no cores reported busy" "" "$(summary_line busy_cores)"

echo "== integration: a live stack pinned to core 2 makes only that core busy =="
reset_fake_env
write_fake_cpuinfo 4
add_stack 5 8001 "2"
run_tool
assert_eq "core 2 is busy" "2" "$(summary_line busy_cores)"
assert_eq "cores 0,1,3 remain free" "0 1 3" "$(summary_line free_cores)"

echo "== integration: orphaned stack (dead pid) never marks a core busy =="
reset_fake_env
write_fake_cpuinfo 4
add_stack 6 9999999 ""
run_tool
assert_eq "every core still free" "0 1 2 3" "$(summary_line free_cores)"

echo "== integration: NIC IRQ on a core is busy only while a stack is live elsewhere =="
reset_fake_env
write_fake_cpuinfo 4
add_nic eth0 50 "3"
run_tool
assert_eq "no live stack yet -> IRQ-only core 3 still free" "0 1 2 3" "$(summary_line free_cores)"
assert_eq "its IRQ is reported free too" "50" "$(summary_line free_irqs)"

reset_fake_env
write_fake_cpuinfo 4
add_stack 7 8002 "1"
add_nic eth0 50 "3"
run_tool
assert_eq "core 1 (stack) and core 3 (IRQ while stack live) are both busy" "1 3" "$(summary_line busy_cores)"
assert_eq "core 3's IRQ is reported free (its own core isn't stack-owned)" "50" "$(summary_line free_irqs)"

echo "== integration: an IRQ steered onto a stack-owned core is reported busy =="
reset_fake_env
write_fake_cpuinfo 4
add_stack 8 8003 "3"
add_nic eth0 51 "3"
run_tool
assert_eq "irq 51 (same core as the live stack) is busy" "51" "$(summary_line busy_irqs)"
assert_eq "no free irqs left" "" "$(summary_line free_irqs)"

echo "== integration: a non-accelerated NIC's IRQ never counts against a core =="
reset_fake_env
write_fake_cpuinfo 4
add_stack 9 8004 "1"
add_non_accelerated_nic eth1 60 "3"
run_tool
assert_eq "only the stack's own core 1 is busy" "1" "$(summary_line busy_cores)"
assert_eq "no accelerated irqs reported at all" "" "$(summary_line free_irqs)$(summary_line busy_irqs)"

echo "== integration: EXCLUDE_CORE_SPEC removes cores from both lists =="
reset_fake_env
write_fake_cpuinfo 4
if EXCLUDE_CORE_SPEC="0,1" run_tool; then
  ok "tool still exits 0 with exclusions set"
fi
assert_eq "excluded cores absent from free list" "2 3" "$(summary_line free_cores)"
assert_eq "excluded cores absent from busy list too" "" "$(summary_line busy_cores)"

echo "== integration: -q/--quiet only prints the machine-readable summary =="
reset_fake_env
write_fake_cpuinfo 2
run_tool -q
if grep -q "^== CPU cores" "$fake_root/tool.out"; then
  nok "quiet mode suppressed the human-readable section header"
else
  ok "quiet mode suppressed the human-readable section header"
fi
assert_eq "summary line still present in quiet mode" "0 1" "$(summary_line free_cores)"

echo "== integration: missing cpuinfo is a hard error, not a silent empty report =="
reset_fake_env
if CPUINFO_PROC="$fake_root/proc/nonexistent_cpuinfo" \
  STACKS_PROC="$fake_root/proc/driver/onload/stacks" \
  PROC_ROOT="$fake_root/proc" \
  PATH="$fake_root/bin:$PATH" \
  INTERRUPTS_PROC="$fake_root/proc/interrupts" \
  IRQ_PROC_ROOT="$fake_root/proc/irq" \
  "$TOOL" >"$fake_root/tool.out" 2>&1; then
  nok "tool fails fast when cpuinfo cannot be read"
else
  ok "tool fails fast when cpuinfo cannot be read"
fi

rm -rf "$fake_root"

echo
echo "== summary: $PASS passed, $FAIL failed =="
((FAIL == 0))
