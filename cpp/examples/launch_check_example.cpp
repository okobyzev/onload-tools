// Example of calling onload_guard directly from inside a launching
// program's own main(), instead of (or in addition to) the bash wrapper
// in bin/launch_qtRobot1TT.sh. This is the pattern an application like
// `1TT` would use: run the guard as the very first thing in main(),
// before opening any sockets or touching the Onload stack, and refuse
// to proceed if another stack already owns the cores this process is
// about to claim.
//
// Usage:
//   launch_check_example [taskset_core_spec] [profile_path]
//
// Environment overrides (mainly for testing without root/real hardware,
// mirroring bin/launch_qtRobot1TT.sh's env vars):
//   ONLOAD_STACKS_PROC, ONLOAD_PROC_ROOT, ONLOAD_MIBDUMP_CMD,
//   ONLOAD_INTERRUPTS_PROC, ONLOAD_IRQ_PROC_ROOT
#include "onload_guard/onload_guard.hpp"

#include <cstdlib>
#include <iostream>

namespace {

std::string envOr(const char* name, const std::string& fallback) {
    const char* v = std::getenv(name);
    return (v && *v) ? std::string(v) : fallback;
}

}  // namespace

int main(int argc, char** argv) {
    onload_guard::GuardConfig cfg;
    cfg.tasksetCoreSpec = argc > 1 ? argv[1] : "25,26";
    cfg.profilePath = argc > 2 ? argv[2] : "/profiles/latency-best-profile-core26.opf";

    cfg.stacksProc = envOr("ONLOAD_STACKS_PROC", cfg.stacksProc);
    cfg.procRoot = envOr("ONLOAD_PROC_ROOT", cfg.procRoot);
    cfg.mibdumpCmd = envOr("ONLOAD_MIBDUMP_CMD", cfg.mibdumpCmd);
    cfg.interruptsProc = envOr("ONLOAD_INTERRUPTS_PROC", cfg.interruptsProc);
    cfg.irqProcRoot = envOr("ONLOAD_IRQ_PROC_ROOT", cfg.irqProcRoot);

    const auto report = onload_guard::checkLaunch(cfg);

    std::cerr << "[onload_guard] target cores:";
    for (int core : report.targetCores) std::cerr << ' ' << core;
    std::cerr << '\n';

    if (!report.ok()) {
        for (const auto& conflict : report.conflicts) {
            std::cerr << "[onload_guard] CONFLICT: " << conflict.message << '\n';
        }
        std::cerr << "[onload_guard] refusing to start: target cores are already in use by an "
                     "existing onload stack.\n";
        return 1;
    }

    std::cerr << "[onload_guard] no existing onload stack found on the target cores - safe to "
                 "start.\n";
    // A real application would now proceed to its normal startup:
    // open its Onload-accelerated sockets, taskset itself onto
    // cfg.tasksetCoreSpec (if not already invoked via `taskset -c ...`
    // from the outside), and run.
    return 0;
}
