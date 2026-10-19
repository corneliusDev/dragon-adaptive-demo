//  SourceSelectionTests.swift
//  Which device each reading comes from, and what happens when it goes stale:
//  directly against SourceSelection, then end to end through the estimator.

import XCTest
import DragonEngine

final class SourceSelectionTests: XCTestCase {
    private func reading(_ value: Double, at t: TimeInterval, _ source: VitalsDevice) -> SourceReading {
        SourceReading(value: value, t: t, source: source)
    }

    // MARK: Heart rate: Watch only

    func testHeartRateComesFromTheWatch() {
        XCTAssertEqual(SourceSelection.heartRate(watch: reading(150, at: 10, .watch), at: 12)?.value, 150)
    }

    func testHeartRateOlderThanFiveSecondsIsMissing() {
        let hr = reading(150, at: 10, .watch)
        XCTAssertNotNil(SourceSelection.heartRate(watch: hr, at: 15))
        XCTAssertNil(SourceSelection.heartRate(watch: hr, at: 15.01))
    }

    func testEstimatorIgnoresPhoneHeartRateEvenWhenTheWatchIsStale() {
        var e = StateEstimator(plan: RunPlan(distanceMeters: 5_000, targetTime: 1_500))
        e.ingest(VitalsSample(timestamp: 0, heartRate: 140, motion: nil, source: .watch))
        e.ingest(VitalsSample(timestamp: 8, heartRate: 160, motion: nil, source: .phone))
        let s = e.state(at: 9)
        XCTAssertNil(s.heartRate)
        XCTAssertEqual(s.quality.secondsSinceHeartRate, 9)
        XCTAssertTrue(s.quality.heartRateMissing)
    }

    func testEstimatorReportsMissingHeartRateNotTheLastValue() {
        let zones = HeartRateZones(resting: 55, threshold: 172, max: 190)
        var e = StateEstimator(plan: RunPlan(distanceMeters: 5_000, targetTime: 1_500, heartRateZones: zones))
        e.ingest(VitalsSample(timestamp: 10, heartRate: 150, motion: nil))

        let fresh = e.state(at: 14.9)
        XCTAssertEqual(fresh.heartRate, 150)
        XCTAssertEqual(fresh.heartZone, zones.zone(for: 150))
        XCTAssertFalse(fresh.quality.heartRateMissing)

        let stale = e.state(at: 15.1)
        XCTAssertNil(stale.heartRate)
        XCTAssertNil(stale.heartZone)
        XCTAssertTrue(stale.quality.heartRateMissing)
        XCTAssertEqual(stale.quality.secondsSinceHeartRate ?? 0, 5.1, accuracy: 1e-9)
    }

    // MARK: Effort: Watch, else phone

    func testEffortPrefersTheWatchWhenBothAreFresh() {
        let pick = SourceSelection.effort(watch: reading(70, at: 9, .watch), phone: reading(20, at: 10, .phone), at: 10)
        XCTAssertEqual(pick?.reading.source, .watch)
        XCTAssertEqual(pick?.isFallback, false)
    }

    func testEffortFallsBackToThePhoneWhenWatchMotionIsStale() {
        let pick = SourceSelection.effort(watch: reading(70, at: 6.9, .watch), phone: reading(20, at: 9.5, .phone), at: 10)
        XCTAssertEqual(pick?.reading.source, .phone)
        XCTAssertEqual(pick?.reading.value, 20)
        XCTAssertEqual(pick?.isFallback, true)
    }

    func testEffortUsesThePhoneWithoutAWatch() {
        let pick = SourceSelection.effort(watch: nil, phone: reading(20, at: 10, .phone), at: 10)
        XCTAssertEqual(pick?.reading.source, .phone)
        XCTAssertEqual(pick?.isFallback, true)
    }

    func testEffortWatchStillFreshAtExactlyThreeSeconds() {
        let pick = SourceSelection.effort(watch: reading(70, at: 7, .watch), phone: reading(20, at: 10, .phone), at: 10)
        XCTAssertEqual(pick?.reading.source, .watch)
    }

    func testEffortNoneWhenBothAreStale() {
        XCTAssertNil(SourceSelection.effort(watch: reading(70, at: 1, .watch), phone: reading(20, at: 2, .phone), at: 10))
    }

    func testEstimatorEffortSwitchesDevicesAndFlagsTheFallbackWithoutAveraging() {
        var e = StateEstimator(plan: RunPlan(distanceMeters: 5_000, targetTime: 1_500))
        e.ingest(VitalsSample(timestamp: 0, heartRate: nil, motion: 80, source: .watch))   // hard
        e.ingest(VitalsSample(timestamp: 0, heartRate: nil, motion: 20, source: .phone))   // light

        var s = e.state(at: 1)
        XCTAssertEqual(s.effort, .hard)
        XCTAssertEqual(s.quality.effortSource, .watch)
        XCTAssertFalse(s.quality.effortFallback)

        // Watch goes quiet; phone keeps reporting.
        e.ingest(VitalsSample(timestamp: 3.5, heartRate: nil, motion: 20, source: .phone))
        s = e.state(at: 4)
        XCTAssertEqual(s.effort, .light, "the phone's own reading, not a blend with the watch")
        XCTAssertEqual(s.quality.effortSource, .phone)
        XCTAssertTrue(s.quality.effortFallback)

        // Watch comes back.
        e.ingest(VitalsSample(timestamp: 4.5, heartRate: nil, motion: 50, source: .watch))
        s = e.state(at: 5)
        XCTAssertEqual(s.effort, .moderate)
        XCTAssertEqual(s.quality.effortSource, .watch)
        XCTAssertFalse(s.quality.effortFallback)

        // Everything stale: hold the newest reading, flag no source.
        s = e.state(at: 20)
        XCTAssertEqual(s.effort, .moderate)
        XCTAssertNil(s.quality.effortSource)
    }

    func testSyntheticWatchPlaysTheWatchRole() {
        var e = StateEstimator(plan: RunPlan(distanceMeters: 5_000, targetTime: 1_500))
        e.ingest(VitalsSample(timestamp: 0, heartRate: 150, motion: 80, source: .synthetic))
        e.ingest(VitalsSample(timestamp: 0, heartRate: nil, motion: 20, source: .phone))
        let s = e.state(at: 1)
        XCTAssertEqual(s.heartRate, 150)
        XCTAssertEqual(s.quality.effortSource, .synthetic)
        XCTAssertFalse(s.quality.effortFallback)
    }

    // MARK: Cadence: phone, else Watch

    func testCadencePrefersThePhonePedometerWhenBothAreFresh() {
        let pick = SourceSelection.cadence(phone: reading(172, at: 8, .phone), watch: reading(168, at: 10, .watch), at: 10)
        XCTAssertEqual(pick?.reading.source, .phone)
        XCTAssertEqual(pick?.isFallback, false)
    }

    func testCadenceFallsBackToTheWatchWhenThePhoneIsStale() {
        let pick = SourceSelection.cadence(phone: reading(172, at: 4.9, .phone), watch: reading(168, at: 10, .watch), at: 10)
        XCTAssertEqual(pick?.reading.source, .watch)
        XCTAssertEqual(pick?.reading.value, 168)
        XCTAssertEqual(pick?.isFallback, true)
    }

    func testCadenceNoneWhenBothAreStale() {
        XCTAssertNil(SourceSelection.cadence(phone: reading(172, at: 1, .phone), watch: reading(168, at: 2, .watch), at: 10))
    }

    func testEstimatorCadenceFollowsThePreference() {
        var e = StateEstimator(plan: RunPlan(distanceMeters: 5_000, targetTime: 1_500))
        e.ingest(VitalsSample(timestamp: 0, heartRate: nil, motion: nil, cadence: 172, source: .phone))
        e.ingest(VitalsSample(timestamp: 0, heartRate: nil, motion: nil, cadence: 168, source: .watch))
        var s = e.state(at: 1)
        XCTAssertEqual(s.cadence, 172)
        XCTAssertEqual(s.quality.cadenceSource, .phone)
        XCTAssertFalse(s.quality.cadenceFallback)

        e.ingest(VitalsSample(timestamp: 6, heartRate: nil, motion: nil, cadence: 166, source: .watch))
        s = e.state(at: 6.5)
        XCTAssertEqual(s.cadence, 166)
        XCTAssertEqual(s.quality.cadenceSource, .watch)
        XCTAssertTrue(s.quality.cadenceFallback)

        s = e.state(at: 30)
        XCTAssertNil(s.cadence)
        XCTAssertNil(s.quality.cadenceSource)
    }
}
