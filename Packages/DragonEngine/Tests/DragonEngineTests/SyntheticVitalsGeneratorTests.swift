//  SyntheticVitalsGeneratorTests.swift

import XCTest
import DragonEngine

final class SyntheticVitalsGeneratorTests: XCTestCase {
    private let dt = 1.0 / 20.0

    private func run(_ source: inout SyntheticVitalsGenerator, seconds: Double) -> [(t: Double, sample: VitalsSample)] {
        var out: [(Double, VitalsSample)] = []
        for _ in 0..<Int(seconds / dt) {
            if let s = source.advance(by: dt) {
                out.append((source.elapsed, s))
            }
        }
        return out
    }

    func testSameSeedReplaysSameRun() {
        var sa = SyntheticVitalsGenerator(seed: 7)
        var sb = SyntheticVitalsGenerator(seed: 7)
        let a = run(&sa, seconds: 60)
        let b = run(&sb, seconds: 60)

        XCTAssertEqual(a.count, b.count)
        XCTAssertEqual(a.map(\.sample.heartRate), b.map(\.sample.heartRate))
        XCTAssertEqual(a.map(\.sample.motion), b.map(\.sample.motion))
    }

    func testResetRestartsTheRun() {
        var source = SyntheticVitalsGenerator(seed: 7)
        let first = run(&source, seconds: 30)
        source.reset()
        let second = run(&source, seconds: 30)

        XCTAssertEqual(first.map(\.sample.heartRate), second.map(\.sample.heartRate))
    }

    func testRatesRoughlyMatchAWatch() {
        var source = SyntheticVitalsGenerator(seed: 1)
        source.dropoutsEnabled = false
        let samples = run(&source, seconds: 120)

        let hrCount = samples.filter { $0.sample.heartRate != nil }.count
        let motionCount = samples.filter { $0.sample.motion != nil }.count

        XCTAssertEqual(Double(hrCount) / 120, 1, accuracy: 0.2)      // ~1 Hz
        XCTAssertEqual(Double(motionCount) / 120, 10, accuracy: 3)   // ~10 Hz
    }

    func testValuesStayInRange() {
        var source = SyntheticVitalsGenerator(seed: 3)
        let samples = run(&source, seconds: 300)

        for (_, s) in samples {
            if let m = s.motion { XCTAssert((0...100).contains(m)) }
            if let hr = s.heartRate { XCTAssert((80...200).contains(hr)) }
        }
    }

    func testHeartRateLagsBehindEffort() {
        // Effort swings within seconds; a lagging HR should swing far less
        // than the HR that effort would map to instantly.
        var source = SyntheticVitalsGenerator(seed: 5)
        source.dropoutsEnabled = false
        let samples = run(&source, seconds: 80).filter { $0.t > 40 }   // skip warm-up from resting

        let hrs = samples.compactMap(\.sample.heartRate)
        let targets = samples.map {
            source.restingHR + (source.maxHR - source.restingHR) * source.exertion(at: $0.t) / 100
        }

        let hrSwing = hrs.max()! - hrs.min()!
        let targetSwing = targets.max()! - targets.min()!

        XCTAssertLessThan(hrSwing, targetSwing * 0.5)
    }

    func testOutagesCreateGaps() {
        var source = SyntheticVitalsGenerator(seed: 11)
        let samples = run(&source, seconds: 600)
        let times = samples.map(\.t)
        let longestGap = zip(times, times.dropFirst()).map { $1 - $0 }.max() ?? 0

        XCTAssertGreaterThanOrEqual(longestGap, 2)
    }

    func testSamplesAreStampedWithRunTimeNotTheClock() {
        var source = SyntheticVitalsGenerator(seed: 7)
        for (t, s) in run(&source, seconds: 10) {
            XCTAssertEqual(s.timestamp, t)
        }
    }
}
