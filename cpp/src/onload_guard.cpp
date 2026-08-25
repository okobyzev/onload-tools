#include "onload_guard/onload_guard.hpp"

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <regex>
#include <sstream>
#include <system_error>

#include <fcntl.h>
#include <sys/wait.h>
#include <unistd.h>

namespace onload_guard {

namespace {

namespace fs = std::filesystem;

std::string trim(const std::string& s) {
    size_t start = s.find_first_not_of(" \t\r\n");
    if (start == std::string::npos) return "";
    size_t end = s.find_last_not_of(" \t\r\n");
    return s.substr(start, end - start + 1);
}

bool isAllDigits(const std::string& s) {
    return !s.empty() &&
           std::all_of(s.begin(), s.end(), [](unsigned char c) { return std::isdigit(c) != 0; });
}

// Runs argv[0] with the given arguments (no shell involved - argv[0] is
// executed directly via execvp, so it is never subject to shell
// metacharacter expansion) and captures its stdout. Returns false if the
// process can't be started or exits non-zero, matching the bash
// reference's `cmd 2>/dev/null` / `|| return 1` behaviour.
bool runCommandCaptureStdout(const std::vector<std::string>& argv, std::string* output) {
    if (argv.empty()) return false;

    int pipefd[2];
    if (pipe(pipefd) != 0) return false;

    pid_t pid = fork();
    if (pid < 0) {
        close(pipefd[0]);
        close(pipefd[1]);
        return false;
    }

    if (pid == 0) {
        // Child.
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) {
            dup2(devnull, STDERR_FILENO);
            close(devnull);
        }
        close(pipefd[1]);

        std::vector<char*> cargv;
        cargv.reserve(argv.size() + 1);
        for (const auto& a : argv) cargv.push_back(const_cast<char*>(a.c_str()));
        cargv.push_back(nullptr);

        execvp(cargv[0], cargv.data());
        _exit(127);  // execvp failed (e.g. command not found).
    }

    // Parent.
    close(pipefd[1]);
    output->clear();
    char buf[4096];
    ssize_t n;
    while ((n = read(pipefd[0], buf, sizeof(buf))) > 0) {
        output->append(buf, static_cast<size_t>(n));
    }
    close(pipefd[0]);

    int status = 0;
    if (waitpid(pid, &status, 0) < 0) return false;
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

}  // namespace

std::vector<int> expandCoreList(const std::string& spec) {
    std::vector<int> out;
    std::stringstream ss(spec);
    std::string token;
    while (std::getline(ss, token, ',')) {
        token = trim(token);
        if (token.empty()) continue;

        auto dash = token.find('-');
        if (dash != std::string::npos && dash > 0 && dash + 1 < token.size()) {
            std::string aStr = token.substr(0, dash);
            std::string bStr = token.substr(dash + 1);
            if (!isAllDigits(aStr) || !isAllDigits(bStr)) continue;
            int a = std::stoi(aStr);
            int b = std::stoi(bStr);
            if (a > b) std::swap(a, b);
            for (int i = a; i <= b; ++i) out.push_back(i);
        } else if (isAllDigits(token)) {
            out.push_back(std::stoi(token));
        }
        // Anything else (e.g. "all", garbage) is silently ignored.
    }
    std::sort(out.begin(), out.end());
    out.erase(std::unique(out.begin(), out.end()), out.end());
    return out;
}

std::vector<int> coresFromProfile(const std::string& profilePath) {
    std::vector<int> out;
    if (profilePath.empty()) return out;

    std::ifstream in(profilePath);
    if (!in) return out;

    static const std::regex irqVarRe(R"(EF_IRQ_(CORE|CHANNEL)[[:space:]=]+([0-9,-]+))");
    std::string line;
    while (std::getline(in, line)) {
        std::smatch m;
        if (std::regex_search(line, m, irqVarRe)) {
            auto cores = expandCoreList(m[2].str());
            out.insert(out.end(), cores.begin(), cores.end());
        }
    }
    std::sort(out.begin(), out.end());
    out.erase(std::unique(out.begin(), out.end()), out.end());
    return out;
}

std::map<int, StackOwner> collectStackCoreOwners(const std::string& stacksProc,
                                                  const std::string& procRoot,
                                                  bool* anyLiveStack) {
    std::map<int, StackOwner> owners;
    if (anyLiveStack) *anyLiveStack = false;

    std::ifstream in(stacksProc);
    if (!in) return owners;

    std::string line;
    while (std::getline(in, line)) {
        if (line.empty()) continue;

        auto colon = line.find(':');
        if (colon == std::string::npos) continue;

        std::string idStr = line.substr(0, colon);
        if (!isAllDigits(idStr)) continue;
        int stackId = std::stoi(idStr);

        std::string rest = trim(line.substr(colon + 1));
        auto sp = rest.find_first_of(" \t");
        std::string pidStr = (sp == std::string::npos) ? rest : rest.substr(0, sp);
        if (!isAllDigits(pidStr)) continue;
        long pid = std::stol(pidStr);

        std::error_code ec;
        fs::path pidDir = fs::path(procRoot) / pidStr;
        if (!fs::exists(pidDir, ec) || !fs::is_directory(pidDir, ec)) {
            // Creator process is gone: an orphan/zombie stack has no live
            // thread affinity to check, so it cannot own a core right now.
            continue;
        }

        if (anyLiveStack) *anyLiveStack = true;

        fs::path taskDir = pidDir / "task";
        if (!fs::exists(taskDir, ec)) continue;

        for (const auto& entry : fs::directory_iterator(taskDir, ec)) {
            fs::path statusFile = entry.path() / "status";
            std::ifstream statusIn(statusFile);
            if (!statusIn) continue;

            std::string sline;
            while (std::getline(statusIn, sline)) {
                static const std::string prefix = "Cpus_allowed_list:";
                if (sline.rfind(prefix, 0) != 0) continue;
                std::string value = trim(sline.substr(prefix.size()));
                for (int core : expandCoreList(value)) {
                    owners[core] = StackOwner{stackId, pid};
                }
                break;
            }
        }
    }
    return owners;
}

bool acceleratedIfaces(const std::string& mibdumpCmd, std::vector<std::string>* ifacesOut) {
    if (!ifacesOut) return false;

    std::string output;
    if (!runCommandCaptureStdout({mibdumpCmd, "-a", "llap"}, &output)) return false;

    static const std::regex llapLineRe(R"(^llap\[[0-9]+\]:\s+(\S+)\s+\()");
    static const std::regex hwportsRe(R"((TX|RX)\s+hwports\s+[0-9])");

    std::istringstream iss(output);
    std::string line;
    std::string curIface;
    bool accelerated = false;

    auto flush = [&]() {
        if (!curIface.empty() && accelerated) ifacesOut->push_back(curIface);
        curIface.clear();
        accelerated = false;
    };

    while (std::getline(iss, line)) {
        std::smatch m;
        if (std::regex_search(line, m, llapLineRe)) {
            flush();
            curIface = m[1].str();
        } else if (std::regex_search(line, hwportsRe)) {
            accelerated = true;
        }
    }
    flush();
    return true;
}

std::map<int, IrqOwner> collectNicIrqCoreOwners(const std::string& mibdumpCmd,
                                                 const std::string& interruptsProc,
                                                 const std::string& irqProcRoot) {
    std::map<int, IrqOwner> owners;

    std::vector<std::string> ifaces;
    if (!acceleratedIfaces(mibdumpCmd, &ifaces) || ifaces.empty()) return owners;

    std::ifstream interruptsIn(interruptsProc);
    if (!interruptsIn) return owners;

    std::vector<std::string> lines;
    std::string line;
    while (std::getline(interruptsIn, line)) lines.push_back(line);

    for (const auto& iface : ifaces) {
        for (const auto& l : lines) {
            if (l.find(iface) == std::string::npos) continue;

            auto colon = l.find(':');
            if (colon == std::string::npos) continue;
            std::string irqStr = trim(l.substr(0, colon));
            if (!isAllDigits(irqStr)) continue;
            int irq = std::stoi(irqStr);

            fs::path affFile = fs::path(irqProcRoot) / irqStr / "smp_affinity_list";
            std::ifstream affIn(affFile);
            if (!affIn) continue;
            std::string aff;
            std::getline(affIn, aff);

            for (int core : expandCoreList(aff)) {
                owners[core] = IrqOwner{irq, iface};
            }
        }
    }
    return owners;
}

GuardReport checkLaunch(const GuardConfig& cfg) {
    GuardReport report;

    std::vector<int> taskset = expandCoreList(cfg.tasksetCoreSpec);
    std::vector<int> profileCores = coresFromProfile(cfg.profilePath);

    std::vector<int> target;
    target.reserve(taskset.size() + profileCores.size());
    target.insert(target.end(), taskset.begin(), taskset.end());
    target.insert(target.end(), profileCores.begin(), profileCores.end());
    std::sort(target.begin(), target.end());
    target.erase(std::unique(target.begin(), target.end()), target.end());
    report.targetCores = target;

    bool anyLiveStack = false;
    auto stackOwners = collectStackCoreOwners(cfg.stacksProc, cfg.procRoot, &anyLiveStack);
    auto irqOwners = collectNicIrqCoreOwners(cfg.mibdumpCmd, cfg.interruptsProc, cfg.irqProcRoot);

    for (int core : target) {
        auto sIt = stackOwners.find(core);
        if (sIt != stackOwners.end()) {
            std::ostringstream msg;
            msg << "core " << core << " is already owned by an existing onload stack (stack="
                << sIt->second.stackId << " pid=" << sIt->second.pid << ")";
            report.conflicts.push_back(Conflict{core, msg.str()});
            continue;
        }

        auto iIt = irqOwners.find(core);
        if (iIt != irqOwners.end() && anyLiveStack) {
            std::ostringstream msg;
            msg << "core " << core << " already handles NIC interrupts (irq=" << iIt->second.irq
                << " if=" << iIt->second.iface << ") while at least one onload stack is active";
            report.conflicts.push_back(Conflict{core, msg.str()});
        }
    }

    return report;
}

}  // namespace onload_guard
