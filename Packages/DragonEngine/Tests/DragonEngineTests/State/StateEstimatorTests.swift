//  StateEstimatorTests.swift
//  The estimator piece by piece, on hand-made samples with known answers.

import XCTest
import DragonEngine

final class StateEstimatorTests: XCTestCase {
    private let start = Course.syntheticStart

    /// A position `east` metres east and `north` metres north of the start.
    private func offset(east: Double, north: Double = 0) -> (latitude: Double, longitude: Double) {
        let lat = start.latitude + north / Course.earthRadius * 180 / .pi
        let lon = start.longitude + east / (Course.earthRadius * cos(start.latitude * .pi / 180)) * 180 / .pi
        return (lat, lon)
    }

    /// 1 Hz fixes running due east at `speed` m/s from t = 0 to `seconds`.
    private func eastward(seconds: Int, speed: Double = 3, accuracy: Double = 5, doppler: Bool = true,
                          altitude: ((Double) -> Double)? = nil) -> [LocationSample] {
        (0...seconds).map { i in
            let t = Double(i), d = speed * t
            let p = offset(east: d)
            return LocationSample(t: t, latitude: p.latitude, longitude: p.longitude, horizontalAccuracy: accuracy,
                                  speed: doppler ? speed : nil, altitude: altitude?(d))
        }
    }

    private func flatPlan(course: Course? = nil) -> RunPlan {
        RunPlan(distanceMeters: 5_000, targetTime: 5_000 / 3.0, course: course)
    }

    // MARK: Distance

    func testIntegratedGPSDistanceRejectsInaccurateAndImpossibleFixes() {
        var e = StateEstimator(plan: flatPlan())
        for fix in eastward(seconds: 120) {
            e.ingest(fix)
            if fix.t == 50 {
                // A 30 m-accuracy fix 200 m away: too inaccurate to use.
                let p = offset(east: 3 * 50.5, north: 200)
                e.ingest(LocationSample(t: 50.5, latitude: p.latitude, longitude: p.longitude, horizontalAccuracy: 30, speed: 3))
                XCTAssertEqual(e.state(at: 50.5).quality.gpsAccuracy, 30, "reported even though unused")
            }
            if fix.t == 70 {
                // Claims 5 m accuracy but sits 100 m off: implies > 8 m/s.
                let p = offset(east: 3 * 70.5, north: 100)
                e.ingest(LocationSample(t: 70.5, latitude: p.latitude, longitude: p.longitude, horizontalAccuracy: 5, speed: 3))
            }
        }
        XCTAssertEqual(e.state(at: 120).distance, 360, accuracy: 1)
        XCTAssertFalse(e.state(at: 120).quality.paceUnknown)
    }

    func testCourseDistanceComesFromLocatingFixesOnTheCourse() {
        let course = Course.synthetic(length: 3_000, curving: 0)
        var e = StateEstimator(plan: flatPlan(course: course))
        for i in 0...200 {
            let t = Double(i)
            let p = course.position(at: 3 * t)
            e.ingest(LocationSample(t: t, latitude: p.latitude, longitude: p.longitude, horizontalAccuracy: 5, speed: 3))
            if i == 100 {
                let jump = course.position(at: 3 * t + 60)    // 60 m ahead in half a second
                e.ingest(LocationSample(t: t + 0.5, latitude: jump.latitude, longitude: jump.longitude, horizontalAccuracy: 5, speed: 3))
            }
        }
        let s = e.state(at: 200)
        XCTAssertEqual(s.distance, 600, accuracy: 1)
        XCTAssertFalse(s.quality.offCourse)
    }

    func testFixFarFromTheCourseIsFlaggedOffCourse() {
        let course = Course.synthetic(length: 3_000, curving: 0)
        var e = StateEstimator(plan: flatPlan(course: course))
        e.ingest(LocationSample(t: 0, latitude: start.latitude, longitude: start.longitude, horizontalAccuracy: 5))
        let off = offset(east: 3, north: 80)
        e.ingest(LocationSample(t: 10, latitude: off.latitude, longitude: off.longitude, horizontalAccuracy: 5))
        XCTAssertTrue(e.state(at: 10).quality.offCourse)
    }

    func testDistanceIsDeadReckonedWhileGPSIsSilent() {
        var e = StateEstimator(plan: flatPlan())
        for fix in eastward(seconds: 100) { e.ingest(fix) }
        let s = e.state(at: 130)
        XCTAssertEqual(s.distance, 390, accuracy: 1)
        XCTAssertTrue(s.quality.distanceEstimated)
        XCTAssertTrue(s.quality.paceUnknown)
        XCTAssertNil(s.pace30s)
        XCTAssertEqual(s.quality.secondsSinceFix, 30)
        // Not forever: after the limit it holds.
        XCTAssertEqual(e.state(at: 1_000).distance, 300 + 3 * 120, accuracy: 1)
    }

    // MARK: Pace

    func testPaceFromDopplerSpeed() {
        var e = StateEstimator(plan: flatPlan())
        for fix in eastward(seconds: 90) { e.ingest(fix) }
        let s = e.state(at: 90)
        XCTAssertEqual(s.pace30s ?? 0, 1 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(s.pace60s ?? 0, 1 / 3.0, accuracy: 1e-9)
        XCTAssertFalse(s.quality.paceUnknown)
    }

    func testPaceFromPositionsWithoutDoppler() {
        var e = StateEstimator(plan: flatPlan())
        for fix in eastward(seconds: 90, doppler: false) { e.ingest(fix) }
        XCTAssertEqual(e.state(at: 90).pace30s ?? 0, 1 / 3.0, accuracy: 0.001)
    }

    func testPaceUnknownUntilThereIsEnoughGPS() {
        var e = StateEstimator(plan: flatPlan())
        for fix in eastward(seconds: 10) { e.ingest(fix) }
        let s = e.state(at: 10)
        XCTAssertNil(s.pace30s)
        XCTAssertTrue(s.quality.paceUnknown)
    }

    // MARK: Grade

    func testGradeAdjustedPaceFromAltitudeWithoutACourse() {
        var e = StateEstimator(plan: flatPlan())
        for fix in eastward(seconds: 90, altitude: { 20 + 0.05 * $0 }) { e.ingest(fix) }
        let s = e.state(at: 90)
        XCTAssertEqual(s.grade ?? 0, 0.05, accuracy: 1e-6)
        XCTAssertEqual(s.gradeAdjustedPace ?? 0, (1 / 3.0) / GradeModel.paceFactor(grade: 0.05), accuracy: 1e-6)
    }

    func testNoGradeAdjustedPaceWithoutElevation() {
        var e = StateEstimator(plan: flatPlan())
        for fix in eastward(seconds: 90) { e.ingest(fix) }
        XCTAssertNil(e.state(at: 90).gradeAdjustedPace)
        XCTAssertNil(e.state(at: 90).grade)
    }

    func testGradeModel() {
        XCTAssertEqual(GradeModel.paceFactor(grade: 0), 1)
        XCTAssertEqual(GradeModel.paceFactor(grade: 0.05), 1.10, accuracy: 1e-12)
        XCTAssertEqual(GradeModel.paceFactor(grade: -0.05), 0.94, accuracy: 1e-12)
        XCTAssertEqual(GradeModel.paceFactor(grade: -0.30), 0.85, "downhill benefit is capped")
    }

    // MARK: Projection

    func testProjectionStartsOnPlanAndCountsTheHillsAhead() {
        let flat = SyntheticProfile.onPlan.defaultPlan
        let hilly = SyntheticProfile.hilly.defaultPlan
        let p = hilly.course!.position(at: 0)
        let fix = LocationSample(t: 0, latitude: p.latitude, longitude: p.longitude, horizontalAccuracy: 5)

        var a = StateEstimator(plan: flat), b = StateEstimator(plan: hilly)
        a.ingest(fix)
        b.ingest(fix)
        let onFlat = a.state(at: 0), onHills = b.state(at: 0)
        XCTAssertEqual(onFlat.gapToTarget ?? .nan, 0, accuracy: 1)
        XCTAssertEqual(onHills.behindPlanNow ?? .nan, 0, accuracy: 1)
        // Four climbs cost more than their descents give back.
        XCTAssertGreaterThan(onHills.gapToTarget ?? 0, 15)
        XCTAssertLessThan(onHills.gapToTarget ?? .infinity, 60)
    }

    func testProjectionLeansOnActualPaceLate() {
        // 10% slower than plan all the way: by 95% of the way the projection uses it.
        let plan = flatPlan()
        var e = StateEstimator(plan: plan)
        let speed = 3 / 1.1
        for fix in eastward(seconds: 1_750, speed: speed) { e.ingest(fix) }
        let s = e.state(at: 1_750)
        let expected = 1_750 + (plan.distanceMeters - speed * 1_750) / speed
        XCTAssertEqual(s.projectedFinish ?? 0, expected, accuracy: 1)
        XCTAssertGreaterThan(s.behindPlanNow ?? 0, 150)
    }

    // MARK: Heart rate drift

    private func steadyRun(seconds: Int, hr: (Double) -> Double, speed: (Double) -> Double = { _ in 3 }) -> StateEstimator {
        var e = StateEstimator(plan: flatPlan())
        var d = 0.0
        for i in 0...seconds {
            let t = Double(i)
            if i > 0 { d += speed(t) }
            let p = offset(east: d)
            e.ingest(LocationSample(t: t, latitude: p.latitude, longitude: p.longitude, horizontalAccuracy: 5, speed: speed(t)))
            e.ingest(VitalsSample(timestamp: t, heartRate: hr(t), motion: 70))
        }
        return e
    }

    func testHeartRateDriftAtSteadyPace() {
        // 1 bpm a minute for ten minutes, same pace throughout.
        let e = steadyRun(seconds: 600) { 140 + $0 / 60 }
        XCTAssertEqual(e.state(at: 600).heartDrift ?? 0, 5, accuracy: 0.05)
        XCTAssertNil(e.state(at: 200).heartDrift, "needs five minutes of heart rate")
    }

    func testNoHeartRateDriftWhenPaceChanged() {
        // Speeding up explains rising HR; that isn't drift.
        let e = steadyRun(seconds: 600, hr: { 140 + $0 / 60 }, speed: { $0 < 450 ? 3 : 3.3 })
        XCTAssertNil(e.state(at: 600).heartDrift)
    }

    // MARK: Course and attention

    func testAheadNamesTheNextHill() {
        let plan = SyntheticProfile.hilly.defaultPlan
        var e = StateEstimator(plan: plan)
        let course = plan.course!
        for (t, d) in [(0.0, 0.0), (500.0, 1_500.0), (700.0, 2_150.0)] {
            let p = course.position(at: d)
            e.ingest(LocationSample(t: t, latitude: p.latitude, longitude: p.longitude, horizontalAccuracy: 5))
            let ahead = e.state(at: t).ahead
            guard case .hill(let hill)? = ahead?.feature else { return XCTFail("no hill ahead at \(d) m") }
            XCTAssertEqual(hill.startDistance, 2_000, accuracy: 30)
            XCTAssertEqual(ahead?.meters ?? -1, max(0, hill.startDistance - d), accuracy: 5)
        }
    }

    func testAttentionHoldsGlanceAndDwellBriefly() {
        var e = StateEstimator(plan: flatPlan())
        XCTAssertEqual(e.state(at: 0).attention, .idle)
        e.ingest(AttentionSample(t: 10, event: .glance))
        XCTAssertEqual(e.state(at: 11).attention, .glance)
        XCTAssertEqual(e.state(at: 12).attention, .idle)
        e.ingest(AttentionSample(t: 20, event: .dwell))
        XCTAssertEqual(e.state(at: 22).attention, .dwell)
        XCTAssertEqual(e.state(at: 23).attention, .idle)
    }

    // MARK: Samples

    func testVitalsSamplesFromOlderRecordingsDecodeAsWatchSamples() throws {
        let old = #"{"timestamp":1.5,"heartRate":150,"motion":60}"#
        let s = try JSONDecoder().decode(VitalsSample.self, from: Data(old.utf8))
        XCTAssertEqual(s, VitalsSample(timestamp: 1.5, heartRate: 150, motion: 60, source: .watch))

        let phone = VitalsSample(timestamp: 2, heartRate: nil, motion: 40, cadence: 170, source: .phone)
        XCTAssertEqual(try JSONDecoder().decode(VitalsSample.self, from: JSONEncoder().encode(phone)), phone)
    }
}

/// The iPhone barometer's altitude gives the grade when there's no course.
final class BarometerGradeTests: XCTestCase {
    func testBarometerGradeBeatsFlatGPSAltitudeWithoutACourse() {
        let plan = RunPlan(distanceMeters: 5_000, targetTime: 1_500)
        var withBaro = StateEstimator(plan: plan)
        var gpsOnly = StateEstimator(plan: plan)
        let speed = 3.5
        for i in 0...200 {
            let t = TimeInterval(i)
            let d = speed * t
            // A 5% climb the barometer sees; GPS altitude says flat.
            let baro = VitalsSample(timestamp: t, heartRate: nil, motion: nil, altitude: 0.05 * d, source: .phone)
            let fix = LocationSample(t: t, latitude: d / 111_195, longitude: 0, horizontalAccuracy: 5,
                                     speed: speed, altitude: 100)
            withBaro.ingest(baro)
            withBaro.ingest(fix)
            gpsOnly.ingest(fix)
        }
        XCTAssertEqual(withBaro.state(at: 200).grade ?? 0, 0.05, accuracy: 0.005)
        XCTAssertEqual(gpsOnly.state(at: 200).grade ?? 1, 0, accuracy: 0.005)
    }
}
