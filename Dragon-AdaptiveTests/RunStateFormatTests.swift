//  RunStateFormatTests.swift
//  The debug overlay's formatting: engine metres/seconds in, clocks and min/mi out.

import XCTest
import DragonEngine
@testable import Dragon_Adaptive

final class RunStateFormatTests: XCTestCase {
    func testClockAndGap() {
        XCTAssertEqual(RunStateFormat.clock(6_269.4), "1:44:29")
        XCTAssertEqual(RunStateFormat.clock(245), "4:05")
        XCTAssertEqual(RunStateFormat.gap(12.4), "+0:12")
        XCTAssertEqual(RunStateFormat.gap(-65), "-1:05")
        XCTAssertEqual(RunStateFormat.gap(0.2), "+0:00")
    }

    func testPacePerMileAndKilometre() {
        let plan = SyntheticProfile.halfMarathon
        XCTAssertEqual(RunStateFormat.pace(6_300 / plan), "8:01")
        XCTAssertEqual(RunStateFormat.pace(6_300 / plan, unit: .kilometers), "4:59")
        XCTAssertEqual(RunStateFormat.pace(nil), "—")
    }

    func testFlagsNameWhatQualityIsWorriedAbout() {
        var q = DataQuality()
        q.secondsSinceHeartRate = 1
        q.paceUnknown = false
        XCTAssertEqual(RunStateFormat.flags(q), [])
        q.paceUnknown = true
        q.distanceEstimated = true
        q.secondsSinceHeartRate = 9
        q.effortFallback = true
        XCTAssertEqual(RunStateFormat.flags(q), ["PACE ?", "DEAD RECKONING", "HR MISSING", "EFFORT FROM PHONE"])
    }

    /// The race the overlay shows: the app's synthetic race fed to the engine's estimator.
    func testSyntheticRaceProducesAProjectionAndQuality() {
        let source = SyntheticRaceSource(profile: .onPlan, seed: 3)
        var estimator = StateEstimator(plan: source.run.plan)
        source.onSample = { estimator.ingest($0) }
        source.onVitals = { estimator.ingest($0) }
        source.step(by: 600)

        let s = estimator.state(at: source.run.time)
        XCTAssertEqual(s.distance, source.run.distance, accuracy: 15)
        XCTAssertEqual(s.gapToTarget ?? .nan, 0, accuracy: 15)
        XCTAssertNotNil(s.pace30s)
        XCTAssertEqual(s.quality.effortSource, .watch)
    }
}
