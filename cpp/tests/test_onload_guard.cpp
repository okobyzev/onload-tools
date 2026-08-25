// Unit + integration tests for onload_guard.hpp, mirroring
// tests/test_launcher.sh (the bash reference implementation) so both
// ports are verified against the same scenarios.
//
// Builds fake /proc trees and a fake `onload_mibdump` script per test -
// no root privileges or real Onload/Solarflare hardware required.

#include "onload_guard/onload_guard.hpp"

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>

#include <sys/stat.h>
#include <unistd.h>

#include <gtest/gtest.h>

namespace {

namespace fs = std::filesystem;

std::string writeFile(const fs::path& path, const std::string& contents) {
    fs::create_directories(path.parent_path());
    std::ofstream out(path);
    out << contents;
    return path.string();
}

void appendFile(const fs::path& path, const std::string& contents) {
    fs::create_directories(path.parent_path());
    std::ofstream out(path, std::ios::app);
    out << contents;
}

// RAII fake filesystem tree standing in for /proc, plus a fake
// `onload_mibdump` executable, used to exercise onload_guard's logic
// without needing real Onload/Solarflare hardware or root.
class FakeEnv {
public:
    FakeEnv() {
        char tmpl[] = "/tmp/onload_guard_test_XXXXXX";
        char* dir = mkdtemp(tmpl);
        root_ = dir;
        fs::create_directories(root_ / "proc/driver/onload");
        fs::create_directories(root_ / "proc/irq");
        fs::create_directories(root_ / "bin");
        writeFile(stacksProc(), "");
        writeFile(interruptsProc(), "");
        writeFakeMibdump("");
    }

    ~FakeEnv() {
        std::error_code ec;
        fs::remove_all(root_, ec);
    }

    fs::path root() const { return root_; }
    std::string stacksProc() const { return (root_ / "proc/driver/onload/stacks").string(); }
    std::string procRoot() const { return (root_ / "proc").string(); }
    std::string interruptsProc() const { return (root_ / "proc/interrupts").string(); }
    std::string irqProcRoot() const { return (root_ / "proc/irq").string(); }
    std::string mibdumpCmd() const { return (root_ / "bin/onload_mibdump").string(); }
    std::string missingMibdumpCmd() const { return (root_ / "bin/does_not_exist").string(); }

    // Registers an Onload stack. If cpusAllowed is non-empty, a "live"
    // owning PID is simulated by creating its directory under the fake
    // /proc root with that Cpus_allowed_list. If empty, the stack is an
    // orphan: its PID directory is never created under the fake /proc
    // root, so collectStackCoreOwners() will treat it as dead.
    void addStack(int stackId, long pid, const std::string& cpusAllowed) {
        std::ostringstream line;
        line << stackId << ": " << pid
             << " 1000 13 0 0 1 2 0 3 0 0 1 0 4 0 5 0 0 0 0 0 0 6 7\n";
        appendFile(stacksProc(), line.str());

        if (!cpusAllowed.empty()) {
            fs::path taskDir = root_ / "proc" / std::to_string(pid) / "task" / std::to_string(pid);
            fs::create_directories(taskDir);
            std::ostringstream status;
            status << "Name:\tfake_stack_owner\n"
                    << "Pid:\t" << pid << "\n"
                    << "Cpus_allowed_list:\t" << cpusAllowed << "\n";
            writeFile(taskDir / "status", status.str());
        }
    }

    // Registers an interface Onload's control plane reports as
    // accelerated (non-zero hwports), with an IRQ pinned to `affinity`.
    void addNic(const std::string& iface, int irq, const std::string& affinity) {
        llapOutput_ << "llap[" << nextLlapIndex_++ << "]: " << iface
                    << " (1) UP mtu 1500 arp_base 30000ms\n"
                    << "         TX hwports 1\n"
                    << "         RX hwports 1\n";
        writeFakeMibdump(llapOutput_.str());
        registerIrq(iface, irq, affinity);
    }

    // Registers an interface Onload's control plane reports as NOT
    // accelerated ("no ... hwports"), with an IRQ anyway - proves such
    // interfaces never contribute to a conflict.
    void addNonAcceleratedNic(const std::string& iface, int irq, const std::string& affinity) {
        llapOutput_ << "llap[" << nextLlapIndex_++ << "]: " << iface
                    << " (1) UP mtu 1500 arp_base 30000ms\n"
                    << "         no TX hwports\n"
                    << "         no RX hwports\n";
        writeFakeMibdump(llapOutput_.str());
        registerIrq(iface, irq, affinity);
    }

    void removeMibdump() {
        std::error_code ec;
        fs::remove(root_ / "bin/onload_mibdump", ec);
    }

    onload_guard::GuardConfig baseConfig(const std::string& tasksetCoreSpec = "25,26",
                                          const std::string& profilePath = "") const {
        onload_guard::GuardConfig cfg;
        cfg.tasksetCoreSpec = tasksetCoreSpec;
        cfg.profilePath = profilePath;
        cfg.stacksProc = stacksProc();
        cfg.procRoot = procRoot();
        cfg.mibdumpCmd = mibdumpCmd();
        cfg.interruptsProc = interruptsProc();
        cfg.irqProcRoot = irqProcRoot();
        return cfg;
    }

private:
    void writeFakeMibdump(const std::string& llapOutput) {
        std::ostringstream script;
        script << "#!/bin/bash\ncat <<'LLAP_EOF'\n" << llapOutput << "\nLLAP_EOF\n";
        fs::path path = root_ / "bin/onload_mibdump";
        writeFile(path, script.str());
        chmod(path.c_str(), 0755);
    }

    void registerIrq(const std::string& iface, int irq, const std::string& affinity) {
        std::ostringstream line;
        line << " " << irq << ":   111   222   0   0  IR-PCI-MSI-edge      " << iface << "-0\n";
        appendFile(interruptsProc(), line.str());
        writeFile(root_ / "proc/irq" / std::to_string(irq) / "smp_affinity_list", affinity + "\n");
    }

    fs::path root_;
    std::ostringstream llapOutput_;
    int nextLlapIndex_ = 0;
};

}  // namespace

// --------------------------------------------------------------------
// expandCoreList
// --------------------------------------------------------------------

TEST(ExpandCoreList, SimpleList) {
    EXPECT_EQ(onload_guard::expandCoreList("25,26"), (std::vector<int>{25, 26}));
}

TEST(ExpandCoreList, Range) {
    EXPECT_EQ(onload_guard::expandCoreList("0-3"), (std::vector<int>{0, 1, 2, 3}));
}

TEST(ExpandCoreList, MixedRangeAndList) {
    EXPECT_EQ(onload_guard::expandCoreList("0-1,8-10"), (std::vector<int>{0, 1, 8, 9, 10}));
}

TEST(ExpandCoreList, DeduplicatesAndSorts) {
    EXPECT_EQ(onload_guard::expandCoreList("26,25,25,26"), (std::vector<int>{25, 26}));
}

TEST(ExpandCoreList, EmptySpec) {
    EXPECT_TRUE(onload_guard::expandCoreList("").empty());
}

TEST(ExpandCoreList, IgnoresGarbageTokens) {
    EXPECT_EQ(onload_guard::expandCoreList("5,all,6"), (std::vector<int>{5, 6}));
}

// --------------------------------------------------------------------
// coresFromProfile
// --------------------------------------------------------------------

TEST(CoresFromProfile, ParsesSpaceForm) {
    FakeEnv env;
    fs::path profile = env.root() / "profile.opf";
    writeFile(profile,
              "# example profile\n"
              "onload_set EF_POLL_USEC 100000\n"
              "onload_set EF_IRQ_CORE 26\n"
              "onload_set EF_TCP_FASTSTART_INIT 0\n");
    EXPECT_EQ(onload_guard::coresFromProfile(profile.string()), (std::vector<int>{26}));
}

TEST(CoresFromProfile, ParsesEqualsForm) {
    FakeEnv env;
    fs::path profile = env.root() / "profile2.opf";
    writeFile(profile, "EF_IRQ_CHANNEL=7\n");
    EXPECT_EQ(onload_guard::coresFromProfile(profile.string()), (std::vector<int>{7}));
}

TEST(CoresFromProfile, MissingFileIsEmpty) {
    EXPECT_TRUE(onload_guard::coresFromProfile("/no/such/profile.opf").empty());
}

TEST(CoresFromProfile, EmptyPathIsEmpty) {
    EXPECT_TRUE(onload_guard::coresFromProfile("").empty());
}

// --------------------------------------------------------------------
// acceleratedIfaces
// --------------------------------------------------------------------

TEST(AcceleratedIfaces, ParsesLlapOutputExcludingNonAccelerated) {
    FakeEnv env;
    fs::path script = env.root() / "bin/mibdump_sample";
    writeFile(script,
              "#!/bin/bash\n"
              "cat <<'EOF'\n"
              "llap[000]: enp4s0f1 (650) UP mtu 1500 arp_base 30000ms\n"
              "         TX hwports 1\n"
              "         RX hwports 1\n"
              "llap[001]:       lo (1) UP mtu 65535 arp_base 30000ms\n"
              "         no TX hwports\n"
              "         no RX hwports\n"
              "llap[002]:     eth0 (652) UP mtu 1500 arp_base 30000ms\n"
              "         TX hwports 2\n"
              "         RX hwports 2\n"
              "EOF\n");
    chmod(script.c_str(), 0755);

    std::vector<std::string> ifaces;
    ASSERT_TRUE(onload_guard::acceleratedIfaces(script.string(), &ifaces));
    EXPECT_EQ(ifaces, (std::vector<std::string>{"enp4s0f1", "eth0"}));
}

TEST(AcceleratedIfaces, MissingCommandReturnsFalse) {
    std::vector<std::string> ifaces;
    EXPECT_FALSE(onload_guard::acceleratedIfaces("/definitely/not/a/real/command", &ifaces));
    EXPECT_TRUE(ifaces.empty());
}

// --------------------------------------------------------------------
// checkLaunch - integration scenarios (mirrors test_launcher.sh)
// --------------------------------------------------------------------

TEST(CheckLaunch, AllowsWhenNoStacksOrIrqsExist) {
    FakeEnv env;
    auto report = onload_guard::checkLaunch(env.baseConfig());
    EXPECT_TRUE(report.ok());
    EXPECT_EQ(report.targetCores, (std::vector<int>{25, 26}));
}

TEST(CheckLaunch, AllowsWhenExistingStackOnUnrelatedCore) {
    FakeEnv env;
    env.addStack(9, 90001, "5");
    auto report = onload_guard::checkLaunch(env.baseConfig());
    EXPECT_TRUE(report.ok());
}

TEST(CheckLaunch, BlocksWhenExistingStackOccupiesTargetCore) {
    FakeEnv env;
    env.addStack(2, 90002, "26");
    auto report = onload_guard::checkLaunch(env.baseConfig());
    ASSERT_FALSE(report.ok());
    EXPECT_EQ(report.conflicts.size(), 1u);
    EXPECT_EQ(report.conflicts[0].core, 26);
    EXPECT_NE(report.conflicts[0].message.find("stack=2"), std::string::npos);
}

TEST(CheckLaunch, BlocksWhenExistingStackAffinityRangeCoversTargetCore) {
    FakeEnv env;
    env.addStack(16, 90003, "20-30");
    auto report = onload_guard::checkLaunch(env.baseConfig());
    EXPECT_FALSE(report.ok());
}

TEST(CheckLaunch, OrphanStackIsNotAConflict) {
    FakeEnv env;
    env.addStack(3, 999999999, "");  // no live PID => orphan/zombie stack
    auto report = onload_guard::checkLaunch(env.baseConfig());
    EXPECT_TRUE(report.ok());
}

TEST(CheckLaunch, BlocksWhenNicIrqOnTargetCoreWithLiveStack) {
    FakeEnv env;
    env.addStack(8, 90004, "5");  // live stack, but not on 25/26 itself
    env.addNic("eth0", 77, "26");
    auto report = onload_guard::checkLaunch(env.baseConfig());
    ASSERT_FALSE(report.ok());
    EXPECT_EQ(report.conflicts[0].core, 26);
    EXPECT_NE(report.conflicts[0].message.find("irq=77"), std::string::npos);
}

TEST(CheckLaunch, AllowsNicIrqOnTargetCoreWithoutLiveStack) {
    FakeEnv env;
    env.addNic("eth0", 78, "26");  // IRQ steering only, no onload stacks active
    auto report = onload_guard::checkLaunch(env.baseConfig());
    EXPECT_TRUE(report.ok());
}

TEST(CheckLaunch, IgnoresNonAcceleratedNic) {
    FakeEnv env;
    env.addStack(5, 90005, "5");
    env.addNonAcceleratedNic("eth1", 99, "26");
    auto report = onload_guard::checkLaunch(env.baseConfig());
    EXPECT_TRUE(report.ok());
}

TEST(CheckLaunch, MissingMibdumpStillBlocksOnStackAffinity) {
    FakeEnv env;
    env.removeMibdump();
    env.addStack(2, 90006, "26");
    auto cfg = env.baseConfig();
    cfg.mibdumpCmd = env.missingMibdumpCmd();
    auto report = onload_guard::checkLaunch(cfg);
    ASSERT_FALSE(report.ok());
    EXPECT_EQ(report.conflicts[0].core, 26);
}

TEST(CheckLaunch, ProfileIrqCoreIsIncludedInTargetCores) {
    FakeEnv env;
    fs::path profile = env.root() / "profile.opf";
    writeFile(profile, "onload_set EF_IRQ_CORE 40\n");
    auto report = onload_guard::checkLaunch(env.baseConfig("25,26", profile.string()));
    EXPECT_EQ(report.targetCores, (std::vector<int>{25, 26, 40}));
}
