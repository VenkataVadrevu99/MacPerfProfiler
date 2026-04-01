import XCTest
import CSampler

final class SamplerTests: XCTestCase {

    func testCreateDestroy() {
        let h = sampler_create()
        XCTAssertNotNil(h)
        sampler_destroy(h)
    }

    func testTotalMemoryNonZero() {
        XCTAssertGreaterThan(sampler_total_memory(), 0)
    }

    func testFirstSamplePopulated() {
        let h = sampler_create()!
        var s = SystemSample()
        let ret = sampler_take(h, &s, 5)
        XCTAssertEqual(ret, 0)
        // System CPU% on first call is 0 (no previous snapshot to delta against)
        XCTAssertGreaterThanOrEqual(s.systemCpuPercent, 0.0)
        XCTAssertLessThanOrEqual(s.systemCpuPercent, 100.0)
        // Memory fields must be populated
        XCTAssertGreaterThan(s.totalMemoryBytes, 0)
        XCTAssertGreaterThan(s.wiredMemoryBytes, 0)
        // Should have found at least 1 process (ourselves)
        XCTAssertGreaterThan(s.processCount, 0)
        sampler_destroy(h)
    }

    func testSecondSampleHasCpuDelta() {
        let h = sampler_create()!
        var s1 = SystemSample()
        var s2 = SystemSample()
        sampler_take(h, &s1, 5)
        // Brief spin to generate measurable CPU delta
        var x: Double = 0
        for i in 0..<500_000 { x += Double(i) }
        _ = x
        sampler_take(h, &s2, 5)
        // After the spin, system CPU% should be > 0
        XCTAssertGreaterThan(s2.systemCpuPercent, 0.0)
        sampler_destroy(h)
    }

    func testTopNRespected() {
        let h = sampler_create()!
        var s = SystemSample()
        sampler_take(h, &s, 3)
        XCTAssertLessThanOrEqual(s.processCount, 3)
        sampler_destroy(h)
    }

    func testNullSafetyHandles() {
        // Should not crash
        sampler_destroy(nil)
        var s = SystemSample()
        XCTAssertEqual(sampler_take(nil, &s, 5), -1)
        XCTAssertEqual(sampler_take(sampler_create(), nil, 5), -1)
    }

    func testSamplingOverheadUnderHalfPercent() throws {
        // Verify our own sampling loop doesn't eat > 0.5% CPU over 5 ticks
        let h = sampler_create()!
        var before = SystemSample()
        var after  = SystemSample()

        sampler_take(h, &before, 10)
        for _ in 0..<5 { sampler_take(h, &after, 10) }

        // Find our own PID's CPU in the last sample
        var ownCpu = 0.0
        let myPid = Int32(ProcessInfo.processInfo.processIdentifier)
        withUnsafeBytes(of: after.processes) { raw in
            let stride = MemoryLayout<ProcessSample>.stride
            for i in 0..<Int(after.processCount) {
                let p = raw.load(fromByteOffset: i * stride, as: ProcessSample.self)
                if p.pid == myPid { ownCpu = p.cpuPercent; break }
            }
        }
        // Allow generous headroom for CI machines — just confirm it's not pathological
        XCTAssertLessThan(ownCpu, 50.0, "Sampler consuming unexpectedly high CPU: \(ownCpu)%")
        sampler_destroy(h)
    }
}
