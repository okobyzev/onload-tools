#!/bin/bash
#
# Shared fake /proc (+ fake `onload_mibdump`) fixture builder, used by both
# tests/test_launcher.sh and tests/test_list_available_onload_resources.sh
# so the two suites exercise the exact same fake-environment plumbing
# instead of maintaining two copies of it.
#
# Intended usage: `source` this file, call reset_fake_env once per test
# case, then add_stack/add_nic/add_non_accelerated_nic/write_fake_cpuinfo
# as needed, and finally point the tool under test at
# "$fake_root/proc/..." (see each test file for its own run_* wrapper).
#
fake_root=""
fake_llap_output=""

reset_fake_env() {
  fake_root="$(mktemp -d)"
  fake_llap_output=""
  mkdir -p "$fake_root/proc/driver/onload" "$fake_root/proc/irq" "$fake_root/bin"
  : >"$fake_root/proc/driver/onload/stacks"
  : >"$fake_root/proc/interrupts"
  : >"$fake_root/proc/cpuinfo"
  # Default fake `onload_mibdump`: reports no accelerated interfaces at
  # all. Individual tests override this with add_nic() as needed.
  write_fake_mibdump ""
}

# write_fake_mibdump <llap_output>
#
# Installs a fake onload_mibdump on PATH (via a directory prepended for
# this test only) that just echoes the given `onload_mibdump -a llap`
# style output, mimicking Onload's control plane without needing real
# Onload/Solarflare hardware.
write_fake_mibdump() {
  local llap_output="$1"
  cat >"$fake_root/bin/onload_mibdump" <<EOF
#!/bin/bash
cat <<'LLAP_EOF'
$llap_output
LLAP_EOF
EOF
  chmod +x "$fake_root/bin/onload_mibdump"
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
#
# Registers an interface that Onload's control plane reports as
# accelerated (non-zero TX/RX hwports) - mimics a real
# `onload_mibdump -a llap` entry - and gives its IRQ a live smp_affinity.
add_nic() {
  local iface="$1" irq="$2" affinity="$3"
  fake_llap_output+="llap[$RANDOM]: $iface (1) UP mtu 1500 arp_base 30000ms
         TX hwports 1
         RX hwports 1
"
  write_fake_mibdump "$fake_llap_output"
  printf ' %s:   111   222   0   0  IR-PCI-MSI-edge      %s-0\n' \
    "$irq" "$iface" >>"$fake_root/proc/interrupts"
  mkdir -p "$fake_root/proc/irq/$irq"
  printf '%s\n' "$affinity" >"$fake_root/proc/irq/$irq/smp_affinity_list"
}

# add_non_accelerated_nic <iface> <irq> <affinity_list>
#
# Registers an interface Onload's control plane reports as NOT
# accelerated ("no TX/RX hwports"), with an IRQ on a target core anyway -
# used to prove such interfaces never trigger a conflict.
add_non_accelerated_nic() {
  local iface="$1" irq="$2" affinity="$3"
  fake_llap_output+="llap[$RANDOM]: $iface (1) UP mtu 1500 arp_base 30000ms
         no TX hwports
         no RX hwports
"
  write_fake_mibdump "$fake_llap_output"
  printf ' %s:   1   2   0   0  IR-PCI-MSI-edge      %s-0\n' \
    "$irq" "$iface" >>"$fake_root/proc/interrupts"
  mkdir -p "$fake_root/proc/irq/$irq"
  printf '%s\n' "$affinity" >"$fake_root/proc/irq/$irq/smp_affinity_list"
}

# write_fake_cpuinfo <n_cores>
#
# Creates a fake /proc/cpuinfo with <n_cores> "processor : N" entries
# (0..N-1), close enough to the real file's layout for
# onload_guard::all_cores to parse.
write_fake_cpuinfo() {
  local n="$1" i
  : >"$fake_root/proc/cpuinfo"
  for ((i = 0; i < n; i++)); do
    {
      echo "processor	: $i"
      echo "vendor_id	: FakeCPU"
      echo ""
    } >>"$fake_root/proc/cpuinfo"
  done
}
