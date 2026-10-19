//  HeartCeilingTriggerTests.swift
//  Chunk 9: zone 5, or zone 4 before 80% of the distance, held 30 s → a
//  critical heart-rate cue; back below for 20 s clears it; missing heart
//  rate never fires it. Hand-built states, then whole races.

import XCTest
import DragonEngine

final class HeartCeilingTriggerTests: XCTestCase {
    /// Zones by heart rate reserve, rest 52 / max 188: zone 4 from 160.8, zone 5 from 174.4.
    private let plan = RunPlan(distanceMeters: 10_000, targetTime: 3_000,
                               heartRateZones: .reserve(resting: 52, threshold: 172, max: 188))

    private func state(_ t: TimeInterval, hr: Double?, distance: Double = 2_000,
                       phase: MovementPhase = .steady) -> RunState {
        RunState(elapsed: t, distance: distance, heartRate: hr, phase: phase)
    }

    /// Feeds one state a second over [from, to) and returns the cues with their run times.
    private func run(_ trigger: inout HeartCeilingTrigger, from: Int, to: Int,
                     _ make: (TimeInterval) -> RunState) -> [(t: TimeInterval, cue: Cue)] {
        (from..<to).flatMap { i -> [(t: TimeInterval, cue: Cue)] in
            let t = TimeInterval(i)
            return trigger.evaluate(state: make(t), at: t).map { (t, $0) }
        }
    }

    func testZoneFiveHeldThirtySecondsFiresACriticalCue() {
        var trigger = HeartCeilingTrigger(plan: plan)
        XCTAssertTrue(run(&trigger, from: 0, to: 60) { self.state($0, hr: 150) }.isEmpty)
        let cues = run(&trigger, from: 60, to: 120) { self.state($0, hr: 178) }
        XCTAssertEqual(cues.count, 1)
        guard let fired = cues.first else { return }
        // Smoothing over 10 s, then 30 s over the line.
        XCTAssertEqual(fired.t, 60 + 30 + 5, accuracy: 6)
        XCTAssertEqual(fired.cue.key, .heartCeiling)
        XCTAssertEqual(fired.cue.priority, .critical)
        XCTAssertEqual(fired.cue.needs, [.heartRate])
        XCTAssertEqual(CueFormat.string(fired.cue.content.main), "HR 178 Z5")
        XCTAssertEqual(fired.cue.content.subtitle.map { CueFormat.string($0) }, ["EASE 5 SEC/MI"])
        XCTAssertEqual(fired.cue.content.tag, "HEART")
        XCTAssertEqual(fired.cue.minShow, 5)
        XCTAssertTrue(trigger.isOn)
    }

    func testZoneFourCountsBeforeEightyPercentOnly() {
        var early = HeartCeilingTrigger(plan: plan)
        XCTAssertEqual(run(&early, from: 0, to: 60) { self.state($0, hr: 167, distance: 7_000) }.count, 1)
        var late = HeartCeilingTrigger(plan: plan)
        XCTAssertTrue(run(&late, from: 0, to: 120) { self.state($0, hr: 167, distance: 8_100) }.isEmpty)
        XCTAssertEqual(run(&late, from: 120, to: 200) { self.state($0, hr: 180, distance: 8_200) }.count, 1)
    }

    func testZoneFourOnAClimbAndJustAfterItIsExpected() {
        var trigger = HeartCeilingTrigger(plan: plan)
        XCTAssertTrue(run(&trigger, from: 0, to: 120) { self.state($0, hr: 167, phase: .climbing) }.isEmpty)
        // Heart rate lags the grade: still zone 4 for the minute after the top.
        XCTAssertTrue(run(&trigger, from: 120, to: 175) { self.state($0, hr: 167) }.isEmpty)
        // Past the grace, zone 4 at 20% of the distance is too much.
        XCTAssertEqual(run(&trigger, from: 175, to: 240) { self.state($0, hr: 167) }.count, 1)
        // Zone 5 always counts, climb or not.
        var climbing = HeartCeilingTrigger(plan: plan)
        XCTAssertEqual(run(&climbing, from: 0, to: 60) { self.state($0, hr: 180, phase: .climbing) }.count, 1)
    }

    func testNeverFiresOnMissingHeartRate() {
        var trigger = HeartCeilingTrigger(plan: plan)
        // Readings drop out every 20 s: zone 5 never stands for 30 s of known heart rate.
        let cues = run(&trigger, from: 0, to: 600) { t in self.state(t, hr: Int(t) % 20 == 19 ? nil : 182) }
        XCTAssertTrue(cues.isEmpty)
        XCTAssertFalse(trigger.isOn)
        // No heart rate at all.
        var none = HeartCeilingTrigger(plan: plan)
        XCTAssertTrue(run(&none, from: 0, to: 600) { self.state($0, hr: nil) }.isEmpty)
        // No zones in the plan.
        var noZones = HeartCeilingTrigger(plan: RunPlan(distanceMeters: 10_000, targetTime: 3_000))
        XCTAssertTrue(run(&noZones, from: 0, to: 600) { self.state($0, hr: 190) }.isEmpty)
    }

    func testClearsAfterTwentySecondsBelowAndCanFireAgain() {
        var trigger = HeartCeilingTrigger(plan: plan)
        XCTAssertEqual(run(&trigger, from: 0, to: 60) { self.state($0, hr: 180) }.count, 1)
        // Zone 5 easing to zone 4 before 80%: still over the ceiling, not cleared, no repeat.
        XCTAssertTrue(run(&trigger, from: 60, to: 200) { self.state($0, hr: 168) }.isEmpty)
        XCTAssertTrue(trigger.isOn)
        // Back in zone 3 (the smoothed reading is under zone 4 from 204 s): cleared 20 s later.
        _ = run(&trigger, from: 200, to: 222) { self.state($0, hr: 150) }
        XCTAssertTrue(trigger.isOn, "not before 20 s below")
        _ = run(&trigger, from: 222, to: 240) { self.state($0, hr: 150) }
        XCTAssertFalse(trigger.isOn)
        // A new time over is a new cue.
        XCTAssertEqual(run(&trigger, from: 240, to: 300) { self.state($0, hr: 180) }.count, 1)
    }

    func testABlipOverTheCeilingDoesNotFire() {
        var trigger = HeartCeilingTrigger(plan: plan)
        let cues = run(&trigger, from: 0, to: 600) { t in self.state(t, hr: Int(t) % 60 < 20 ? 180 : 150) }
        XCTAssertTrue(cues.isEmpty)
    }

    // MARK: Whole races

    func testTooHotGivesAHeartRateCueInTheFirstThird() {
        let race = cueRace(.tooHot)
        let third = race.plan.distanceMeters / 3
        let proposed = race.proposals(.heartCeiling)
        guard let first = proposed.first else { return XCTFail("no heart-rate cue in the hot race") }
        XCTAssertLessThan(first.row.trueDistance, third)
        XCTAssertGreaterThanOrEqual(first.row.state.heartZone ?? 0, 4)
        // It made it to the screen, in the first third.
        guard let shown = race.appearances(.heartCeiling).first else { return XCTFail("never shown") }
        XCTAssertLessThan(shown.trueDistance, third)
        XCTAssertTrue(shown.texts.contains { $0.hasPrefix("HR ") && $0.hasSuffix("Z4") }, "\(shown.texts)")
        // One episode: the heat doesn't let up, and it isn't repeated.
        XCTAssertEqual(proposed.count, 1)
    }

    func testOnPlanAndHillyRacesGetNoHeartRateCue() {
        // On plan: zone 3 all race. Hilly: zone 4 on the climbs is expected.
        for profile in [SyntheticProfile.onPlan, .hilly] {
            XCTAssertTrue(cueRace(profile).proposals(.heartCeiling).isEmpty, profile.name)
        }
    }
}
