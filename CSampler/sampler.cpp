#include "sampler.h"

#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/processor_info.h>
#include <mach/vm_statistics.h>
#include <sys/sysctl.h>
#include <sys/proc_info.h>
#include <libproc.h>

#include <algorithm>
#include <chrono>
#include <string>
#include <unordered_map>
#include <vector>
#include <cstring>

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static uint64_t host_page_bytes() {
    vm_size_t ps = 0;
    host_page_size(mach_host_self(), &ps);
    return static_cast<uint64_t>(ps);
}

// Aggregate CPU ticks from the host (across all cores)
struct CpuSnapshot {
    uint64_t user{}, sys{}, idle{}, nice{};
    uint64_t total()  const { return user + sys + idle + nice; }
    uint64_t active() const { return user + sys + nice; }
};

static CpuSnapshot get_host_cpu_ticks() {
    host_cpu_load_info_data_t info;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO,
                    reinterpret_cast<host_info_t>(&info), &count);
    CpuSnapshot s;
    s.user = info.cpu_ticks[CPU_STATE_USER];
    s.sys  = info.cpu_ticks[CPU_STATE_SYSTEM];
    s.idle = info.cpu_ticks[CPU_STATE_IDLE];
    s.nice = info.cpu_ticks[CPU_STATE_NICE];
    return s;
}

// ---------------------------------------------------------------------------
// SamplerImpl
// ---------------------------------------------------------------------------

struct ProcState {
    uint64_t cpuNs{};                          // accumulated CPU ns at last sample
    std::chrono::steady_clock::time_point ts;  // wall-clock time at last sample
};

class SamplerImpl {
public:
    SamplerImpl() : prevCpu_(get_host_cpu_ticks()) {}

    void take(SystemSample& out, int topN) {
        std::memset(&out, 0, sizeof(out));

        // --- System CPU % (delta ticks) ---
        CpuSnapshot cur = get_host_cpu_ticks();
        uint64_t totalDelta  = cur.total()  - prevCpu_.total();
        uint64_t activeDelta = cur.active() - prevCpu_.active();
        out.systemCpuPercent = totalDelta > 0
            ? 100.0 * static_cast<double>(activeDelta) / static_cast<double>(totalDelta)
            : 0.0;
        prevCpu_ = cur;

        // --- Memory (vm_statistics64) ---
        const uint64_t pageBytes = host_page_bytes();
        vm_statistics64_data_t vmStats;
        mach_msg_type_number_t vmCount = HOST_VM_INFO64_COUNT;
        host_statistics64(mach_host_self(), HOST_VM_INFO64,
                          reinterpret_cast<host_info64_t>(&vmStats), &vmCount);

        out.freeMemoryBytes       = vmStats.free_count                * pageBytes;
        out.activeMemoryBytes     = vmStats.active_count              * pageBytes;
        out.wiredMemoryBytes      = vmStats.wire_count                * pageBytes;
        out.compressedMemoryBytes = vmStats.compressor_page_count     * pageBytes;
        out.totalMemoryBytes      = sampler_total_memory();

        // --- Per-process info via proc_pidinfo (no elevated privileges needed) ---
        fill_processes(out, topN);
    }

private:
    CpuSnapshot prevCpu_;
    std::unordered_map<int, ProcState> procHistory_;

    void fill_processes(SystemSample& out, int topN) {
        // Enumerate all PIDs
        int needed = proc_listallpids(nullptr, 0);
        if (needed <= 0) return;

        std::vector<int> pids(static_cast<size_t>(needed));
        int actual = proc_listallpids(pids.data(),
                                      static_cast<int>(pids.size() * sizeof(int)));
        if (actual <= 0) return;
        pids.resize(static_cast<size_t>(actual));

        auto now = std::chrono::steady_clock::now();

        struct ProcData {
            int      pid{};
            char     name[256]{};
            double   cpuPct{};
            uint64_t rss{};
            uint64_t virt{};
            uint32_t threads{};
        };

        std::vector<ProcData> procs;
        procs.reserve(pids.size());

        for (int pid : pids) {
            if (pid <= 0) continue;

            struct proc_taskinfo pti;
            int ret = proc_pidinfo(pid, PROC_PIDTASKINFO, 0,
                                   &pti, sizeof(pti));
            if (ret != sizeof(pti)) continue;

            // CPU delta: pti_total_user + pti_total_system are nanoseconds
            uint64_t cpuNsNow = pti.pti_total_user + pti.pti_total_system;
            double cpuPct = 0.0;

            auto it = procHistory_.find(pid);
            if (it != procHistory_.end()) {
                uint64_t cpuDelta = cpuNsNow - it->second.cpuNs;
                auto wallNs = std::chrono::duration_cast<std::chrono::nanoseconds>(
                    now - it->second.ts).count();
                if (wallNs > 0)
                    cpuPct = 100.0 * static_cast<double>(cpuDelta)
                                   / static_cast<double>(wallNs);
            }
            procHistory_[pid] = { cpuNsNow, now };

            char nameBuf[256] = {};
            proc_name(pid, nameBuf, sizeof(nameBuf));

            ProcData d;
            d.pid     = pid;
            d.rss     = pti.pti_resident_size;
            d.virt    = pti.pti_virtual_size;
            d.threads = static_cast<uint32_t>(pti.pti_threadnum);
            d.cpuPct  = cpuPct;
            std::strncpy(d.name, nameBuf[0] ? nameBuf : "(unknown)", 255);
            procs.push_back(d);
        }

        // Evict stale PIDs from history
        for (auto it = procHistory_.begin(); it != procHistory_.end(); ) {
            bool alive = std::any_of(pids.begin(), pids.end(),
                                     [&](int p){ return p == it->first; });
            it = alive ? std::next(it) : procHistory_.erase(it);
        }

        // Sort by RSS descending, take topN
        std::sort(procs.begin(), procs.end(),
                  [](const ProcData& a, const ProcData& b){ return a.rss > b.rss; });

        int count = std::min(static_cast<int>(procs.size()),
                             std::min(topN, 32));
        out.processCount = count;
        for (int i = 0; i < count; ++i) {
            out.processes[i].pid           = procs[i].pid;
            out.processes[i].residentBytes = procs[i].rss;
            out.processes[i].virtualBytes  = procs[i].virt;
            out.processes[i].threadCount   = procs[i].threads;
            out.processes[i].cpuPercent    = procs[i].cpuPct;
            std::strncpy(out.processes[i].name, procs[i].name, 255);
        }
    }
};

// ---------------------------------------------------------------------------
// C interface
// ---------------------------------------------------------------------------

extern "C" {

SamplerHandle sampler_create() {
    return new SamplerImpl();
}

void sampler_destroy(SamplerHandle h) {
    delete static_cast<SamplerImpl*>(h);
}

int sampler_take(SamplerHandle h, SystemSample* out, int topN) {
    if (!h || !out) return -1;
    static_cast<SamplerImpl*>(h)->take(*out, topN);
    return 0;
}

uint64_t sampler_total_memory() {
    int mib[2] = { CTL_HW, HW_MEMSIZE };
    uint64_t total = 0;
    size_t len = sizeof(total);
    sysctl(mib, 2, &total, &len, nullptr, 0);
    return total;
}

} // extern "C"
