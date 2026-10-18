//  SyntheticRunTests.swift
//  Whole synthetic races: repeatable, realistic GPS, pace and HR that agree.

import XCTest
@testable import DragonEngine

final class SyntheticRunTests: XCTestCase {
    private let mile = DistanceUnit.metersPerMile

    // MARK: Repeatability

    func testSameSeedProducesTheSameRecordingByteForByte() throws {
        let a = try syntheticRecording(.designWalkthrough, seed: 7).jsonData()
        let b = try syntheticRecording(.designWalkthrough, seed: 7).jsonData()
        XCTAssertEqual(a, b)

        let other = try syntheticRecording(.designWalkthrough, seed: 8).jsonData()
        XCTAssertNotEqual(a, other)
    }

    func testHowTheCallerChunksTimeDoesNotChangeTheSamples() {
        var coarse = SyntheticRun(profile: .hilly, seed: 5)
        var fine = SyntheticRun(profile: .hilly, seed: 5)
        var a: [RunEvent] = [], b: [RunEvent] = []
        while coarse.time < 600 { a += coarse.advance(by: 10) }
        while fine.time < 600 { b += fine.advance(by: 0.037) }
        b += fine.samples(until: 600)
        XCTAssertEqual(a, b.filter { $0.t <= 600 + 1e-9 })
        XCTAssertGreaterThan(a.count, 5_000)
    }

    // MARK: Pace

    func testOnPlanMileSplitsAreWithinFiveSecondsOfPlan() {
        let recording = syntheticRecording(.onPlan, seed: 11)
        let plan = recording.plan!
        let crossings = crossingTimes(recording)
        XCTAssertEqual(crossings.count, 13)

        for (i, split) in splits(crossings).enumerated() {
            let planned = plan.planTime(at: Double(i + 1) * mile) - plan.planTime(at: Double(i) * mile)
            XCTAssertEqual(split, planned, accuracy: 5, "mile \(i + 1)")
        }
    }

    func testSlowFadeMilesAfterNineAreAtLeastFifteenSecondsSlower() {
        let recording = syntheticRecording(.slowFade(from: 9 * mile), seed: 11)
        let plan = recording.plan!
        let all = splits(crossingTimes(recording))
        XCTAssertEqual(all.count, 13)

        for (i, split) in all.enumerated() {
            let planned = plan.planTime(at: Double(i + 1) * mile) - plan.planTime(at: Double(i) * mile)
            if i < 9 {
                XCTAssertEqual(split, planned, accuracy: 5, "mile \(i + 1) is before the fade")
            } else {
                XCTAssertGreaterThanOrEqual(split - planned, 15, "mile \(i + 1)")
            }
        }
    }

    func testDesignWalkthroughMatchesTheDesignDoc() {
        var run = SyntheticRun(profile: .designWalkthrough, seed: 42)
        let recording = run.recordToFinish()
        let plan = recording.plan!

        XCTAssertEqual(plan.distanceMeters, SyntheticProfile.halfMarathon)
        XCTAssertEqual(plan.targetTime, 6_300)
        XCTAssertEqual(plan.targetSecondsPerMile(at: 0), 481, accuracy: 0.5)       // 8:01/mi
        XCTAssertEqual(run.finishTime ?? 0, 6_269, accuracy: 10)                   // ~1:44:29

        let hills = run.course.hills()
        XCTAssertEqual(hills.count, 1)
        XCTAssertEqual((hills[0].startDistance + hills[0].endDistance) / 2 / mile, 7.6, accuracy: 0.15)
        XCTAssertEqual(hills[0].gain, 36, accuracy: 2.5)

        // Hill mile slower than plan, fade miles slower, kick faster than the fade.
        let s = splits(crossingTimes(recording))
        XCTAssertGreaterThan(s[7], 481 + 5)                // mile 8 holds the climb
        XCTAssertGreaterThan(s[11], 481 + 10)              // mile 12, fading
        let kickPace = (run.finishTime! - crossingTimes(recording, every: plan.distanceMeters - 0.25 * mile)[0]) / 0.25
        XCTAssertLessThan(kickPace, s[12] - 20)
    }

    // MARK: GPS

    func testPositionNoiseStaysInTheConfiguredRange() {
        var run = SyntheticRun(profile: .onPlan, seed: 3)
        var errors: [Double] = [], accuracies: [Double] = []
        var normalErrors: [Double] = [], normalCovered = 0

        func check(_ events: [RunEvent]) {
            for case .location(let fix) in events {
                let truth = run.truePosition
                errors.append(Course.haversine(fix.latitude, fix.longitude, truth.latitude, truth.longitude))
                accuracies.append(fix.horizontalAccuracy)
                if fix.horizontalAccuracy <= run.gps.accuracy.upperBound {   // not a spike
                    normalErrors.append(errors.last!)
                    if errors.last! <= fix.horizontalAccuracy + 1e-6 { normalCovered += 1 }
                }
            }
        }
        check(run.advance(by: 0))
        while !run.isFinished { check(run.advance(by: 1)) }

        let range = run.gps.accuracy
        let n = Double(errors.count)
        XCTAssertGreaterThan(n, 6_000)
        let normal = Double(normalErrors.count)
        XCTAssertGreaterThanOrEqual(normal / n, 0.95, "spikes are occasional")
        let tolerance = 1e-6
        // Acceptance: across every fix (spikes included), >= 95% of position errors
        // sit inside the configured 3–8 m range.
        let allInRange = errors.filter { range.lowerBound - tolerance <= $0 && $0 <= range.upperBound + tolerance }
        XCTAssertGreaterThanOrEqual(Double(allInRange.count) / n, 0.95)
        // Error magnitude of normal fixes sits inside the configured 3–8 m (both bounds).
        let inRange = normalErrors.filter { $0 >= range.lowerBound - tolerance && $0 <= range.upperBound + tolerance }
        XCTAssertGreaterThanOrEqual(Double(inRange.count) / normal, 0.95)
        XCTAssertGreaterThanOrEqual(Double(accuracies.filter { range.contains($0) }.count) / n, 0.95)
        // Reported accuracy is a ~95% radius: it covers the true error.
        XCTAssertGreaterThanOrEqual(Double(normalCovered) / normal, 0.95)
        // The error really spreads across the range rather than sitting at one value.
        let sorted = normalErrors.sorted()
        XCTAssertLessThan(sorted[sorted.count / 10], 4.5)
        XCTAssertGreaterThan(sorted[sorted.count * 9 / 10], 6.5)
        XCTAssertTrue(accuracies.contains { $0 >= 25 }, "occasional accuracy spikes toward 30 m")
        XCTAssertLessThanOrEqual(accuracies.max() ?? 0, run.gps.spikeAccuracy)
    }

    func testGPSDropoutLeavesAGapAtTheScriptedDistance() {
        let recording = syntheticRecording(.gpsDropout(at: 5_000, for: 60), seed: 2)
        let gaps = zip(recording.locations, recording.locations.dropFirst()).map { ($0.t, $1.t - $0.t) }
        let long = gaps.filter { $0.1 > 1.5 }
        XCTAssertEqual(long.count, 1)
        XCTAssertEqual(long[0].1, 61, accuracy: 1)
        // 5 km at plan pace (~0.2986 s/m).
        XCTAssertEqual(long[0].0, 5_000 * 6_300 / SyntheticProfile.halfMarathon, accuracy: 15)
        XCTAssertFalse(recording.vitals.isEmpty, "the watch keeps sending")

        var noisy = SyntheticRun.GPS()
        noisy.dropoutsPerHour = 30
        var run = SyntheticRun(profile: .onPlan, seed: 2, gps: noisy)
        let fixes = run.recordToFinish().locations
        XCTAssertGreaterThan(zip(fixes, fixes.dropFirst()).filter { $1.t - $0.t > 1.5 }.count, 5)
    }

    func testFixesCarrySpeedAndAltitude() {
        var run = SyntheticRun(profile: .hilly, seed: 1)
        let fixes = run.recordToFinish().locations
        let speeds = fixes.dropFirst().compactMap(\.speed)
        XCTAssertEqual(speeds.count, fixes.count - 1)
        XCTAssertEqual(speeds.reduce(0, +) / Double(speeds.count), 21_097.5 / 6_300, accuracy: 0.1)
        XCTAssertEqual(fixes.compactMap(\.altitude).max() ?? 0, 15 + 40, accuracy: 8)
    }

    // MARK: Heart rate

    func testHeartRateRisesOnClimbsAndLagsTheClimbStart() {
        var run = SyntheticRun(profile: .hilly, seed: 3)
        var truth: [(t: Double, d: Double)] = []
        var hr: [(t: Double, bpm: Double)] = []
        _ = run.advance(by: 0)
        while !run.isFinished {
            for case .vitals(let v) in run.advance(by: 1) {
                if let bpm = v.heartRate { hr.append((v.timestamp, bpm)) }
            }
            truth.append((run.time, run.distance))
        }

        // 7 s centred mean, to see through sensor noise.
        func smoothed(_ t: Double) -> Double? {
            let w = hr.filter { abs($0.t - t) <= 3.5 }.map(\.bpm)
            return w.isEmpty ? nil : w.reduce(0, +) / Double(w.count)
        }

        let hills = run.course.hills()
        XCTAssertEqual(hills.count, 4)
        for hill in hills {
            let start = truth.first { $0.d >= hill.startDistance }!.t
            let top = truth.first { $0.d >= hill.endDistance }!.t
            let before = hr.filter { $0.t > start - 40 && $0.t <= start }.map(\.bpm)
            let baseline = before.reduce(0, +) / Double(before.count)
            let peak = stride(from: start, through: top + 30, by: 1).compactMap(smoothed).max()!
            let rise = peak - baseline
            XCTAssertGreaterThan(rise, 6, "HR rises on the climb at \(Int(hill.startDistance)) m")

            let halfway = stride(from: start - 20, through: top + 30, by: 1)
                .first { (smoothed($0) ?? 0) >= baseline + rise / 2 }!
            XCTAssertGreaterThanOrEqual(halfway - start, 10, "HR lags the climb at \(Int(hill.startDistance)) m")
            XCTAssertLessThanOrEqual(halfway - start, 30, "HR lags the climb at \(Int(hill.startDistance)) m")
        }
    }

    func testHotDayRaisesHeartRateAtTheSamePace() {
        func meanHR(_ r: RunRecording, from: Double, to: Double) -> Double {
            let w = r.vitals.filter { $0.timestamp >= from && $0.timestamp < to }.compactMap(\.heartRate)
            return w.reduce(0, +) / Double(w.count)
        }
        let cool = syntheticRecording(.onPlan, seed: 4)
        let hot = syntheticRecording(.tooHot, seed: 4)
        XCTAssertEqual(meanHR(hot, from: 60, to: 300), meanHR(cool, from: 60, to: 300), accuracy: 2)
        XCTAssertGreaterThan(meanHR(hot, from: 3_000, to: 6_000), meanHR(cool, from: 3_000, to: 6_000) + 3)
        XCTAssertGreaterThan(hot.duration, cool.duration + 60, "and pace eases off")
    }

    func testFadeShowsUpInHeartRateToo() {
        let fade = syntheticRecording(.slowFade(from: 9 * mile), seed: 4)
        let steady = syntheticRecording(.onPlan, seed: 4)
        func meanHR(_ r: RunRecording, _ range: Range<Double>) -> Double {
            let w = r.vitals.filter { range.contains($0.timestamp) }.compactMap(\.heartRate)
            return w.reduce(0, +) / Double(w.count)
        }
        // Slower but working harder: fatigue, not easing off.
        XCTAssertGreaterThan(meanHR(fade, 5_200..<6_200), meanHR(steady, 5_200..<6_200) + 2)
    }

    // MARK: Performance

    func testATwoHourRaceGeneratesAndReplaysQuickly() throws {
        // Debug builds are several times slower than release; the < 1 s target is for release.
        #if DEBUG
        let budget = 3.0
        #else
        let budget = 1.0
        #endif
        let plan = RunPlan(distanceMeters: 24_000, targetTime: 7_200)
        let start = ProcessInfo.processInfo.systemUptime
        let recording = syntheticRecording(.onPlan, seed: 9, plan: plan)
        let generated = ProcessInfo.processInfo.systemUptime
        let replayed = replaySamples(recording, step: 10)
        let end = ProcessInfo.processInfo.systemUptime

        XCTAssertEqual(recording.duration, 7_200, accuracy: 60)
        XCTAssertEqual(replayed.count, recording.locations.count + recording.vitals.count)
        print(String(format: "2 h race: generate %.3f s, replay %.3f s", generated - start, end - generated))
        XCTAssertLessThan(end - start, budget)
    }
}
