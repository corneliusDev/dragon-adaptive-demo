//  CapacityReplayTests.swift
//  Chunk 6 acceptance on whole synthetic races (seed 42) through RunEngine:
//  the budget it computes each second, and the arbiter obeying it.

import XCTest
import DragonEngine

final class CapacityReplayTests: XCTestCase {
    /// After the crest the runner's effort score (a 5 s mean) and the grade
    /// under them (±10 m of course) need a moment to come down. Allowed: 10 s.
    private let crestSettle: TimeInterval = 10

    func testHillyBudgetIsOneElementOnEveryClimbAndTwoAfterIt() {
        let race = cueRace(.hilly)
        let hills = race.plan.course!.hills()
        XCTAssertEqual(hills.count, SyntheticProfile.hillyHills.count)
        for hill in hills {
            // On the climb (the course's own hill, less the 15 m at each end where
            // the smoothed grade crosses 3%): one element, critical and up.
            let climbing = race.rows.filter {
                $0.state.distance > hill.startDistance + 15 && $0.state.distance < hill.endDistance - 15
            }
            XCTAssertGreaterThan(climbing.count, 60)
            for row in climbing {
                XCTAssertEqual(row.budget.maxElements, 1, "hill at \(Int(hill.startDistance)) m, t=\(row.t)")
                XCTAssertEqual(row.budget.minPriority, .critical)
            }
            // After the crest (and the settle): two elements, advisory and up,
            // for the 300 m after it.
            guard let crest = race.rows.first(where: { $0.state.distance >= hill.endDistance }) else {
                return XCTFail("never reached the crest at \(Int(hill.endDistance)) m")
            }
            let after = race.rows.filter {
                $0.t >= crest.t + crestSettle && $0.state.distance < hill.endDistance + 300
            }
            XCTAssertGreaterThan(after.count, 60)
            for row in after {
                XCTAssertEqual(row.budget.maxElements, 2, "after hill at \(Int(hill.startDistance)) m, t=\(row.t)")
                XCTAssertEqual(row.budget.minPriority, .advisory)
            }
        }
    }

    func testHillySplitOnAClimbWaitsForTheCrestThenShows() {
        // Design: "splits deferred to the crest". Miles 4, 7 and 10 fall on climbs.
        let race = cueRace(.hilly)
        let hills = race.plan.course!.hills()
        var deferred = 0
        for p in race.splitProposals {
            guard case .split(let marker, let unit) = p.cue.key else { continue }
            let at = Double(marker) * unit.meters
            guard let hill = hills.first(where: { at >= $0.startDistance && at < $0.endDistance }) else { continue }
            deferred += 1
            let shown = race.rows.filter { $0.current?.key == p.cue.key }
            guard let first = shown.first else { XCTFail("\(p.cue.key.name) never showed"); continue }
            // Not on the climb: only once over the top.
            XCTAssertGreaterThanOrEqual(first.state.distance, hill.endDistance, p.cue.key.name)
            XCTAssertTrue(race.rows.filter { $0.t < first.t && $0.t >= p.row.t }.allSatisfy { $0.current?.key != p.cue.key })
        }
        XCTAssertEqual(deferred, 3)
    }

    func testDesignWalkthroughAllowsOnlySafetyCuesInTheLastFourHundredMetres() {
        let race = cueRace(.designWalkthrough)
        let last400 = race.rows.filter { race.plan.distanceMeters - $0.state.distance <= 400 }
        XCTAssertGreaterThan(last400.count, 80)
        for row in last400 {
            let left = Int(race.plan.distanceMeters - row.state.distance)
            XCTAssertTrue(row.budget.admits(.safety), "\(left) m to go")
            XCTAssertFalse([.info, .advisory, .critical].contains { row.budget.admits($0) },
                           "\(left) m to go: \(row.situation.label) allows \(row.budget.minPriority) and up")
            XCTAssertTrue(row.current.map { $0.priority == .safety } ?? true, "\(left) m to go")
        }
    }

    func testOnPlanBudgetIsTwoElementsAllRaceExceptTheFinalStretch() {
        // Racing on the flat at ~80 effort: steady at race effort throughout,
        // so every split before the final stretch still shows. The last 400 m,
        // by position, is safety only, whatever the runner does.
        let race = cueRace(.onPlan)
        let left = { (row: CueRace.Row) in race.plan.distanceMeters - row.state.distance }
        let racing = race.rows.filter { $0.t > 10 && left($0) > 400 }
        let stretch = race.rows.filter { left($0) <= 400 }
        XCTAssertGreaterThan(stretch.count, 80)
        XCTAssertTrue(racing.allSatisfy { $0.situation == .raceEffort },
                      "\(Set(racing.map(\.situation.label)))")
        XCTAssertTrue(racing.allSatisfy { $0.budget.maxElements == 2 && $0.budget.minPriority == .advisory })
        for row in stretch {
            XCTAssertEqual(row.situation, .finalStretch, "\(Int(left(row))) m to go")
            XCTAssertTrue(row.budget.finalStretch)
            XCTAssertEqual(row.budget.maxElements, 0)
            XCTAssertTrue(row.budget.admits(.safety))
            XCTAssertFalse([.info, .advisory, .critical].contains { row.budget.admits($0) }, "\(Int(left(row))) m to go")
            XCTAssertTrue(row.current.map { $0.priority == .safety } ?? true)
        }
    }
}
