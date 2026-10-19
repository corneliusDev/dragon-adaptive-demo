//  MovementPhaseTests.swift
//  Chunk 6 acceptance: the movement phase classifier, through the estimator,
//  on hand-scripted segments — a steady block, a 20 s surge, a hill, and the
//  last 400 m with a sprint — and on the synthetic races.

import XCTest
import DragonEngine

final class MovementPhaseTests: XCTestCase {
    func testSteadyBlockIsSteadyAndStandingStillIsStopped() {
        let run = segmentRun([Segment(seconds: 300, speed: 3.5, effort: 75),
                              Segment(seconds: 60, speed: 0, effort: 2)])
        // After the first few fixes, the steady block is steady all through.
        for row in run.rows(from: 10, to: 300) {
            XCTAssertEqual(row.state.phase, .steady, "t=\(row.t)")
        }
        // Within a few seconds of stopping, stopped, and it stays that way.
        for row in run.rows(from: 306, to: 360) {
            XCTAssertEqual(row.state.phase, .stopped, "t=\(row.t)")
        }
        XCTAssertEqual(run.rows.last?.state.effortScore ?? -1, 2, accuracy: 0.01)
    }

    func testTwentySecondSurgeIsSurgingThenSettles() {
        // 20% faster for 20 s, in the middle of steady running.
        let run = segmentRun([Segment(seconds: 180, speed: 3.5, effort: 75),
                              Segment(seconds: 20, speed: 4.2, effort: 85),
                              Segment(seconds: 120, speed: 3.5, effort: 75)])
        XCTAssertTrue(run.rows(from: 10, to: 181).allSatisfy { $0.state.phase == .steady })
        let during = run.rows(from: 181, to: 201)
        let surging = during.filter { $0.state.phase == .surging }
        // Caught within 5 s, and held for the rest of the surge.
        XCTAssertLessThanOrEqual(surging.first?.t ?? .infinity, 185)
        XCTAssertGreaterThanOrEqual(surging.count, 16)
        XCTAssertTrue(during.filter { $0.t >= 185 }.allSatisfy { $0.state.phase == .surging })
        // Back to steady within 5 s of easing off, and no surge after it.
        XCTAssertTrue(run.rows(from: 206, to: 320).allSatisfy { $0.state.phase == .steady })
    }

    func testFasterPaceHeldForMinutesBecomesTheNewSteady() {
        let run = segmentRun([Segment(seconds: 180, speed: 3.5, effort: 75),
                              Segment(seconds: 180, speed: 4.2, effort: 85)])
        XCTAssertTrue(run.rows(from: 185, to: 195).allSatisfy { $0.state.phase == .surging })
        XCTAssertTrue(run.rows(from: 250, to: 360).allSatisfy { $0.state.phase == .steady })
    }

    func testHillIsClimbingOnlyWhileOnIt() {
        // A 6% climb of 400 m from 1 km, then back down. The runner holds effort
        // and slows on it, and speeds up down the far side: neither is a surge.
        let hill = SyntheticHill(start: 1_000, length: 400, gain: 24, descent: 600)
        let run = segmentRun([Segment(seconds: 900, speed: 3.5, effort: 78)], hills: [hill])
        let course = run.plan.course!
        guard let climb = course.hills().first else { return XCTFail("no hill on the course") }
        for row in run.rows {
            let d = row.distance
            if d > climb.startDistance + 15 && d < climb.endDistance - 15 {
                XCTAssertEqual(row.state.phase, .climbing, "d=\(Int(d))")
            } else if d < climb.startDistance - 15 || d > climb.endDistance + 15 {
                XCTAssertEqual(row.state.phase, .steady, "d=\(Int(d))")
            }
        }
        XCTAssertTrue(run.rows.contains { $0.state.phase == .climbing })
    }

    func testSprintInTheLastFourHundredMetresIsAKick() {
        // 5 km: steady, then a sprint from 350 m out to the line.
        let length = 5_000.0
        let steady = Segment(seconds: 1_329, speed: 3.5, effort: 78)   // ≈ 4 650 m
        let run = segmentRun([steady, Segment(seconds: 200, speed: 4.2, effort: 92)], length: length)
        let sprintFrom = run.rows.first { $0.t > 1_329 }!.t
        // Not before the sprint.
        XCTAssertTrue(run.rows.filter { $0.t < sprintFrom && $0.t > 10 }.allSatisfy { $0.state.phase == .steady })
        // From a few seconds into it, to the finish.
        let kicked = run.rows.filter { $0.t >= sprintFrom + 4 }
        XCTAssertFalse(kicked.isEmpty)
        XCTAssertTrue(kicked.allSatisfy { $0.state.phase == .kick }, "\(kicked.map(\.state.phase))")
    }

    func testSameSprintBeforeTheLastFourHundredMetresIsASurgeNotAKick() {
        let run = segmentRun([Segment(seconds: 900, speed: 3.5, effort: 78),
                              Segment(seconds: 20, speed: 4.2, effort: 92),
                              Segment(seconds: 60, speed: 3.5, effort: 78)], length: 5_000)
        XCTAssertFalse(run.rows.contains { $0.state.phase == .kick })
        XCTAssertTrue(run.rows.contains { $0.state.phase == .surging })
    }

    func testRunningOnToTheLineWithoutSpeedingUpIsNotAKick() {
        let run = segmentRun([Segment(seconds: 1_600, speed: 3.5, effort: 78)], length: 5_000)
        XCTAssertEqual(run.rows.last?.distance, 5_000)
        XCTAssertFalse(run.rows.contains { $0.state.phase == .kick })
    }

    // MARK: Synthetic races

    func testSyntheticRacesOnlyKickInTheWalkthrough() {
        for profile in SyntheticProfile.all {
            let race = cueRace(profile)
            let kicks = race.rows.filter { $0.state.phase == .kick }
            if profile == .designWalkthrough {
                // The walkthrough kicks from 0.25 mi (402 m) out, ramping up to full
                // speed over 50 m: caught before the ramp ends, and held to the line.
                guard let first = kicks.first else { XCTFail("no kick in the walkthrough"); continue }
                let kickFrom = race.plan.distanceMeters - 0.25 * DistanceUnit.metersPerMile
                XCTAssertGreaterThan(first.trueDistance, kickFrom)
                XCTAssertLessThan(first.trueDistance, kickFrom + 50)
                XCTAssertTrue(race.rows.filter { $0.t >= first.t }.allSatisfy { $0.state.phase == .kick })
            } else {
                XCTAssertTrue(kicks.isEmpty, "\(profile.name) kicked at \(kicks.first.map { Int($0.trueDistance) } ?? 0) m")
            }
            // Nobody in these races surges or stops.
            XCTAssertFalse(race.rows.contains { $0.state.phase == .surging || $0.state.phase == .stopped },
                           profile.name)
        }
    }
}
