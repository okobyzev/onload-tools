# onload-tools

Bash tooling for launching [Onload](https://github.com/Xilinx-CNS/onload)-accelerated
programs safely on shared, core-pinned hosts.

## Why this exists

Latency-sensitive Onload applications are normally started with a dedicated
`taskset` core list and a tuning profile (`.opf`) that may additionally
dedicate a core to NIC interrupt handling (`EF_IRQ_CORE` / `EF_IRQ_CHANNEL`).
If a previous instance (or any other, unrelated Onload program) is still
running and pinned to one of those same cores, starting a second stack on
top of it silently degrades both — instead of failing fast and loud.

`bin/launch_qtRobot1TT.sh` adds a pre-flight guard in front of the launch
that refuses to start the program if any of the CPU cores (or the NIC IRQ
core) it is about to claim are already owned by an existing Onload stack.

The guard is deliberately generic:

* **No reliance on any name at all** — process names, stack names, and NIC
  driver names are all treated as arbitrary/random and never matched
  against a pattern:
  * Existing stacks are discovered purely from the kernel-exposed
    `/proc/driver/onload/stacks` table (stack id + creator PID) — whatever
    binary created them, whatever it's called.
  * Which network interfaces are actually Onload-accelerated is asked
    directly from Onload's own control plane (`onload_mibdump -a llap`,
    which reports hwport assignment — a fact), instead of guessing from a
    NIC driver name. There is no single reliable driver name to match:
    Solarflare/AMD adapters alone span several driver module names across
    generations, and Onload can also accelerate arbitrary AF_XDP-capable
    NICs from any vendor.
* **No hard-coded core IDs or IRQ numbers.** The cores this launch will use
  are extracted once, into script-local variables (`TASKSET_CORE_SPEC`,
  and whatever `EF_IRQ_CORE`/`EF_IRQ_CHANNEL` the profile file itself sets),
  and every existing stack's *actual current* CPU affinity and every NIC
  IRQ's *actual current* `smp_affinity` are read live from
  `/proc/<pid>/task/*/status` and `/proc/interrupts` / `/proc/irq/*` —
  never assumed or guessed from a previous run or from the file name.

## Layout

```
bin/launch_qtRobot1TT.sh               # the launcher (adapted from the original script)
bin/list_available_onload_resources.sh # reports which cores/NIC IRQs are free right now
lib/onload_guard.sh                    # reusable, dependency-free guard functions
tests/fake_proc_fixtures.sh            # shared fake /proc + fake onload_mibdump builder
tests/test_launcher.sh                 # unit + integration tests (fake /proc, no root needed)
tests/test_list_available_onload_resources.sh # tests for the resource-listing tool
```

`lib/onload_guard.sh` has no dependency on the specific application and can
be `source`d from any other Onload launcher (or tool) that needs the same
protection or the same core/IRQ facts.

## How the guard decides

For every core this launch intends to use (`TARGET_CORES` = taskset cores ∪
profile IRQ core):

1. **Stack ownership** — walk every stack in `/proc/driver/onload/stacks`;
   for each one whose creator PID is still alive, inspect every thread's
   `Cpus_allowed_list`. If any thread of an existing stack is allowed to run
   on a target core, that core is "owned" and the launch is blocked. A
   stack whose creator PID has exited (orphan/zombie) is not counted, since
   it can't run on any core anymore.
2. **NIC IRQ steering** — ask Onload's control plane (`onload_mibdump -a
   llap`) which interfaces it currently has hwports assigned to, read
   their IRQs from `/proc/interrupts` and each IRQ's live
   `smp_affinity_list`. If a target core is already handling that NIC's
   interrupts *and* at least one Onload stack is currently active anywhere
   on the host, the launch is blocked too (an idle NIC IRQ with zero active
   stacks is not, by itself, a conflict). If `onload_mibdump` is
   unavailable, this check is skipped (logged as a notice) and check 1
   above remains the primary, name-independent safety net.

Any core with unrestricted affinity (e.g. `0-63`, meaning "not pinned")
overlaps every target core by definition, so an existing, unpinned Onload
stack will also block the launch — this is intentional: on a host where
specific cores must be dedicated, an unpinned stack could be scheduled onto
them at any time.

All filesystem paths and commands the guard reads (`/proc/driver/onload/stacks`,
`/proc`, `onload_mibdump`, `/proc/interrupts`, `/proc/irq`) are overridable
via environment variables (`STACKS_PROC`, `PROC_ROOT`, `ONLOAD_MIBDUMP_CMD`,
`INTERRUPTS_PROC`, `IRQ_PROC_ROOT`), which is how the test suite exercises
every code path against fake fixtures — including a fake `onload_mibdump`
stub — without root or real Onload/Solarflare hardware.

## Usage

```bash
bin/launch_qtRobot1TT.sh
```

Adjust `APP_DIR`, `APP_BIN`, `APP_ARGS`, `ONLOAD_PROFILE` and
`TASKSET_CORE_SPEC` at the top of the script for your deployment; they are
the single source of truth used both for the pre-flight check and for the
actual `taskset`/`onload` invocation.

Run only the pre-flight guard (e.g. from a monitoring/health-check job)
without launching anything:

```bash
CHECK_ONLY=1 bin/launch_qtRobot1TT.sh
```

Exit code `0` means the target cores are free; `1` means an existing stack
(or IRQ) already occupies one of them, with details logged to stderr.

### Finding free cores/IRQs before you configure a launch

`bin/list_available_onload_resources.sh` answers the complementary
question: instead of checking one launch's specific target cores, it walks
*every* CPU core on the host (from `/proc/cpuinfo`) and every IRQ channel
of every Onload-accelerated NIC, and reports which are free right now vs.
already claimed by a live Onload stack — so you can pick a safe
`TASKSET_CORE_SPEC` / `EF_IRQ_CORE` for a *new* launcher before wiring it
up, without guessing.

It reuses the exact same, already-tested "is this core already used by
onload?" logic as the launcher's guard (`onload_guard::check_conflicts`),
so the two tools can never disagree about what counts as busy — see "How
the guard decides" above.

```bash
bin/list_available_onload_resources.sh
```

```
== CPU cores (host has 4: 0 1 2 3) ==
core 0: FREE
core 1: BUSY (core 1 is already owned by an existing onload stack (stack=2 pid=9002))
core 2: FREE
core 3: FREE

== NIC IRQ channels (Onload-accelerated interfaces) ==
irq 77 (if=eth0, affinity=1): BUSY (already steered to a core owned by a live onload stack)

free_cores:0 2 3
busy_cores:1
free_irqs:
busy_irqs:77
```

Useful options/env vars:

* `-q` / `--quiet` — print only the four machine-readable summary lines
  (`free_cores:`, `busy_cores:`, `free_irqs:`, `busy_irqs:`), for scripting:

  ```bash
  TASKSET_CORE_SPEC="$(bin/list_available_onload_resources.sh -q \
    | awk -F: '/^free_cores:/{print $2}' | tr ' ' ',')"
  ```

* `EXCLUDE_CORE_SPEC` — a taskset-style spec (e.g. `"0,1"`) of cores to
  leave out of the report entirely (e.g. cores permanently reserved for
  the OS on this host).

* Same overridable env vars as the launcher's guard
  (`STACKS_PROC`, `PROC_ROOT`, `ONLOAD_MIBDUMP_CMD`, `INTERRUPTS_PROC`,
  `IRQ_PROC_ROOT`), plus `CPUINFO_PROC` for the core list itself.

This tool only reports; it never blocks or launches anything, and always
exits `0` unless it cannot determine the host's cores at all.

## Running the tests

```bash
tests/test_launcher.sh
tests/test_list_available_onload_resources.sh
```

No root privileges or Onload/Solarflare hardware required — both suites
build throwaway fake `/proc` trees per test case (via the shared
`tests/fake_proc_fixtures.sh` builder) and point the tool under test at
them.
