#!/bin/bash
#
# onload_guard.sh - reusable helpers to detect whether the CPU cores (and
# the NIC IRQs) a new Onload-accelerated process is about to claim are
# already in use by another, currently running, Onload stack.
#
# Design notes (see README.md "Why this exists" for the full rationale):
#   * We never assume a process/stack *name* pattern - any Onload stack,
#     created by any binary, counts. Stacks are discovered purely from the
#     kernel-exposed /proc/driver/onload/stacks table.
#   * We never hard-code core IDs or IRQ numbers - both are read at
#     runtime, either from the caller-supplied taskset spec / profile file,
#     or straight from the kernel (/proc/interrupts, /proc/irq/*).
#   * Every path this file touches (/proc/driver/onload/stacks, /proc,
#     /sys/class/net, /proc/interrupts) is overridable so the logic can be
#     exercised against a fake filesystem tree in tests, without root and
#     without real Onload/Solarflare hardware.
#
# Intended usage: `source` this file, then call the onload_guard::* public
# functions below. Nothing in this file launches a process or exits the
# shell - it only reports findings into associative arrays supplied by the
# caller (via bash namerefs), so it is safe to source from any launcher.

set -o pipefail

# --------------------------------------------------------------------------
# onload_guard::expand_core_list <spec>
#
# Expands a taskset/Cpus_allowed_list/smp_affinity_list style core spec
# ("25,26", "0-3,8", "0-63") into one core number per line, sorted+unique.
# --------------------------------------------------------------------------
onload_guard::expand_core_list() {
  local spec="${1:-}" part a b i out=()
  IFS=',' read -ra _onload_guard_parts <<<"$spec"
  for part in "${_onload_guard_parts[@]}"; do
    part="${part//[[:space:]]/}"
    [[ -z "$part" ]] && continue
    if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      a=$((10#${BASH_REMATCH[1]}))
      b=$((10#${BASH_REMATCH[2]}))
      if (( a > b )); then local t=$a; a=$b; b=$t; fi
      for ((i = a; i <= b; i++)); do out+=("$i"); done
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      out+=("$((10#$part))")
    fi
    # anything else (e.g. "all", garbage) is silently ignored: we only
    # ever want to compare *numeric* core ids.
  done
  ((${#out[@]} == 0)) && return 0
  printf '%s\n' "${out[@]}" | sort -nu
}

# --------------------------------------------------------------------------
# onload_guard::cores_from_profile <profile_file>
#
# Onload tuning profiles (.opf) can dedicate interrupt handling to a core
# via EF_IRQ_CORE / EF_IRQ_CHANNEL (set with `onload_set VAR VALUE` or
# `onload_set VAR=VALUE`). Pull whatever value the profile *actually*
# contains instead of guessing it from the file name.
# --------------------------------------------------------------------------
onload_guard::cores_from_profile() {
  local profile="${1:-}" line
  [[ -n "$profile" && -r "$profile" ]] || return 0
  while IFS= read -r line; do
    if [[ "$line" =~ EF_IRQ_(CORE|CHANNEL)[[:space:]=]+([0-9,-]+) ]]; then
      onload_guard::expand_core_list "${BASH_REMATCH[2]}"
    fi
  done <"$profile" | sort -nu
}

# --------------------------------------------------------------------------
# onload_guard::collect_stack_core_owners <stacks_proc> <proc_root> \
#                                          <out_owner_map> <out_any_live>
#
# Reads /proc/driver/onload/stacks (path given by <stacks_proc>) and, for
# every stack whose creator PID is still alive, inspects every *thread* of
# that PID under <proc_root>/<pid>/task/*/status (Cpus_allowed_list) to
# work out which cores that stack is really pinned to right now.
#
# <out_owner_map> (nameref to an associative array) is filled as:
#   owner_map[<core>]="stack=<id> pid=<pid>"
# <out_any_live> (nameref to a plain variable) is set to 1 if at least one
# stack with a live owning process was found (used as a secondary signal
# for the IRQ-core check below), 0 otherwise.
# --------------------------------------------------------------------------
onload_guard::collect_stack_core_owners() {
  local stacks_proc="$1" proc_root="$2"
  local -n _owner_map="$3"
  local -n _any_live="$4"
  _any_live=0

  [[ -r "$stacks_proc" ]] || return 0

  local line stack_id rest pid status_file allowed core
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    stack_id="${line%%:*}"
    rest="${line#*: }"
    pid="${rest%%[[:space:]]*}"
    [[ "$stack_id" =~ ^[0-9]+$ ]] || continue
    [[ "$pid" =~ ^[0-9]+$ ]] || continue

    if [[ ! -d "$proc_root/$pid" ]]; then
      # Creator process is gone: this is an orphan/zombie stack. It has no
      # live thread affinity to check, so it cannot own a core right now.
      continue
    fi

    _any_live=1
    for status_file in "$proc_root/$pid"/task/*/status; do
      [[ -r "$status_file" ]] || continue
      allowed=$(awk '/^Cpus_allowed_list:/{print $2}' "$status_file")
      [[ -n "$allowed" ]] || continue
      while IFS= read -r core; do
        [[ -n "$core" ]] || continue
        _owner_map["$core"]="stack=$stack_id pid=$pid"
      done < <(onload_guard::expand_core_list "$allowed")
    done
  done <"$stacks_proc"
}

# --------------------------------------------------------------------------
# onload_guard::collect_nic_irq_core_owners <sys_class_net> <interrupts_proc> \
#                                            <irq_proc_root> <out_owner_map>
#
# Auto-discovers network interfaces bound to an Onload-capable NIC driver
# (Solarflare/AMD "sfc*"), finds their IRQ numbers from <interrupts_proc>,
# and reads each IRQ's *current* smp_affinity_list from <irq_proc_root>
# (normally /proc/irq) - never a hard-coded IRQ number.
#
# <out_owner_map> is filled as: owner_map[<core>]="irq=<n> if=<iface>"
# --------------------------------------------------------------------------
onload_guard::collect_nic_irq_core_owners() {
  local sys_class_net="$1" interrupts_proc="$2" irq_proc_root="$3"
  local -n _irq_owner_map="$4"

  [[ -d "$sys_class_net" ]] || return 0
  [[ -r "$interrupts_proc" ]] || return 0

  local netdev iface driver_path driver irq_line irq aff_file aff core
  for netdev in "$sys_class_net"/*; do
    [[ -e "$netdev" ]] || continue
    iface="$(basename "$netdev")"
    driver_path="$netdev/device/driver"
    [[ -e "$driver_path" ]] || continue
    driver="$(basename "$(readlink -f "$driver_path")")"
    [[ "$driver" == sfc* ]] || continue

    while IFS= read -r irq_line; do
      irq="${irq_line%%:*}"
      irq="${irq//[[:space:]]/}"
      [[ "$irq" =~ ^[0-9]+$ ]] || continue
      aff_file="$irq_proc_root/$irq/smp_affinity_list"
      [[ -r "$aff_file" ]] || continue
      aff=$(<"$aff_file")
      while IFS= read -r core; do
        [[ -n "$core" ]] || continue
        _irq_owner_map["$core"]="irq=$irq if=$iface"
      done < <(onload_guard::expand_core_list "$aff")
    done < <(grep -F "$iface" "$interrupts_proc" || true)
  done
}

# --------------------------------------------------------------------------
# onload_guard::check_conflicts <target_cores_array_name> \
#                                <stack_owner_map_name> \
#                                <irq_owner_map_name> \
#                                <any_live_stack> \
#                                <out_messages_array_name>
#
# Returns 0 if none of the target cores are already owned, 1 otherwise.
# Human-readable explanations are appended to <out_messages_array_name>.
# --------------------------------------------------------------------------
onload_guard::check_conflicts() {
  local -n _targets="$1"
  local -n _stack_owner="$2"
  local -n _irq_owner="$3"
  local any_live_stack="$4"
  local -n _out_msgs="$5"

  local core rc=0
  for core in "${_targets[@]}"; do
    if [[ -n "${_stack_owner[$core]:-}" ]]; then
      _out_msgs+=("core $core is already owned by an existing onload stack (${_stack_owner[$core]})")
      rc=1
    elif [[ -n "${_irq_owner[$core]:-}" && "$any_live_stack" == "1" ]]; then
      _out_msgs+=("core $core already handles NIC interrupts (${_irq_owner[$core]}) while at least one onload stack is active")
      rc=1
    fi
  done
  return "$rc"
}
