import Foundation
import CSampler

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

struct Args {
    var interval: TimeInterval = 1.0
    var topN: Int              = 10
    var iterations: Int        = 0   // 0 = run until Ctrl-C
    var jsonOutput: Bool       = false

    static func parse() -> Args {
        var a = Args()
        var i = 1
        let argv = CommandLine.arguments
        while i < argv.count {
            switch argv[i] {
            case "-i", "--interval":
                i += 1
                if i < argv.count, let v = Double(argv[i]) { a.interval = max(0.1, v) }
            case "-n", "--top":
                i += 1
                if i < argv.count, let v = Int(argv[i])    { a.topN = max(1, min(32, v)) }
            case "-c", "--count":
                i += 1
                if i < argv.count, let v = Int(argv[i])    { a.iterations = max(0, v) }
            case "--json":
                a.jsonOutput = true
            case "-h", "--help":
                printHelp(); exit(0)
            default:
                fputs("Unknown option: \(argv[i])\n", stderr)
                printHelp(); exit(1)
            }
            i += 1
        }
        return a
    }

    static func printHelp() {
        print("""
        MacPerfProfiler — macOS system performance sampler

        Usage: MacPerfProfiler [options]

        Options:
          -i, --interval <sec>   Sampling interval in seconds (default: 1.0)
          -n, --top <n>          Number of top processes to display (default: 10, max: 32)
          -c, --count <n>        Exit after n samples (default: run forever)
              --json             Emit JSON lines instead of formatted output
          -h, --help             Show this help

        Notes:
          • Sampling uses proc_pidinfo(2) and host_statistics(3) — no elevated privileges needed.
          • os_signpost intervals are emitted under subsystem com.vadrevu.MacPerfProfiler;
            attach Instruments → Time Profiler to visualise sampling overhead live.
          • CPU% is a delta across consecutive samples; first sample always shows 0.0%.
        """)
    }
}

// ---------------------------------------------------------------------------
// JSON output
// ---------------------------------------------------------------------------

func toJSON(_ s: SystemSample) -> String {
    var procs: [[String: Any]] = []
    withUnsafeBytes(of: s.processes) { raw in
        let stride = MemoryLayout<ProcessSample>.stride
        for i in 0..<Int(s.processCount) {
            let p = raw.load(fromByteOffset: i * stride, as: ProcessSample.self)
            let name = withUnsafeBytes(of: p.name) { nb -> String in
                String(bytes: nb.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
            }
            procs.append([
                "pid": p.pid, "name": name,
                "cpuPercent": p.cpuPercent,
                "residentBytes": p.residentBytes,
                "virtualBytes": p.virtualBytes,
                "threadCount": p.threadCount
            ])
        }
    }
    let obj: [String: Any] = [
        "timestamp": ISO8601DateFormatter().string(from: Date()),
        "systemCpuPercent": s.systemCpuPercent,
        "memory": [
            "totalBytes": s.totalMemoryBytes,
            "freeBytes": s.freeMemoryBytes,
            "activeBytes": s.activeMemoryBytes,
            "wiredBytes": s.wiredMemoryBytes,
            "compressedBytes": s.compressedMemoryBytes
        ],
        "processes": procs
    ]
    let data = try? JSONSerialization.data(withJSONObject: obj)
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

let args = Args.parse()

// Clear screen header
if !args.jsonOutput {
    print("MacPerfProfiler  |  interval: \(args.interval)s  |  top \(args.topN) processes")
    print("Ctrl-C to quit   |  attach Instruments to PID \(ProcessInfo.processInfo.processIdentifier) to trace\n")
}

var tick = 0
let monitor = Monitor(interval: args.interval, topProcesses: args.topN)

monitor.onSample = { snapshot in
    tick += 1
    if args.jsonOutput {
        print(toJSON(snapshot))
    } else {
        // Move cursor up to overwrite previous output after first sample
        if tick > 1 {
            // 14 lines: header(3) + cpu(1) + mem(2) + blank(1) + tableHeader(2) + up-to-topN processes
            let moveUp = 7 + args.topN
            print(String(repeating: "\u{1B}[1A\u{1B}[2K", count: moveUp), terminator: "")
        }
        print(Formatter.render(snapshot, tick: tick))
    }
    if args.iterations > 0 && tick >= args.iterations {
        monitor.stop()
        exit(0)
    }
}

monitor.start()

// Keep the main thread alive
RunLoop.main.run()
