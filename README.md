# onload-tools

Tooling for launching [Onload](https://github.com/Xilinx-CNS/onload)-accelerated
programs safely on shared, core-pinned hosts.

## Why this exists

Latency-sensitive Onload applications are normally started with a dedicated
`taskset` core list and a tuning profile (`.opf`) that may additionally
dedicate a core to NIC interrupt handling (`EF_IRQ_CORE` / `EF_IRQ_CHANNEL`).
If a previous instance (or any other, unrelated Onload program) is still
running and pinned to one of those same cores, starting a second stack on
top of it silently degrades both — instead of failing fast and loud.

There are two implementations of the same pre-flight guard, sharing the
exact same logic and test scenarios:

* **`lib/onload_guard.sh` + `bin/launch_qtRobot1TT.sh`** — a bash library
  and an external wrapper script that runs the guard, then `exec`s
  `taskset`/`onload` in front of the real application. Use this when you
  don't control the application's source (or don't want to rebuild it) and
  can wrap its launch instead.
* **`cpp/`** — a C++17 library (`onload_guard`) exposing the identical
  checks as a set of plain functions, meant to be linked directly into the
  launching program itself and called at the very top of its own `main()`,
  before it touches the network. Use this when you *do* control the
  application's source and want it to refuse to start on its own, without
  depending on an external wrapper.

Both refuse to start the program if any of the CPU cores (or the NIC IRQ
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
bin/launch_qtRobot1TT.sh   # bash launcher (adapted from the original script)
lib/onload_guard.sh        # reusable, dependency-free bash guard functions
tests/test_launcher.sh     # bash unit + integration tests (fake /proc, no root needed)

cpp/                       # C++17 port of the same guard, for in-process use
  include/onload_guard/onload_guard.hpp
  src/onload_guard.cpp
  tests/test_onload_guard.cpp   # GoogleTest unit + integration tests
  examples/launch_check_example.cpp
```

`lib/onload_guard.sh` has no dependency on the specific application and can
be `source`d from any other Onload launcher that needs the same protection.
Likewise, `onload_guard` (the C++ library under `cpp/`) has no dependency on
any specific application and can be linked into any launching program.

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

## Running the bash tests

```bash
tests/test_launcher.sh
```

No root privileges or Onload/Solarflare hardware required — the suite
builds throwaway fake `/proc` and `/sys` trees per test case and points the
guard at them.

## C++ library (`cpp/`) — using the guard from inside your own launcher

`onload_guard` exposes the same checks as plain functions over a small,
dependency-free (standard library + POSIX only) API:

```cpp
#include "onload_guard/onload_guard.hpp"

onload_guard::GuardConfig cfg;
cfg.tasksetCoreSpec = "25,26";
cfg.profilePath = "/profiles/latency-best-profile-core26.opf";

const auto report = onload_guard::checkLaunch(cfg);
if (!report.ok()) {
    for (const auto& conflict : report.conflicts) {
        std::cerr << "CONFLICT: " << conflict.message << "\n";
    }
    return 1;  // refuse to start
}
// ... proceed with normal startup ...
```

Call this as the very first thing in the launching program's `main()`,
before it opens any sockets or otherwise touches the Onload stack. See
`cpp/examples/launch_check_example.cpp` for a runnable version of the
snippet above.

Every field on `GuardConfig` besides `tasksetCoreSpec`/`profilePath`
defaults to the real system path/command (`/proc/driver/onload/stacks`,
`/proc`, `onload_mibdump`, `/proc/interrupts`, `/proc/irq`) and can be
overridden independently — the same mechanism the bash implementation
uses to stay testable without root or real hardware.

### Building and testing

```bash
cmake -S cpp -B cpp/build -DCMAKE_BUILD_TYPE=Release
cmake --build cpp/build -j"$(nproc)"
ctest --test-dir cpp/build --output-on-failure
```

This produces a static `libonload_guard.a` (see `cpp/CMakeLists.txt` for
the exported CMake target `onload_guard::onload_guard`, installable and
consumable via `find_package`/`add_subdirectory`), a GoogleTest-based test
suite (`cpp/tests/`, fetched automatically via CMake `FetchContent` — no
system package required), and the example above
(`cpp/build/examples/launch_check_example`). The test suite builds fake
`/proc` trees and a stub `onload_mibdump` per test case, so it needs no
root privileges or real Onload/Solarflare hardware, and covers the same
scenarios as `tests/test_launcher.sh`.

To disable building the tests/examples (e.g. when consuming this as a
subdirectory of a larger CMake project):

```bash
cmake -S cpp -B cpp/build -DONLOAD_GUARD_BUILD_TESTS=OFF -DONLOAD_GUARD_BUILD_EXAMPLES=OFF
```
