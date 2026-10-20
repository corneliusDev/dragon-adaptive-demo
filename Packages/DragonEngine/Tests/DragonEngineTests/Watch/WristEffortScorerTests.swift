//  WristEffortScorerTests.swift

import XCTest
import DragonEngine

final class WristEffortScorerTests: XCTestCase {
    private func feed(_ scorer: inout WristEffortScorer, seconds: Double, rate: Double = 50, g: (Double) -> Double) -> [WristEffortScorer.Score] {
        var out: [WristEffortScorer.Score] = []
        for i in 0..<Int(seconds * rate) {
            let t = Double(i) / rate
            if let s = scorer.add(t: t, x: g(t), y: 0, z: 0) { out.append(s) }
        }
        return out
    }

    func testOneScorePerSecondOnTheEffortScale() {
        var scorer = WristEffortScorer()
        let scores = feed(&scorer, seconds: 5.1) { _ in 1.025 }   // halfway between 0.05 and 2.0 g
        XCTAssertEqual(scores.map(\.t), [1, 2, 3, 4, 5])
        for s in scores { XCTAssertEqual(s.effort, 50, accuracy: 0.01) }
    }

    func testStillArmIsZeroAndSprintIsCapped() {
        var still = WristEffortScorer()
        XCTAssertEqual(feed(&still, seconds: 2.1) { _ in 0.01 }.map(\.effort), [0, 0])
        var sprint = WristEffortScorer()
        XCTAssertEqual(feed(&sprint, seconds: 2.1) { _ in 3.5 }.map(\.effort), [100, 100])
    }

    func testRMSNotMean() {
        // Alternating ±1 g averages zero but swings hard.
        var scorer = WristEffortScorer()
        let s = feed(&scorer, seconds: 1.1) { t in Int(t * 50) % 2 == 0 ? 1 : -1 }
        XCTAssertEqual(s.first?.effort ?? -1, WristEffortScorer.Config().effort(rms: 1), accuracy: 0.01)
    }

    func testSparseSecondIsNotScored() {
        var scorer = WristEffortScorer()
        XCTAssertTrue(feed(&scorer, seconds: 3.1, rate: 5) { _ in 1 }.isEmpty)
    }

    func testBandsLineUpWithMotionBand() {
        let c = WristEffortScorer.Config()
        XCTAssertEqual(MotionBand(motion: c.effort(rms: 0.06)), .stationary)
        XCTAssertEqual(MotionBand(motion: c.effort(rms: 2.5)), .hard)
    }
}
