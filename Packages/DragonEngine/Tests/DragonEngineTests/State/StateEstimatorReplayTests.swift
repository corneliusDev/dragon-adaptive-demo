//  StateEstimatorReplayTests.swift
//  Chunk 3 acceptance: whole synthetic races (seed 42, the chunk 2 profiles)
//  replayed through the estimator, checked against the simulator's truth.

import XCTest
import DragonEngine

final class StateEstimatorReplayTests: XCTestCase {
    private let mile = DistanceUnit.metersPerMile
    private let total = SyntheticProfile.halfMarathon

    // MARK: Gap to target

    func testOnPlanGapStaysWithinTenSecondsAfterMileOne() {
        let race = estimatedRace(.onPlan)
        let after = race.rows.filter { $0.state.distance >= mile }
        XCTAssertGreaterThan(after.count, 5_000)
        for row in after {
            guard let gap = row.state.gapToTarget else { return XCTFail("no gap at t=\(row.t)") }
            XCTAssertEqual(gap, 0, accuracy: 10, "t=\(row.t)")
        }
    }

    func testSlowFadeGapPassesFifteenSecondsWithinNinetySecondsOfTheFadeBeingMeasurable() {
        let from = 9 * mile
        let race = estimatedRace(.slowFade(from: from))

        // Before the fade the gap never reaches +15 s.
        for row in race.rows where row.state.distance >= mile && row.trueDistance < from {
            XCTAssertLessThan(row.state.gapToTarget ?? .infinity, 15, "t=\(row.t)")
        }

        // Measurable: the runner's true pace over the last minute is 3% off plan,
        // well clear of normal wobble (~0.5%).
        guard let measurable = race.rows.indices.first(where: { i in
            race.rows[i].trueDistance > from
                && (race.truePace(endingAt: i, window: 60) ?? 0) >= race.planPace(at: from) * 1.03
        }) else { return XCTFail("fade never became measurable") }

        guard let passed = race.rows[measurable...].first(where: { ($0.state.gapToTarget ?? 0) >= 15 }) else {
            return XCTFail("gap never passed +15 s")
        }
        XCTAssertLessThanOrEqual(passed.t - race.rows[measurable].t, 90)
    }

    // MARK: Hills

    func testHillyRawPaceSlowsOnClimbsWhileGradeAdjustedPaceHoldsPlan() {
        let race = estimatedRace(.hilly)
        let plan = race.planPace(at: 0)

        for hill in SyntheticProfile.hillyHills {
            // Climb, once the 30 s window is all uphill.
            let climb = race.rows.filter { $0.state.distance > hill.start + 100 && $0.state.distance < hill.start + hill.length }
            XCTAssertGreaterThan(climb.count, 60)
            for row in climb {
                guard let raw = row.state.pace30s else { continue }
                XCTAssertGreaterThan(raw, plan * 1.05, "raw pace on the climb from \(hill.start) at t=\(row.t)")
            }

            // Up, over and down the other side.
            let hillRows = race.rows.filter {
                $0.state.distance > hill.start && $0.state.distance < hill.start + hill.length + (hill.descent ?? 0) + 100
            }
            var known = 0
            for row in hillRows {
                // GPS bad patches (30 m fixes are dropped) leave pace honestly unknown.
                guard let gap = row.state.gradeAdjustedPace else {
                    XCTAssertTrue(row.state.quality.paceUnknown, "t=\(row.t)")
                    continue
                }
                known += 1
                XCTAssertEqual(gap / plan, 1, accuracy: 0.03, "GAP on the hill from \(hill.start) at t=\(row.t)")
            }
            XCTAssertGreaterThan(Double(known), 0.9 * Double(hillRows.count))
        }
    }

    // MARK: GPS dropout

    func testGPSDropoutMakesPaceUnknownAndDistanceResumesAfterIt() {
        let race = estimatedRace(.gpsDropout(at: 5_000, for: 60))
        // The longest stretch without a usable fix (bad patches make short ones).
        var stretches: [[EstimatedRace.Row]] = [[]]
        for row in race.rows where row.trueDistance < total {
            if (row.state.quality.secondsSinceFix ?? 0) > 5 {
                stretches[stretches.count - 1].append(row)
            } else if !stretches[stretches.count - 1].isEmpty {
                stretches.append([])
            }
        }
        let stale = stretches.max { $0.count < $1.count } ?? []
        // A 60 s outage, flagged after 5 s (a GPS bad patch next to it can stretch it).
        XCTAssertGreaterThanOrEqual(stale.count, 53)
        XCTAssertLessThanOrEqual(stale.count, 70)
        guard let first = stale.first, let last = stale.last else { return }
        XCTAssertEqual(first.trueDistance, 5_000, accuracy: 30)

        for row in stale {
            XCTAssertNil(row.state.pace30s, "t=\(row.t)")
            XCTAssertNil(row.state.pace60s, "t=\(row.t)")
            XCTAssertNil(row.state.gradeAdjustedPace, "t=\(row.t)")
            XCTAssertTrue(row.state.quality.paceUnknown, "t=\(row.t)")
            XCTAssertTrue(row.state.quality.distanceEstimated, "t=\(row.t)")
            // Dead-reckoned meanwhile, so plan and projection don't freeze.
            XCTAssertEqual(row.state.distance, row.trueDistance, accuracy: 25, "t=\(row.t)")
            XCTAssertNotNil(row.state.projectedFinish)
        }

        // Back on GPS: distance snaps to the truth and pace returns.
        let after = race.rows.filter { $0.t > last.t && $0.t <= last.t + 300 }
        XCTAssertFalse(after.first?.state.quality.distanceEstimated ?? true)
        for row in after {
            XCTAssertEqual(row.state.distance, row.trueDistance, accuracy: 10, "t=\(row.t)")
        }
        let paceBack = after.first { $0.state.pace30s != nil }
        XCTAssertNotNil(paceBack)
        XCTAssertLessThanOrEqual((paceBack?.t ?? .infinity) - last.t, 20)
        XCTAssertEqual(race.rows.last!.state.distance, total, accuracy: 10)
    }

    func testDistanceTracksTheTruthAllRace() {
        for profile in [SyntheticProfile.onPlan, .hilly] {
            let race = estimatedRace(profile)
            for row in race.rows where row.t > 5 {
                XCTAssertEqual(row.state.distance, row.trueDistance, accuracy: 10, "\(profile.name) t=\(row.t)")
            }
        }
    }

    // MARK: Projected finish

    func testProjectedFinishIsWithinFiveSecondsOverTheLastMile() {
        for profile in SyntheticProfile.all where profile != .designWalkthrough {
            let race = estimatedRace(profile)
            let lastMile = race.rows.filter { $0.trueDistance >= total - mile }
            XCTAssertGreaterThan(lastMile.count, 400, profile.name)
            for row in lastMile {
                XCTAssertEqual(row.state.projectedFinish ?? 0, race.finish, accuracy: 5, "\(profile.name) t=\(row.t)")
            }
        }
    }

    /// The walkthrough ends with a scripted ~8% kick over the last 0.25 mi that
    /// nothing in the data foretells, so until the kick the projection is late by
    /// roughly the time the kick will save (~9 s). It closes to 5 s within a
    /// minute of the kick starting.
    func testDesignWalkthroughProjectionAllowsForTheUnforeseeableKick() {
        let race = estimatedRace(.designWalkthrough)
        for row in race.rows where row.trueDistance >= total - mile {
            let error = (row.state.projectedFinish ?? 0) - race.finish
            XCTAssertEqual(error, 0, accuracy: 13, "t=\(row.t)")
            if row.trueDistance >= total - 200 {
                XCTAssertEqual(error, 0, accuracy: 5, "t=\(row.t)")
            }
        }
    }

    // MARK: Heart rate

    func testHeartRateIsReportedOnlyWhileFresh() {
        let race = estimatedRace(.onPlan)
        var missing = 0
        for row in race.rows {
            let age = row.state.quality.secondsSinceHeartRate ?? .infinity
            if age > 5 {
                XCTAssertNil(row.state.heartRate, "t=\(row.t)")
                XCTAssertNil(row.state.heartZone, "t=\(row.t)")
                XCTAssertTrue(row.state.quality.heartRateMissing)
                missing += 1
            } else {
                XCTAssertNotNil(row.state.heartRate, "t=\(row.t)")
                XCTAssertNotNil(row.state.heartZone, "t=\(row.t)")
            }
        }
        XCTAssertGreaterThan(missing, 0, "the synthetic watch has outages; some HR should go missing")
    }

    func testNoHeartRateDriftAtSteadyPaceAndSteadyConditions() {
        let race = estimatedRace(.onPlan)
        let drifts = race.rows.filter { $0.t > 900 }.compactMap(\.state.heartDrift)
        XCTAssertGreaterThan(drifts.count, 4_000)
        XCTAssertEqual(drifts.reduce(0, +) / Double(drifts.count), 0, accuracy: 0.3)
    }
}
