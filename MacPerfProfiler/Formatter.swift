import Foundation
import CSampler

/// Formats a SystemSample into a terminal-friendly string.
/// Keeps all formatting logic isolated so main.swift stays clean.
struct Formatter {

    static func render(_ s: SystemSample, tick: Int) -> String {
        var lines: [String] = []

        // Header
        let ts = DateFormatter.localizedString(
            from: Date(), dateStyle: .none, timeStyle: .medium)
        lines.append("─────────────────────────────────────────────────── tick \(tick)  \(ts)")

        // CPU
        let cpuBar = bar(fraction: s.systemCpuPercent / 100.0, width: 30)
        lines.append(String(format: "  CPU   %s  %5.1f%%", cpuBar, s.systemCpuPercent))

        // Memory
        let usedBytes = s.totalMemoryBytes
            - s.freeMemoryBytes
            - s.compressedMemoryBytes
        let memFrac = s.totalMemoryBytes > 0
            ? Double(usedBytes) / Double(s.totalMemoryBytes)
            : 0.0
        let memBar = bar(fraction: memFrac, width: 30)
        lines.append(String(
            format: "  RAM   %s  %5.1f%%   (%@ used / %@ total)",
            memBar,
            memFrac * 100.0,
            humanBytes(usedBytes),
            humanBytes(s.totalMemoryBytes)
        ))

        lines.append(String(format: "         active %-8@  wired %-8@  compressed %-8@",
            humanBytes(s.activeMemoryBytes) as CVarArg,
            humanBytes(s.wiredMemoryBytes) as CVarArg,
            humanBytes(s.compressedMemoryBytes) as CVarArg))

        // Process table
        lines.append("")
        lines.append(String(format: "  %-6s  %-28s  %7s  %8s  %6s",
            "PID", "NAME", "CPU%", "RSS", "THR"))
        lines.append("  " + String(repeating: "─", count: 58))

        let mirror = Mirror(reflecting: s.processes)
        // Access the fixed-size tuple as a flat array via withUnsafeBytes
        withUnsafeBytes(of: s.processes) { raw in
            let stride = MemoryLayout<ProcessSample>.stride
            let count  = Int(s.processCount)
            for i in 0..<count {
                let proc = raw.load(fromByteOffset: i * stride, as: ProcessSample.self)
                let name = withUnsafeBytes(of: proc.name) { nb -> String in
                    String(bytes: nb.prefix(while: { $0 != 0 }), encoding: .utf8) ?? "?"
                }
                lines.append(String(format: "  %-6d  %-28@  %6.1f%%  %8@  %6d",
                    proc.pid,
                    String(name.prefix(28)) as CVarArg,
                    proc.cpuPercent,
                    humanBytes(proc.residentBytes) as CVarArg,
                    proc.threadCount))
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func bar(fraction: Double, width: Int) -> String {
        let filled = max(0, min(width, Int(fraction * Double(width))))
        return "[" + String(repeating: "█", count: filled)
                   + String(repeating: "░", count: width - filled) + "]"
    }

    private static func humanBytes(_ b: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var val = Double(b)
        var idx = 0
        while val >= 1024 && idx < units.count - 1 {
            val /= 1024; idx += 1
        }
        return idx == 0
            ? String(format: "%d %@", Int(val), units[idx])
            : String(format: "%.1f %@", val, units[idx])
    }
}
