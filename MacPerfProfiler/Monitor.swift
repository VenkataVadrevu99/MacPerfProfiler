import Foundation
import os.signpost
import CSampler

// os_signpost log — visible in Instruments under "Points of Interest"
// Lets you measure exact sampling overhead in Instruments' Time Profiler
private let samplerLog = OSLog(
    subsystem: "com.vadrevu.MacPerfProfiler",
    category: "sampling"
)

/// Drives periodic sampling on a background dispatch queue.
/// Uses os_signpost intervals so each sample tick is measurable
/// in Instruments without additional instrumentation overhead.
final class Monitor {

    // MARK: - Public

    /// Called on the main queue with each new snapshot
    var onSample: ((SystemSample) -> Void)?

    init(interval: TimeInterval = 1.0, topProcesses: Int = 10) {
        self.interval     = interval
        self.topProcesses = topProcesses
        self.handle       = sampler_create()
    }

    deinit {
        stop()
        sampler_destroy(handle)
    }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(
            flags: [],
            queue: samplingQueue
        )
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Private

    private let handle: SamplerHandle
    private let interval: TimeInterval
    private let topProcesses: Int
    private var timer: DispatchSourceTimer?

    // Dedicated QoS .utility queue — won't contend with UI or user interaction
    private let samplingQueue = DispatchQueue(
        label: "com.vadrevu.MacPerfProfiler.sampler",
        qos: .utility
    )

    private func tick() {
        // os_signpost bracket — each sample appears as a named interval
        // in Instruments → Time Profiler → Points of Interest track.
        // This lets us verify sampling overhead stays < 0.5% CPU.
        let spid = OSSignpostID(log: samplerLog)
        os_signpost(.begin, log: samplerLog, name: "SampleTick", signpostID: spid)
        defer {
            os_signpost(.end, log: samplerLog, name: "SampleTick", signpostID: spid)
        }

        var snapshot = SystemSample()
        guard sampler_take(handle, &snapshot, Int32(topProcesses)) == 0 else { return }

        DispatchQueue.main.async { [weak self] in
            self?.onSample?(snapshot)
        }
    }
}
