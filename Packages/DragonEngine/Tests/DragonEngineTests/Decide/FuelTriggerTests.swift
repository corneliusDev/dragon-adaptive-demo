//  FuelTriggerTests.swift
//  Chunk 9: on the plan's fuel schedule a critical cue; it comes back once
//  after 2 min unless a glance acknowledges it.

import XCTest
import DragonEngine

final class FuelTriggerTests: XCTestCase {
    private let plan = RunPlan(distanceMeters: 21_097.5, targetTime: 6_300, fuelEvery: 2_700)

    private func run(_ trigger: inout FuelTrigger, from: Int, to: Int,
                     glanceAt: TimeInterval? = nil) -> [(t: TimeInterval, cue: Cue)] {
        (from..<to).flatMap { i -> [(t: TimeInterval, cue: Cue)] in
            let t = TimeInterval(i)
            if t == glanceAt { trigger.note(AttentionSample(t: t, event: .glance)) }
            return trigger.evaluate(state: RunState(elapsed: t, distance: t * 3.35), at: t).map { (t, $0) }
        }
    }

    func testFuelOnScheduleThenOnceMoreTwoMinutesLater() {
        var trigger = FuelTrigger(plan: plan)
        let cues = run(&trigger, from: 0, to: 3_600)
        XCTAssertEqual(cues.map(\.t), [2_700, 2_820])
        XCTAssertEqual(cues.map(\.cue.key), [.fuel(1), .fuel(1)])
        guard let first = cues.first?.cue else { return }
        XCTAssertEqual(first.priority, .critical)
        XCTAssertEqual(first.minShow, 6)
        XCTAssertEqual(CueFormat.string(first.content.main), "GEL NOW")
        XCTAssertEqual(first.content.subtitle.map { CueFormat.string($0) }, ["FUEL 1 OF 2"])
        XCTAssertEqual(first.content.tag, "FUEL")
        XCTAssertEqual(first.content.icon, .drop)
        // Only once more, then the next stop.
        let rest = run(&trigger, from: 3_600, to: 6_000)
        XCTAssertEqual(rest.map(\.t), [5_400, 5_520])
        XCTAssertEqual(rest.first?.cue.content.subtitle.map { CueFormat.string($0) }, ["FUEL 2 OF 2"])
    }

    func testAGlanceAfterTheCueAcknowledgesIt() {
        var trigger = FuelTrigger(plan: plan)
        let cues = run(&trigger, from: 0, to: 3_600, glanceAt: 2_703)
        XCTAssertEqual(cues.map(\.t), [2_700])
        // A glance before the cue is not an acknowledgement.
        var early = FuelTrigger(plan: plan)
        XCTAssertEqual(run(&early, from: 0, to: 3_600, glanceAt: 2_600).map(\.t), [2_700, 2_820])
    }

    func testNoScheduleNoFuel() {
        var trigger = FuelTrigger(plan: RunPlan(distanceMeters: 21_097.5, targetTime: 6_300))
        XCTAssertTrue(run(&trigger, from: 0, to: 7_000).isEmpty)
        XCTAssertEqual(trigger.stops, 0)
    }

    // MARK: The walkthrough

    func testWalkthroughFuelAtFortyFiveMinutesAndAgainAtFortySevenWhenNotAcknowledged() {
        let race = cueRace(.designWalkthrough)
        XCTAssertEqual(race.plan.fuelEvery, 2_700)
        let shown = race.appearances(.fuel(1))
        XCTAssertEqual(shown.map(\.t), [2_700, 2_820])
        for row in shown {
            XCTAssertEqual(row.texts, ["GEL NOW", "FUEL 1 OF 2", "FUEL"], "t=\(row.t)")
        }
    }

    func testWalkthroughFuelIsNotRepeatedWhenAGlanceFollowsIt() {
        let glance = RunEvent.attention(AttentionSample(t: 2_702, event: .glance))
        let race = cueRace(.designWalkthrough, extra: [glance])
        XCTAssertEqual(race.appearances(.fuel(1)).map(\.t), [2_700])
        XCTAssertEqual(race.proposals(.fuel(1)).count, 1)
        // The glance came while the gel cue held the screen: it isn't cut short for the status.
        XCTAssertEqual(race.rows.filter { $0.current?.key == .fuel(1) }.count, 6)
    }
}
