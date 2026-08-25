// onload_guard.hpp
//
// C++ port of lib/onload_guard.sh, meant to be linked directly into the
// launching program itself (rather than shelled out to as a wrapper
// script), so an Onload-accelerated application can refuse to start on
// its own, in-process, before it ever touches the network.
//
// Design invariants (mirrors the bash implementation exactly):
//   * No reliance on any process, stack, thread or driver *name* pattern.
//     Every fact used here comes from a structural, kernel- or
//     control-plane-reported identifier: stack ids and PIDs from
//     /proc/driver/onload/stacks, live CPU affinity from
//     /proc/<pid>/task/*/status, and accelerated interfaces from
//     Onload's own control plane (`onload_mibdump -a llap`) rather than
//     a NIC driver name guess.
//   * No hard-coded core IDs or IRQ numbers - both are read at runtime
//     from the caller-supplied taskset spec / profile file, or straight
//     from the kernel (/proc/interrupts, /proc/irq/*).
//   * Every filesystem path and external command used is a field on
//     GuardConfig, defaulting to the real system location/command, so
//     the exact same logic can be exercised against fake fixtures in
//     tests without root or real Onload/Solarflare hardware.
#pragma once

#include <map>
#include <string>
#include <vector>

namespace onload_guard {

// Expands a taskset / Cpus_allowed_list / smp_affinity_list style core
// spec ("25,26", "0-3,8", "0-63") into a sorted, de-duplicated list of
// individual core numbers. Malformed tokens are silently ignored, since
// callers only ever want to compare numeric core ids.
std::vector<int> expandCoreList(const std::string& spec);

// Reads whatever EF_IRQ_CORE / EF_IRQ_CHANNEL value an Onload tuning
// profile (.opf) actually sets (via `onload_set VAR VALUE` or
// `onload_set VAR=VALUE`), instead of guessing it from the profile's
// file name. Returns an empty, sorted, de-duplicated list if the file
// can't be read or sets no such variable.
std::vector<int> coresFromProfile(const std::string& profilePath);

// Which existing Onload stack (if any) owns a given core right now.
struct StackOwner {
    int stackId = -1;
    long pid = -1;
};

// Which NIC IRQ (if any) is currently steered to a given core.
struct IrqOwner {
    int irq = -1;
    std::string iface;
};

// A single core that conflicts with an already-active Onload stack or
// NIC IRQ, with a human-readable explanation.
struct Conflict {
    int core = -1;
    std::string message;
};

// Every filesystem path / external command the guard reads from. All
// fields default to the real system location, and every field is
// independently overridable - this is what lets the exact same guard
// logic be exercised against fake fixtures in unit tests.
struct GuardConfig {
    // Cores this launch is about to claim via `taskset -c ...`, e.g. "25,26".
    std::string tasksetCoreSpec;
    // Path to the Onload tuning profile (.opf) this launch will use, if
    // any. May declare an additional dedicated IRQ core via
    // EF_IRQ_CORE/EF_IRQ_CHANNEL. Leave empty to skip.
    std::string profilePath;

    std::string stacksProc = "/proc/driver/onload/stacks";
    std::string procRoot = "/proc";
    // Resolved via PATH if it contains no '/', or used as a literal path
    // otherwise (execvp semantics) - never invoked through a shell.
    std::string mibdumpCmd = "onload_mibdump";
    std::string interruptsProc = "/proc/interrupts";
    std::string irqProcRoot = "/proc/irq";
};

// Result of a full pre-flight guard run.
struct GuardReport {
    std::vector<int> targetCores;
    std::vector<Conflict> conflicts;

    bool ok() const { return conflicts.empty(); }
};

// Runs the full pre-flight guard: computes the target cores from
// cfg.tasksetCoreSpec + cfg.profilePath, then checks them against every
// existing Onload stack's live CPU affinity and every accelerated NIC's
// current IRQ affinity. Safe to call unconditionally at process startup,
// before any Onload/network initialization - it only reads /proc and
// (optionally) runs `onload_mibdump`; it never modifies system state.
GuardReport checkLaunch(const GuardConfig& cfg);

// --- Lower-level building blocks, exposed for callers/tests that need ---
// --- finer-grained control than checkLaunch().                       ---

// Walks every stack in <stacksProc>; for each one whose creator PID is
// still alive (checked under <procRoot>), inspects every thread's
// Cpus_allowed_list to determine which cores it currently owns.
// *anyLiveStack is set to true if at least one such stack was found
// (used as a secondary signal by the NIC IRQ check below).
std::map<int, StackOwner> collectStackCoreOwners(const std::string& stacksProc,
                                                  const std::string& procRoot,
                                                  bool* anyLiveStack);

// Runs `<mibdumpCmd> -a llap` and returns, in ifacesOut, every interface
// Onload's control plane reports as accelerated (non-zero TX/RX
// hwports). Returns false (leaving ifacesOut unmodified) if the command
// can't be found or fails - callers must treat that as "unknown", not
// "none accelerated".
bool acceleratedIfaces(const std::string& mibdumpCmd, std::vector<std::string>* ifacesOut);

// For every interface acceleratedIfaces() reports, finds its IRQ
// numbers in <interruptsProc> and reads each IRQ's live
// smp_affinity_list from <irqProcRoot>. Returns an empty map (a no-op,
// not an error) if the accelerated interface list can't be determined.
std::map<int, IrqOwner> collectNicIrqCoreOwners(const std::string& mibdumpCmd,
                                                 const std::string& interruptsProc,
                                                 const std::string& irqProcRoot);

}  // namespace onload_guard
