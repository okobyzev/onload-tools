#!/bin/bash
#
# Launch the qtRobot1TT Onload-accelerated application.
#
# Before starting a new Onload stack, this script refuses to run if any
# CPU core (or NIC IRQ core) it is about to claim exclusively is already
# in use by another, currently running, Onload stack - whatever process
# created that stack. See lib/onload_guard.sh for how that is determined.
#
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=../lib/onload_guard.sh
source "$SCRIPT_DIR/../lib/onload_guard.sh"

# ============================================================================
# Section 1 - single source of truth for this launch's config.
# Every core/IRQ value used below is derived from these variables (or read
# straight from the kernel) - nothing is duplicated or assumed elsewhere.
# ============================================================================
APP_DIR="/home/prodfx/Desktop/ALEX/qtRobot1TT"
APP_BIN="./1TT"
APP_ARGS=(1)
ONLOAD_PROFILE="/profiles/latency-best-profile-core26.opf"
TASKSET_CORE_SPEC="25,26"

# Real filesystem locations / commands the guard reads from. Overridable
# via env vars so this script (and its checks) can be exercised in tests
# without root or real Onload/Solarflare hardware - see tests/test_launcher.sh.
STACKS_PROC="${STACKS_PROC:-/proc/driver/onload/stacks}"
PROC_ROOT="${PROC_ROOT:-/proc}"
# `onload_mibdump -a llap` is Onload's own control-plane report of which
# interfaces it has hwports assigned to - used instead of guessing from a
# NIC driver name, which cannot be assumed to follow any fixed pattern.
ONLOAD_MIBDUMP_CMD="${ONLOAD_MIBDUMP_CMD:-onload_mibdump}"
INTERRUPTS_PROC="${INTERRUPTS_PROC:-/proc/interrupts}"
IRQ_PROC_ROOT="${IRQ_PROC_ROOT:-/proc/irq}"

# When set (e.g. by tests), run only the pre-flight guard and skip exec'ing
# onload/taskset.
CHECK_ONLY="${CHECK_ONLY:-0}"

log() { printf '%s [launch_qtRobot1TT] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

# ============================================================================
# Section 2 - Onload runtime tuning (unchanged from the original script).
# ============================================================================
export EF_CTPIO_MODE=sf
export EF_DONT_ACCELERATE=1
export EF_TX_TIMESTAMPING=3
export EF_RX_TIMESTAMPING=3
export EF_PIO=1
export EF_UL_EPOLL=1
export EF_EPOLL_MT_SAFE=1
export EF_SPIN_USEC=-1
export EF_POLL_USEC=-1
export EF_NONAGLE_INFLIGHT_MAX=1
export EF_SEND_POLL_THRESH=1

# ============================================================================
# Section 3 - work out which cores this launch is about to claim.
# ============================================================================
mapfile -t TASKSET_CORES < <(onload_guard::expand_core_list "$TASKSET_CORE_SPEC")
mapfile -t PROFILE_IRQ_CORES < <(onload_guard::cores_from_profile "$ONLOAD_PROFILE")
mapfile -t TARGET_CORES < <(printf '%s\n' "${TASKSET_CORES[@]}" "${PROFILE_IRQ_CORES[@]}" | sort -nu)

((${#TARGET_CORES[@]} > 0)) || die "could not determine any target core from TASKSET_CORE_SPEC='$TASKSET_CORE_SPEC'"

log "target cores for this launch (taskset + profile IRQ core): ${TARGET_CORES[*]}"

# ============================================================================
# Section 4 - pre-flight guard: is any of those cores already owned by an
# existing onload stack (by CPU affinity) or already dedicated to NIC IRQs
# while onload is active?
# ============================================================================
# Populated via namerefs inside onload_guard::* below.
# shellcheck disable=SC2034
declare -A STACK_CORE_OWNER=()
# shellcheck disable=SC2034
declare -A IRQ_CORE_OWNER=()
ANY_LIVE_STACK=0
CONFLICT_MESSAGES=()

onload_guard::collect_stack_core_owners \
  "$STACKS_PROC" "$PROC_ROOT" STACK_CORE_OWNER ANY_LIVE_STACK

onload_guard::collect_nic_irq_core_owners \
  "$ONLOAD_MIBDUMP_CMD" "$INTERRUPTS_PROC" "$IRQ_PROC_ROOT" IRQ_CORE_OWNER

if [[ ! -r "$STACKS_PROC" ]]; then
  log "notice: $STACKS_PROC not present (onload module not loaded?) - no existing stacks to conflict with"
fi
if ! command -v "$ONLOAD_MIBDUMP_CMD" >/dev/null 2>&1; then
  log "notice: '$ONLOAD_MIBDUMP_CMD' not found - skipping the NIC IRQ cross-check (stack-affinity check below still applies)"
fi

if onload_guard::check_conflicts \
  TARGET_CORES STACK_CORE_OWNER IRQ_CORE_OWNER "$ANY_LIVE_STACK" CONFLICT_MESSAGES; then
  log "no existing onload stack found on cores ${TARGET_CORES[*]} - safe to launch"
else
  for msg in "${CONFLICT_MESSAGES[@]}"; do
    log "CONFLICT: $msg"
  done
  die "refusing to start: one or more target cores (${TARGET_CORES[*]}) are already in use by an existing onload stack. Inspect with 'cat $STACKS_PROC' and 'onload_stackdump' before retrying."
fi

if [[ "$CHECK_ONLY" == "1" ]]; then
  log "CHECK_ONLY=1 set - skipping actual launch"
  exit 0
fi

# ============================================================================
# Section 5 - rotate old timeseries files (unchanged behaviour, safer).
# ============================================================================
cd "$APP_DIR" || die "cannot cd to $APP_DIR"

tag="$(date +%m%d_%H%M%S)"
if [[ -e timeseries ]]; then
  mv timeseries "timeseries.$tag"
fi
find . -name 'timeseries*' -ctime +7 -delete

# ============================================================================
# Section 6 - launch.
# ============================================================================
log "launching: taskset -c $TASKSET_CORE_SPEC onload --profile=$ONLOAD_PROFILE $APP_BIN ${APP_ARGS[*]}"
exec taskset -c "$TASKSET_CORE_SPEC" onload --profile="$ONLOAD_PROFILE" "$APP_BIN" "${APP_ARGS[@]}"
