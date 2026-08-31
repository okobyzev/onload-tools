#!/bin/bash
#
# List, for the current host, which CPU cores and which NIC IRQ channels
# (of Onload-accelerated interfaces) are currently free to dedicate to a
# *new* Onload stack (taskset core list / EF_IRQ_CORE / EF_IRQ_CHANNEL),
# and which are already claimed by an existing one - so an operator can
# pick a safe TASKSET_CORE_SPEC/profile before starting a new launcher
# without stepping on a stack that is already running.
#
# "Busy" is defined exactly the same way lib/onload_guard.sh's pre-flight
# launch guard defines it (see README.md "How the guard decides"): a core
# is busy if either
#   1. some thread of a still-alive onload stack has it in its
#      Cpus_allowed_list, or
#   2. it currently handles NIC interrupts for an Onload-accelerated
#      interface (per `onload_mibdump -a llap`) while at least one onload
#      stack is active anywhere on the host.
# This script does not re-derive that definition; it feeds every core on
# the host through onload_guard::check_conflicts one at a time, so both
# tools can never disagree with each other.
#
# Usage:
#   bin/list_available_onload_resources.sh          # full, human-readable report
#   bin/list_available_onload_resources.sh -q        # only the machine-readable summary lines
#
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=../lib/onload_guard.sh
source "$SCRIPT_DIR/../lib/onload_guard.sh"

# Real filesystem locations / commands this tool reads from. Overridable
# via env vars (same names as bin/launch_qtRobot1TT.sh) so it can be
# exercised against fake fixtures in tests, without root or real
# Onload/Solarflare hardware.
CPUINFO_PROC="${CPUINFO_PROC:-/proc/cpuinfo}"
STACKS_PROC="${STACKS_PROC:-/proc/driver/onload/stacks}"
PROC_ROOT="${PROC_ROOT:-/proc}"
ONLOAD_MIBDUMP_CMD="${ONLOAD_MIBDUMP_CMD:-onload_mibdump}"
INTERRUPTS_PROC="${INTERRUPTS_PROC:-/proc/interrupts}"
IRQ_PROC_ROOT="${IRQ_PROC_ROOT:-/proc/irq}"

# Cores to leave out of the report entirely (e.g. cores permanently
# reserved for the OS/housekeeping on this host), as a taskset-style spec
# ("0" or "0-1,8"). Empty (consider every core) by default.
EXCLUDE_CORE_SPEC="${EXCLUDE_CORE_SPEC:-}"

# -q/--quiet: print only the machine-readable "free_cores:"/"free_irqs:"
# summary lines, so other scripts can consume the result directly, e.g.:
#   TASKSET_CORE_SPEC="$(bin/list_available_onload_resources.sh -q \
#     | awk -F: '/^free_cores:/{print $2}' | tr ' ' ',')"
QUIET=0
case "${1:-}" in
  -q | --quiet) QUIET=1 ;;
esac

log() { ((QUIET)) && return 0; printf '%s\n' "$*"; }

mapfile -t ALL_CORES < <(onload_guard::all_cores "$CPUINFO_PROC")
if ((${#ALL_CORES[@]} == 0)); then
  echo "ERROR: could not determine any CPU core from '$CPUINFO_PROC'" >&2
  exit 1
fi

declare -A EXCLUDED=()
mapfile -t _exclude_cores < <(onload_guard::expand_core_list "$EXCLUDE_CORE_SPEC")
for _c in "${_exclude_cores[@]}"; do EXCLUDED["$_c"]=1; done

# Populated via namerefs inside onload_guard::* below.
# shellcheck disable=SC2034
declare -A STACK_CORE_OWNER=()
# shellcheck disable=SC2034
declare -A IRQ_CORE_OWNER=()
ANY_LIVE_STACK=0

onload_guard::collect_stack_core_owners \
  "$STACKS_PROC" "$PROC_ROOT" STACK_CORE_OWNER ANY_LIVE_STACK

onload_guard::collect_nic_irq_core_owners \
  "$ONLOAD_MIBDUMP_CMD" "$INTERRUPTS_PROC" "$IRQ_PROC_ROOT" IRQ_CORE_OWNER

if [[ ! -r "$STACKS_PROC" ]]; then
  log "notice: $STACKS_PROC not present (onload module not loaded?) - no existing stacks to conflict with"
fi
if ! command -v "$ONLOAD_MIBDUMP_CMD" >/dev/null 2>&1; then
  log "notice: '$ONLOAD_MIBDUMP_CMD' not found - NIC IRQ steering is not reflected below"
fi

log "== CPU cores (host has ${#ALL_CORES[@]}: ${ALL_CORES[*]}) =="
FREE_CORES=()
BUSY_CORES=()
for core in "${ALL_CORES[@]}"; do
  if [[ -n "${EXCLUDED[$core]:-}" ]]; then
    log "core $core: EXCLUDED (EXCLUDE_CORE_SPEC)"
    continue
  fi
  target=("$core")
  msgs=()
  if onload_guard::check_conflicts target STACK_CORE_OWNER IRQ_CORE_OWNER "$ANY_LIVE_STACK" msgs; then
    FREE_CORES+=("$core")
    log "core $core: FREE"
  else
    BUSY_CORES+=("$core")
    log "core $core: BUSY (${msgs[*]})"
  fi
done

log ""
log "== NIC IRQ channels (Onload-accelerated interfaces) =="
declare -a ACCEL_IFACES=()
FREE_IRQS=()
BUSY_IRQS=()
if onload_guard::accelerated_ifaces "$ONLOAD_MIBDUMP_CMD" ACCEL_IFACES; then
  if ((${#ACCEL_IFACES[@]} == 0)); then
    log "(no Onload-accelerated interfaces reported by $ONLOAD_MIBDUMP_CMD)"
  fi
  for iface in "${ACCEL_IFACES[@]}"; do
    irqs=()
    onload_guard::iface_irqs "$iface" "$INTERRUPTS_PROC" irqs
    for irq in "${irqs[@]}"; do
      aff_file="$IRQ_PROC_ROOT/$irq/smp_affinity_list"
      [[ -r "$aff_file" ]] || continue
      aff="$(<"$aff_file")"
      mapfile -t irq_cores < <(onload_guard::expand_core_list "$aff")
      busy=0
      for c in "${irq_cores[@]}"; do
        [[ -n "${STACK_CORE_OWNER[$c]:-}" ]] && busy=1
      done
      if ((busy)); then
        BUSY_IRQS+=("$irq")
        log "irq $irq (if=$iface, affinity=$aff): BUSY (already steered to a core owned by a live onload stack)"
      else
        FREE_IRQS+=("$irq")
        log "irq $irq (if=$iface, affinity=$aff): FREE"
      fi
    done
  done
else
  log "(onload_mibdump unavailable - cannot enumerate accelerated interfaces/IRQ channels)"
fi

log ""
echo "free_cores:${FREE_CORES[*]:-}"
echo "busy_cores:${BUSY_CORES[*]:-}"
echo "free_irqs:${FREE_IRQS[*]:-}"
echo "busy_irqs:${BUSY_IRQS[*]:-}"
