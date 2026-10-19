//  PaceGapTriggerTests.swift
//  The trigger on hand-built states; whole races are in CueReplayTests.

import XCTest
import DragonEngine

final class PaceGapTriggerTests: XCTestCase {
    /// 10 km in 50:00: 0.3 s/m.
    private let plan = RunPlan(distanceMeters: 10_000, targetTime: 3_000)

    private func state(_ t: Double, gap: Double?, pace: Double?, distance: Double = 5_000) -> RunState {
        var q = DataQuality()
        q.paceUnknown = pace == nil
        return RunState(elapsed: t, distance: distance, pace30s: pace, pace60s: pace, gradeAdjustedPace: pace,
                        projectedFinish: gap.map { 3_000 + $0 }, gapToTarget: gap, quality: q)
    }

    private func run(_ trigger: inout PaceGapTrigger, from: Int, to: Int,
                     _ make: (Double) -> RunState) -> [(TimeInterval, Cue)] {
        (from..<to).flatMap { t in trigger.evaluate(state: make(Double(t)), at: Double(t)).map { (Double(t), $0) } }
    }

    func testFiresAfterTwentySecondsOfGapAndPaceOffThenClearsUnderEightSeconds() {
        var trigger = PaceGapTrigger(plan: plan)
        // 30 s behind, 5% slow: fires at 20 s, once.
        var fired = run(&trigger, from: 0, to: 100) { self.state($0, gap: 30, pace: 0.315) }
        XCTAssertEqual(fired.map(\.0), [20])
        XCTAssertEqual(trigger.active, .behind)

        let cue = fired[0].1
        XCTAssertEqual(cue.key, .paceGap)
        XCTAssertEqual(cue.priority, .critical)
        XCTAssertEqual(cue.minShow, 5)
        XCTAssertEqual(CueFormat.string(cue.content.heading!), "BEHIND PLAN")
        XCTAssertEqual(CueFormat.string(cue.content.main), "+0:30")
        // Finish 50:30; the plan's 50:00 less 20 s gone, over 5 km left: 0.596 s/m.
        XCTAssertEqual(cue.content.subtitle.map(CueFormat.string), ["FINISH 50:30", "NEED 15:59 / MI"])

        // Pace back on plan, gap 10 s: still on (only the gap clears it).
        fired = run(&trigger, from: 100, to: 200) { self.state($0, gap: 10, pace: 0.3) }
        XCTAssertTrue(fired.isEmpty)
        XCTAssertEqual(trigger.active, .behind)
        _ = run(&trigger, from: 200, to: 201) { self.state($0, gap: 7, pace: 0.3) }
        XCTAssertNil(trigger.active)
    }

    func testNeedsBothTheGapAndThePace() {
        var trigger = PaceGapTrigger(plan: plan)
        // Big gap, pace on plan (a slow start already paid for).
        XCTAssertTrue(run(&trigger, from: 0, to: 200) { self.state($0, gap: 40, pace: 0.302) }.isEmpty)
        // Pace well off, gap small.
        XCTAssertTrue(run(&trigger, from: 200, to: 400) { self.state($0, gap: 12, pace: 0.33) }.isEmpty)
        // Gap behind but pace fast: the runner is already fixing it.
        XCTAssertTrue(run(&trigger, from: 400, to: 600) { self.state($0, gap: 40, pace: 0.28) }.isEmpty)
        XCTAssertNil(trigger.active)
    }

    func testAheadOfTarget() {
        var trigger = PaceGapTrigger(plan: plan)
        let fired = run(&trigger, from: 0, to: 60) { self.state($0, gap: -25, pace: 0.285) }
        XCTAssertEqual(fired.map(\.0), [20])
        XCTAssertEqual(trigger.active, .ahead)
        XCTAssertEqual(CueFormat.string(fired[0].1.content.heading!), "AHEAD OF PLAN")
        XCTAssertEqual(CueFormat.string(fired[0].1.content.main), "-0:25")
        _ = run(&trigger, from: 60, to: 61) { self.state($0, gap: -5, pace: 0.3) }
        XCTAssertNil(trigger.active)
    }

    func testNeverFiresWhilePaceIsUnknown() {
        var trigger = PaceGapTrigger(plan: plan)
        XCTAssertTrue(run(&trigger, from: 0, to: 600) { self.state($0, gap: 60, pace: nil) }.isEmpty)
        // A pace that drops out every 15 s never holds long enough.
        let flicker = run(&trigger, from: 600, to: 1_200) { t in
            self.state(t, gap: 60, pace: Int(t) % 15 == 0 ? nil : 0.33)
        }
        XCTAssertTrue(flicker.isEmpty)
        // Flagged unknown with a stale number still present: still unknown.
        let flagged = run(&trigger, from: 1_200, to: 1_800) { t in
            var s = self.state(t, gap: 60, pace: 0.33)
            s.quality.paceUnknown = true
            return s
        }
        XCTAssertTrue(flagged.isEmpty)
        XCTAssertNil(trigger.active)
    }
}
