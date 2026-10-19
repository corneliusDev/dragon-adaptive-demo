//  TerrainAheadTriggerTests.swift
//  Chunk 9: a hill or sharp turn 150–250 m ahead → an advisory cue, once,
//  gone by the time the runner reaches it; on the hilly race, a notice
//  before every climb, quiet on the climbs, and the held split at the top.

import XCTest
import DragonEngine

final class TerrainAheadTriggerTests: XCTestCase {
    /// 5 km, one 400 m climb from 2 km.
    private let plan: RunPlan = {
        let course = Course.synthetic(length: 5_000, hills: [SyntheticHill(start: 2_000, length: 400, gain: 24)],
                                      curving: 0)
        return RunPlan(distanceMeters: 5_000, targetTime: 1_500, course: course)
    }()

    private func cues(_ trigger: inout TerrainAheadTrigger, from: Double, to: Double, step: Double = 3) -> [(d: Double, cue: Cue)] {
        stride(from: from, through: to, by: step).flatMap { d -> [(d: Double, cue: Cue)] in
            trigger.evaluate(state: RunState(elapsed: d * 0.3, distance: d), at: d * 0.3).map { (d, $0) }
        }
    }

    func testAHillTwoHundredMetresAheadIsAnnouncedOnce() {
        var trigger = TerrainAheadTrigger(plan: plan)
        guard let hill = trigger.features.first, case .hill = hill else { return XCTFail("no hill found") }
        let start = hill.distance
        let all = cues(&trigger, from: 0, to: 5_000)
        XCTAssertEqual(all.count, 1)
        guard let fired = all.first else { return }
        XCTAssertGreaterThanOrEqual(start - fired.d, 150)
        XCTAssertLessThanOrEqual(start - fired.d, 250)
        XCTAssertEqual(fired.cue.key, .terrain(at: Int(start.rounded())))
        XCTAssertEqual(fired.cue.priority, .advisory)
        XCTAssertEqual(fired.cue.minShow, 4)
        XCTAssertEqual(fired.cue.needs, [.gps])
        // "HILL 0.15 MI", counting down with the runner.
        let here = CueFormat.Now(elapsed: 0, distance: fired.d)
        XCTAssertEqual(CueFormat.string(fired.cue.content.main, unit: .miles, now: here),
                       CueFormat.string(.phrase([.label("HILL"), .distance(start - fired.d)])))
        XCTAssertEqual(CueFormat.string(fired.cue.content.main, unit: .miles,
                                        now: CueFormat.Now(elapsed: 0, distance: start - 50)), "HILL 0.03 MI")
        XCTAssertEqual(fired.cue.content.subtitle.map { CueFormat.string($0) }, ["HOLD EFFORT"])
        XCTAssertEqual(fired.cue.content.tag, "TERRAIN")
        XCTAssertEqual(fired.cue.content.icon, .hill)
        // It clears on reaching the hill: it expires about when the plan's pace gets there.
        XCTAssertEqual(fired.cue.expiresAt, fired.cue.createdAt + (start - fired.d) * plan.targetPace(at: fired.d),
                       accuracy: 0.01)
    }

    func testNothingOutsideTheWindowAndNothingOnAFlatCourse() {
        var trigger = TerrainAheadTrigger(plan: plan)
        let start = trigger.features[0].distance
        // Never inside 150–250 m: from more than 250 m out straight onto the climb.
        XCTAssertTrue(cues(&trigger, from: 0, to: start - 251, step: 1).isEmpty)
        XCTAssertTrue(cues(&trigger, from: start - 149, to: 5_000).isEmpty)
        var flat = TerrainAheadTrigger(plan: RunPlan(distanceMeters: 5_000, targetTime: 1_500,
                                                      course: .synthetic(length: 5_000, curving: 0)))
        XCTAssertTrue(flat.features.isEmpty)
        XCTAssertTrue(cues(&flat, from: 0, to: 5_000).isEmpty)
    }

    func testASharpTurnIsAnnouncedWithItsDirection() {
        // Due east 1 km, then a right angle south.
        let start = Course.syntheticStart
        let east = (0...100).map { i in TrackPoint(latitude: start.latitude,
                                                   longitude: start.longitude + Double(i) * 10 / 88_000) }
        let corner = east.last!
        let south = (1...100).map { i in TrackPoint(latitude: corner.latitude - Double(i) * 10 / 111_000,
                                                    longitude: corner.longitude) }
        let course = Course(track: east + south)
        var trigger = TerrainAheadTrigger(plan: RunPlan(distanceMeters: course.totalDistance, targetTime: 600,
                                                        course: course))
        guard case .turn(let turn)? = trigger.features.first else { return XCTFail("no turn found") }
        XCTAssertGreaterThan(turn.angle, 60)
        let fired = cues(&trigger, from: 0, to: course.totalDistance)
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired.first?.cue.content.subtitle.map { CueFormat.string($0) }, ["SHARP RIGHT"])
        XCTAssertEqual(fired.first?.cue.content.icon, .arrow)
    }

    // MARK: The hilly race

    func testHillyGivesATerrainCueBeforeEveryHill() {
        let race = cueRace(.hilly)
        let hills = race.plan.course!.hills()
        XCTAssertEqual(hills.count, 4)
        for hill in hills {
            let key = CueKey.terrain(at: Int(hill.startDistance.rounded()))
            guard let shown = race.appearances(key).first else { XCTFail("no notice before \(key.name)"); continue }
            let ahead = hill.startDistance - shown.state.distance
            XCTAssertGreaterThanOrEqual(ahead, 120, key.name)
            XCTAssertLessThanOrEqual(ahead, 250, key.name)
            XCTAssertTrue(shown.texts.first?.hasPrefix("HILL 0.") ?? false, "\(shown.texts)")
            XCTAssertEqual(Array(shown.texts.dropFirst()), ["HOLD EFFORT", "TERRAIN"])
            // Before, never during: off the screen by the time the climb starts.
            XCTAssertFalse(race.rows.contains { $0.current?.key == key && $0.state.distance >= hill.startDistance })
        }
    }

    func testHillyShowsNothingOnAClimbButWhatTheBudgetAllowsAndTheHeldSplitAtTheTop() {
        let race = cueRace(.hilly)
        let hills = race.plan.course!.hills()
        for hill in hills {
            let climbing = race.rows.filter { $0.state.distance > hill.startDistance && $0.state.distance < hill.endDistance }
            XCTAssertGreaterThan(climbing.count, 60)
            for row in climbing {
                // Only what the climb's budget lets through (critical and up), and nothing that
                // went up before the climb lingering on it but a split held to the top.
                if let cue = row.current {
                    XCTAssertTrue(row.budget.admits(cue), "\(cue.key.name) at \(Int(row.state.distance)) m")
                    XCTAssertGreaterThanOrEqual(cue.priority, .critical, "\(cue.key.name) on the climb")
                }
            }
        }
        // Miles 4, 7 and 10 fall on climbs: each shown within 20 s of reaching the crest.
        var held = 0
        for p in race.splitProposals {
            guard case .split(let marker, let unit) = p.cue.key else { continue }
            let at = Double(marker) * unit.meters
            guard let hill = hills.first(where: { at >= $0.startDistance && at < $0.endDistance }) else { continue }
            held += 1
            guard let crest = race.rows.first(where: { $0.state.distance >= hill.endDistance }),
                  let shown = race.appearances(p.cue.key).first else { XCTFail("\(p.cue.key.name) never shown"); continue }
            XCTAssertGreaterThanOrEqual(shown.t, crest.t, p.cue.key.name)
            XCTAssertLessThanOrEqual(shown.t - crest.t, 20, p.cue.key.name)
            XCTAssertEqual(shown.texts.first, "MILE \(marker)")
        }
        XCTAssertEqual(held, 3)
    }
}
