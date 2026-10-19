//  KickClockAndFinishTests.swift
//  Chunk 9: the last 0.25 mi is the kick clock's alone (a safety cue counting
//  down to the target); across the line the result shows for 10 s and then
//  the display goes dark.

import XCTest
import DragonEngine

final class KickClockAndFinishTests: XCTestCase {
    private let mile = DistanceUnit.metersPerMile
    private let plan = RunPlan(distanceMeters: 21_097.5, targetTime: 6_300)

    // MARK: Kick clock

    func testKickClockComesOnAQuarterMileOutOnce() {
        var trigger = KickClockTrigger(plan: plan)
        let total = plan.distanceMeters
        var fired: [(d: Double, cue: Cue)] = []
        for d in stride(from: total - 1_000, through: total, by: 2.0) {
            let t = 6_000 + (d - total + 1_000) / 3.5
            fired += trigger.evaluate(state: RunState(elapsed: t, distance: d), at: t).map { (d, $0) }
        }
        XCTAssertEqual(fired.count, 1)
        guard let first = fired.first else { return }
        XCTAssertEqual(total - first.d, 0.25 * mile, accuracy: 2)
        XCTAssertEqual(first.cue.key, .kickClock)
        XCTAssertEqual(first.cue.priority, .safety)
        // Live: the time left to beat the target and the distance left, from where the runner is.
        let c = first.cue.content
        XCTAssertEqual(CueFormat.string(c.heading!), "TO BEAT 1:45:00")
        let now = CueFormat.Now(elapsed: 6_202, distance: total - 257)
        XCTAssertEqual(CueFormat.string(c.main, unit: .miles, now: now), "1:38")
        XCTAssertEqual(CueFormat.string(c.subtitle[0], unit: .miles, now: now), "LEFT 0.16 MI")
        XCTAssertEqual(CueFormat.string(c.main, unit: .miles, now: CueFormat.Now(elapsed: 6_400, distance: total)), "0:00")
    }

    func testNoKickClockBeforeTheLastQuarterMile() {
        var trigger = KickClockTrigger(plan: plan)
        let early = stride(from: 0.0, through: plan.distanceMeters - 0.25 * mile - 1, by: 5).flatMap {
            trigger.evaluate(state: RunState(elapsed: $0 / 3.35, distance: $0), at: $0 / 3.35)
        }
        XCTAssertTrue(early.isEmpty)
        XCTAssertFalse(trigger.fired)
    }

    func testInTheFinalQuarterMileOnlyTheKickClockAppearsAndTheFinishAfterTheLine() {
        for profile in SyntheticProfile.all {
            let race = cueRace(profile, afterFinish: 15)
            let kickFrom = race.plan.distanceMeters - 0.25 * mile
            let stretch = race.rows.filter { $0.trueDistance >= kickFrom }
            XCTAssertGreaterThan(stretch.count, 80, profile.name)
            let kick = race.appearances(.kickClock)
            XCTAssertEqual(kick.count, 1, profile.name)
            for row in stretch {
                guard let cue = row.current else { continue }
                let beyond = row.t > race.finishTime
                XCTAssertTrue(cue.key == .kickClock || (beyond && cue.key == .finish),
                              "\(profile.name): \(cue.key.name) \(Int(race.plan.distanceMeters - row.trueDistance)) m out")
            }
            // On screen from the quarter mile to the line.
            let before = stretch.filter { $0.t <= race.finishTime && $0.t > (kick.first?.t ?? 0) }
            XCTAssertTrue(before.allSatisfy { $0.current?.key == .kickClock }, profile.name)
            // The clock ticks: the frame changes every second (while there is time left to beat).
            let times = before.filter { $0.t < race.plan.targetTime - 1 }.compactMap { $0.texts.dropFirst().first }
            XCTAssertEqual(Set(times).count, times.count, "\(profile.name) countdown")
        }
    }

    // MARK: Finish

    func testFinishNoticedByPositionIsInterpolatedAndStandsAfterFiveSeconds() {
        var trigger = FinishTrigger(plan: plan)
        let total = plan.distanceMeters
        XCTAssertTrue(trigger.evaluate(state: RunState(elapsed: 6_268, distance: total - 2), at: 6_268).isEmpty)
        XCTAssertTrue(trigger.evaluate(state: RunState(elapsed: 6_269, distance: total + 2), at: 6_269).isEmpty)
        XCTAssertEqual(trigger.crossedAt ?? 0, 6_268.5, accuracy: 0.001)
        XCTAssertFalse(trigger.isFinished(at: 6_273))
        XCTAssertTrue(trigger.evaluate(state: RunState(elapsed: 6_273, distance: total), at: 6_273).isEmpty)
        let cues = trigger.evaluate(state: RunState(elapsed: 6_274, distance: total), at: 6_274)
        XCTAssertEqual(cues.count, 1)
        guard let cue = cues.first else { return }
        XCTAssertEqual(cue.key, .finish)
        XCTAssertEqual(cue.minShow, 10)
        XCTAssertEqual(CueFormat.string(cue.content.main), "1:44:29")
        XCTAssertEqual(cue.content.subtitle.map { CueFormat.string($0) }, ["TARGET MET -0:31"])
        XCTAssertEqual(cue.content.tag, "FINISH")
        XCTAssertEqual(cue.content.icon, .flag)
        XCTAssertTrue(trigger.evaluate(state: RunState(elapsed: 6_275, distance: total), at: 6_275).isEmpty, "once")
    }

    func testNoFinishShortOfTheLineAndTheCallersWordCountsAtOnce() {
        var trigger = FinishTrigger(plan: plan)
        for t in stride(from: 6_000.0, to: 6_300, by: 1) {
            XCTAssertTrue(trigger.evaluate(state: RunState(elapsed: t, distance: plan.distanceMeters - 3), at: t).isEmpty)
        }
        XCTAssertNil(trigger.crossedAt)
        trigger.crossed(at: 6_310)
        let cues = trigger.evaluate(state: RunState(elapsed: 6_311, distance: plan.distanceMeters - 3), at: 6_311)
        XCTAssertEqual(cues.map { CueFormat.string($0.content.subtitle[0]) }, ["TARGET MISSED +0:10"])
    }

    func testAfterTheLineTheResultShowsForTenSecondsThenTheDisplayGoesDark() {
        let race = cueRace(.onPlan, afterFinish: 30)
        guard let shown = race.appearances(.finish).first else { return XCTFail("no finish cue") }
        XCTAssertGreaterThan(shown.t, race.finishTime)
        XCTAssertLessThanOrEqual(shown.t - race.finishTime, 7)
        XCTAssertEqual(shown.situation, .finished)
        XCTAssertEqual(shown.budget.minPriority, .info)
        // The kick clock came down for it.
        XCTAssertTrue(shown.decisions.contains { $0.key == .kickClock && $0.reason == .withdrawn })
        let up = race.rows.filter { $0.current?.key == .finish }
        XCTAssertEqual(up.count, 10)
        let after = race.rows.filter { $0.t > (up.last?.t ?? .infinity) }
        XCTAssertGreaterThan(after.count, 5)
        for row in after {
            XCTAssertNil(row.current)
            // Dark: not even the status dot.
            XCTAssertEqual(row.frame.ops.filter { if case .clear = $0 { return false }; if case .luma = $0 { return false }; return true }.count,
                           0, "t=\(row.t)")
        }
    }
}
