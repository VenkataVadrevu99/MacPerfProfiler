# MacPerfProfiler

A lightweight macOS command-line tool that samples system and per-process CPU, memory, and thread metrics in real time.

Built to explore Apple's low-level system APIs — specifically the Mach kernel interfaces that Activity Monitor and Instruments use under the hood.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Swift layer  (Monitor.swift, Formatter.swift)       │
│  • DispatchSourceTimer on .utility QoS queue         │
│  • os_signpost intervals → visible in Instruments    │
│  • JSON or formatted terminal output                 │
└────────────────────┬────────────────────────────────┘
                     │  C interface (sampler.h)
┌────────────────────▼────────────────────────────────┐
│  C++ core  (sampler.cpp)                             │
│  • host_statistics()  → system-wide CPU ticks        │
│  • host_statistics64() → vm_statistics64 memory      │
│  • proc_pidinfo(PROC_PIDTASKINFO) → per-process RSS, │
│    virtual size, thread count, accumulated CPU ns    │
│  • Delta CPU% computed from consecutive snapshots    │
│  • std::unordered_map tracks per-PID CPU history     │
└─────────────────────────────────────────────────────┘
```

The C++ core is compiled as a separate SPM target and linked into the Swift executable. The Swift/C++ boundary uses a plain C interface (`extern "C"`) via a public header — the most portable interop approach across Swift versions.

## Build

Requires macOS 13+, Xcode 15+ (Swift 5.9+), and the Xcode Command Line Tools.

```bash
git clone https://github.com/YOUR_USERNAME/MacPerfProfiler.git
cd MacPerfProfiler
swift build -c release
```

Run:

```bash
.build/release/MacPerfProfiler                   # 1s interval, top 10 processes
.build/release/MacPerfProfiler -i 0.5 -n 15      # 500ms interval, top 15
.build/release/MacPerfProfiler --json | head -5   # JSON lines output
.build/release/MacPerfProfiler -c 10              # exit after 10 samples
```

## Tests

```bash
swift test
```

Tests cover: sampler lifecycle, memory field population, CPU delta correctness across two samples, topN enforcement, null-safety of the C interface, and a sampling overhead bound (< 50% own CPU across 5 ticks).

## Instruments Integration

The sampler emits `os_signpost` intervals under:

```
subsystem: com.vadrevu.MacPerfProfiler
category:  sampling
name:      SampleTick
```

To measure sampling overhead live:

1. Build in debug: `swift build`
2. Run the binary
3. Open Instruments → Time Profiler
4. Attach to the running PID
5. The **Points of Interest** track shows each `SampleTick` interval

On an M2 MacBook Pro at 1s interval with 10 processes, `SampleTick` duration is typically 1–4 ms, well under 0.5% of a 1000 ms window.

## Key APIs Used

| API | Source | Purpose |
|-----|--------|---------|
| `host_statistics` | `mach/mach_host.h` | Aggregate CPU ticks |
| `host_statistics64` | `mach/mach_host.h` | vm_statistics64 memory fields |
| `proc_listallpids` | `libproc.h` | Enumerate all PIDs |
| `proc_pidinfo(PROC_PIDTASKINFO)` | `sys/proc_info.h` | Per-process RSS, virt, threads, CPU ns |
| `proc_name` | `libproc.h` | Process name from PID |
| `sysctl(HW_MEMSIZE)` | `sys/sysctl.h` | Total installed RAM |
| `os_signpost` | `os/signpost.h` | Instruments-visible trace intervals |
| `DispatchSource.makeTimerSource` | Foundation | Low-jitter background timer |

No elevated privileges required. `proc_pidinfo` is accessible for all user-space processes owned by the current user; system processes return partial data gracefully.

## What This Is Not

This is a learning and portfolio project. For production monitoring, use [Instruments](https://developer.apple.com/instruments/), `top`, `vm_stat`, or `powermetrics`. The goal here was to understand the underlying APIs those tools are built on.

## License

MIT
