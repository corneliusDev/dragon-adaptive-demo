//  SyntheticVitalsSourceTests.swift

import XCTest
@testable import Dragon_Adaptive

final class SyntheticVitalsSourceTests: XCTestCase {
    private let dt = 1.0 / 20.0

    private func run(_ source: SyntheticVitalsSource, seconds: Double) -> [(t: Double, sample: VitalsSample)] {
        var out: [(Double, VitalsSample)] = []
        for _ in 0..<Int(seconds / dt) {
            if let s = source.advance(by: dt) {
                out.append((source.elapsed, s))
            }
        }
        return out
    }

    func testSameSeedReplaysSameRun() {
        let a = run(SyntheticVitalsSource(seed: 7), seconds: 60)
        let b = run(SyntheticVitalsSource(seed: 7), seconds: 60)

        XCTAssertEqual(a.count, b.count)
        XCTAssertEqual(a.map(\.sample.heartRate), b.map(\.sample.heartRate))
        XCTAssertEqual(a.map(\.sample.motion), b.map(\.sample.motion))
    }

    func testResetRestartsTheRun() {
        let source = SyntheticVitalsSource(seed: 7)
        let first = run(source, seconds: 30)
        source.reset()
        let second = run(source, seconds: 30)

        XCTAssertEqual(first.map(\.sample.heartRate), second.map(\.sample.heartRate))
    }

    func testRatesRoughlyMatchAWatch() {
        let source = SyntheticVitalsSource(seed: 1)
        source.dropoutsEnabled = false
        let samples = run(source, seconds: 120)

        let hrCount = samples.filter { $0.sample.heartRate != nil }.count
        let motionCount = samples.filter { $0.sample.motion != nil }.count

        XCTAssertEqual(Double(hrCount) / 120, 1, accuracy: 0.2)      // ~1 Hz
        XCTAssertEqual(Double(motionCount) / 120, 10, accuracy: 3)   // ~10 Hz
    }

    func testValuesStayInRange() {
        let samples = run(SyntheticVitalsSource(seed: 3), seconds: 300)

        for (_, s) in samples {
            if let m = s.motion { XCTAssert((0...100).contains(m)) }
            if let hr = s.heartRate { XCTAssert((80...200).contains(hr)) }
        }
    }

    func testHeartRateLagsBehindEffort() {
        // Effort swings within seconds; a lagging HR should swing far less
        // than the HR that effort would map to instantly.
        let source = SyntheticVitalsSource(seed: 5)
        source.dropoutsEnabled = false
        let samples = run(source, seconds: 80).filter { $0.t > 40 }   // skip warm-up from resting

        let hrs = samples.compactMap(\.sample.heartRate)
        let targets = samples.map {
            source.restingHR + (source.maxHR - source.restingHR) * source.exertion(at: $0.t) / 100
        }

        let hrSwing = hrs.max()! - hrs.min()!
        let targetSwing = targets.max()! - targets.min()!

        XCTAssertLessThan(hrSwing, targetSwing * 0.5)
    }

    func testOutagesCreateGaps() {
        let samples = run(SyntheticVitalsSource(seed: 11), seconds: 600)
        let times = samples.map(\.t)
        let longestGap = zip(times, times.dropFirst()).map { $1 - $0 }.max() ?? 0

        XCTAssertGreaterThanOrEqual(longestGap, 2)
    }
}
