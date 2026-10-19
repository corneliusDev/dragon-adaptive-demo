//  CueReplayTests.swift
//  Chunk 4 acceptance: whole synthetic races (seed 42) through RunEngine —
//  estimator → split and pace-gap triggers → choice — checking which cues
//  were proposed and when.

import XCTest
import DragonEngine

final class CueReplayTests: XCTestCase {
    private let mile = DistanceUnit.metersPerMile

    func testOnPlanHalfMarathonGivesThirteenSplitsAndNoPaceGap() {
        let race = cueRace(.onPlan)
        let splits = race.splitProposals
        XCTAssertEqual(splits.map(\.cue.key), (1...13).map { .split(mile: $0) })
        XCTAssertTrue(race.proposals(.paceGap).isEmpty)
        XCTAssertTrue(race.rows.allSatisfy { $0.paceGap == nil })

        // Each split is proposed within a few seconds of really crossing the marker,
        // and its time is the runner's (8:01 plan, ±normal wobble and GPS).
        for (i, p) in splits.enumerated() {
            let marker = Double(i + 1) * mile
            guard let crossed = race.rows.first(where: { $0.trueDistance >= marker }) else { return XCTFail() }
            XCTAssertEqual(p.row.t, crossed.t, accuracy: 15, "mile \(i + 1)")
            XCTAssertEqual(race.splits[i].time, 481, accuracy: 10, "mile \(i + 1)")
        }
        // Splits 1–12 made it to the screen, for their 3 s each.
        for i in 1...12 {
            let shown = race.rows.filter { $0.current?.key == .split(mile: i) }
            XCTAssertEqual(shown.count, 3, "mile \(i)")
        }
        // Mile 13 falls 176 m from the finish, in the final 400 m: proposed, but
        // dropped there and never shown (the kick clock, chunk 9, owns the stretch).
        let mile13 = CueKey.split(mile: 13)
        XCTAssertLessThanOrEqual(race.plan.distanceMeters - splits[12].row.state.distance, 400)
        XCTAssertFalse(race.rows.contains { $0.current?.key == mile13 })
        let left = race.rows.flatMap(\.decisions).filter { $0.key == mile13 && $0.outcome == .expired }
        XCTAssertEqual(left.map(\.reason), [.finalStretch])
        XCTAssertEqual(left.first?.text, "final 400 m: only safety until the finish")
    }

    func testSlowFadeFromMileNineFiresThePaceGapCueAfterMileNineAndNotBefore() {
        let from = 9 * mile
        let race = cueRace(.slowFade(from: from))
        let gaps = race.proposals(.paceGap)
        XCTAssertEqual(gaps.count, 1)
        guard let fired = gaps.first else { return }
        XCTAssertGreaterThan(fired.row.trueDistance, from)
        XCTAssertGreaterThan(fired.row.state.distance, from)
        // Design: "a behind-plan cue around mile 10".
        XCTAssertLessThan(fired.row.trueDistance, 10.5 * mile)
        XCTAssertNil(race.rows.first { $0.trueDistance < from && $0.paceGap != nil })
        XCTAssertEqual(CueFormat.string(fired.cue.content.heading!), "BEHIND PLAN")
        XCTAssertEqual(fired.cue.content.subtitle.count, 2)
        // It made it to the screen.
        XCTAssertTrue(race.rows.contains { $0.current?.key == .paceGap })
        // The fade never recovers: still on at the finish.
        XCTAssertEqual(race.rows.last?.paceGap, .behind)
        // Splits keep coming.
        XCTAssertEqual(race.splitProposals.count, 13)
    }

    func testPaceGapCueClearsOnceTheRunnerRecovers() {
        let from = 9 * mile, recoverAt = 10 * mile
        let race = cueRace(.slowFadeRecovery(from: from, recoverAt: recoverAt))
        let gaps = race.proposals(.paceGap)
        XCTAssertEqual(gaps.count, 1)
        guard let fired = gaps.first else { return }
        XCTAssertGreaterThan(fired.row.trueDistance, from)
        XCTAssertLessThan(fired.row.trueDistance, recoverAt + 0.25 * mile)

        // Clears after the recovery starts, and stays clear to the finish.
        guard let cleared = race.rows.first(where: { $0.t > fired.row.t && $0.paceGap == nil }) else {
            return XCTFail("pace gap never cleared")
        }
        XCTAssertGreaterThan(cleared.trueDistance, recoverAt)
        XCTAssertLessThan(cleared.state.gapToTarget ?? .infinity, 8)
        XCTAssertTrue(race.rows.filter { $0.t >= cleared.t }.allSatisfy { $0.paceGap == nil })
    }

    func testGPSDropoutGivesNoPaceGapCueWhilePaceIsUnknown() {
        let race = cueRace(.gpsDropout(at: 5_000, for: 60))
        let unknown = race.rows.filter { $0.state.quality.paceUnknown }
        XCTAssertGreaterThan(unknown.count, 50, "the dropout should leave pace unknown for most of a minute")
        for row in unknown {
            XCTAssertFalse(row.proposed.contains { $0.key == .paceGap }, "t=\(row.t)")
        }
        XCTAssertTrue(race.proposals(.paceGap).isEmpty)
        // Distance is dead-reckoned through it, so splits still come once each.
        XCTAssertEqual(race.splitProposals.map(\.cue.key), (1...13).map { .split(mile: $0) })
    }

    func testRunEngineFrameShowsTheChosenCue() {
        var run = SyntheticRun(profile: .onPlan)
        var engine = RunEngine(plan: run.plan)
        var sawSplit = false
        while run.time < 600 {
            for event in run.advance(by: 0.5) { engine.ingest(event) }
            let step = engine.update(at: run.time)
            let texts = engine.frame().ops.compactMap { op -> String? in
                if case .text(_, _, _, _, _, let s) = op { return s } else { return nil }
            }
            if step.current?.key == .split(mile: 1) {
                sawSplit = true
                XCTAssertEqual(texts.first, "MILE 1")
                XCTAssertTrue(texts.contains("SPLIT"))
            } else if step.current == nil {
                XCTAssertTrue(texts.isEmpty)
            }
        }
        XCTAssertTrue(sawSplit)
    }
}
