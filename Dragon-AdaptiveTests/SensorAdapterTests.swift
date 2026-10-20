//  SensorAdapterTests.swift
//  CoreLocationSource and PhoneMotionSource map fake Core Location and Core
//  Motion readings into the engine's samples in run time, and drop invalid
//  (negative accuracy, NaN) and stale readings.

import XCTest
import CoreLocation
import DragonEngine
@testable import Dragon_Adaptive

final class CoreLocationSourceTests: XCTestCase {
    private let clock = FakeClock()
    private var timeline: RunTimeline { RunTimeline(startingOn: clock) }

    func testAFixMapsToARunTimeSample() {
        let start = timeline
        clock.uptime += 12
        let fix = CLLocation.fix(51.5, -0.12, at: clock.now.addingTimeInterval(-0.8), accuracy: 6, speed: 3.2,
                                 altitude: 42, verticalAccuracy: 3)
        guard case .sample(let s) = CoreLocationSource.map(fix, timeline: start, now: clock.now, after: nil) else {
            return XCTFail("a good fix should map")
        }
        XCTAssertEqual(s.t, 11.2, accuracy: 1e-6)
        XCTAssertEqual(s.latitude, 51.5)
        XCTAssertEqual(s.longitude, -0.12)
        XCTAssertEqual(s.horizontalAccuracy, 6)
        XCTAssertEqual(s.speed, 3.2)
        XCTAssertEqual(s.altitude, 42)
    }

    func testInvalidFixesAreDropped() {
        let start = timeline
        clock.uptime += 5
        let now = clock.now
        let at = now.addingTimeInterval(-1)
        XCTAssertEqual(CoreLocationSource.map(.fix(51.5, -0.1, at: at, accuracy: -1), timeline: start, now: now, after: nil),
                       .invalid, "negative accuracy: no fix")
        XCTAssertEqual(CoreLocationSource.map(.fix(51.5, -0.1, at: at, accuracy: .nan), timeline: start, now: now, after: nil),
                       .invalid)
        XCTAssertEqual(CoreLocationSource.map(.fix(.nan, -0.1, at: at), timeline: start, now: now, after: nil), .invalid)
        XCTAssertEqual(CoreLocationSource.map(.fix(51.5, 200, at: at), timeline: start, now: now, after: nil), .invalid)
    }

    func testUnvouchedSpeedAndAltitudeAreLeftOut() {
        let start = timeline
        clock.uptime += 5
        let now = clock.now
        let at = now.addingTimeInterval(-1)
        func mapped(_ l: CLLocation) -> LocationSample? {
            if case .sample(let s) = CoreLocationSource.map(l, timeline: start, now: now, after: nil) { return s }
            return nil
        }
        XCTAssertNil(mapped(.fix(51.5, -0.1, at: at, speed: -1))?.speed)
        XCTAssertNil(mapped(.fix(51.5, -0.1, at: at, speed: 3, speedAccuracy: -1))?.speed)
        XCTAssertNil(mapped(.fix(51.5, -0.1, at: at, speed: .nan))?.speed)
        XCTAssertNil(mapped(.fix(51.5, -0.1, at: at, verticalAccuracy: -1))?.altitude)
        XCTAssertNil(mapped(.fix(51.5, -0.1, at: at, altitude: .nan))?.altitude)
        XCTAssertNotNil(mapped(.fix(51.5, -0.1, at: at, speed: -1)), "the position itself is still good")
    }

    func testStaleFixesAreDropped() {
        let start = timeline
        clock.uptime += 60
        let now = clock.now
        // Cached: taken 30 s before it arrived.
        XCTAssertEqual(CoreLocationSource.map(.fix(51.5, -0.1, at: now.addingTimeInterval(-30)), timeline: start,
                                              now: now, after: nil), .stale)
        // Taken before the run started.
        let early = RunTimeline(startDate: now.addingTimeInterval(-2), startUptime: clock.uptime - 2)
        XCTAssertEqual(CoreLocationSource.map(.fix(51.5, -0.1, at: now.addingTimeInterval(-3)), timeline: early,
                                              now: now, after: nil), .stale)
        // Not newer than the last fix sent.
        XCTAssertEqual(CoreLocationSource.map(.fix(51.5, -0.1, at: now.addingTimeInterval(-1)), timeline: start,
                                              now: now, after: 59), .stale)
    }

    func testTheSourceRunsTheProviderForARunAndCountsDrops() {
        let provider = FakeLocationProvider()
        let source = CoreLocationSource(provider: provider, clock: clock)
        var samples: [LocationSample] = []
        source.onSample = { samples.append($0) }
        source.timeline = timeline
        source.start()
        XCTAssertEqual(provider.started, [true], "fitness updates with background location for a run")

        clock.uptime += 3
        provider.deliver([.fix(51.5, -0.1, at: clock.now.addingTimeInterval(-0.5)),
                          .fix(51.5, -0.1, at: clock.now.addingTimeInterval(-0.5), accuracy: -1),
                          .fix(51.5, -0.1, at: clock.now.addingTimeInterval(-40))])
        XCTAssertEqual(samples.map(\.t), [2.5])
        XCTAssertEqual(source.dropped, DroppedReadings(invalid: 1, stale: 1))
        source.stop()
        XCTAssertEqual(provider.stopped, 1)
        provider.isUpdating = true
        provider.deliver([.fix(51.5, -0.1, at: clock.now)])
        XCTAssertEqual(samples.count, 1, "stopped: no more samples")
    }

    func testPausedTimeIsLeftOutOfRunTime() {
        var t = timeline
        clock.uptime += 10
        t.pause(on: clock)
        XCTAssertEqual(t.runTime(on: clock), 10)
        clock.uptime += 30
        XCTAssertEqual(t.runTime(on: clock), 10, "the run clock stands still while paused")
        t.resume(on: clock)
        clock.uptime += 5
        XCTAssertEqual(t.runTime(on: clock), 15)
        XCTAssertEqual(t.runTime(date: clock.now), 15, accuracy: 1e-6)
    }
}

final class PhoneMotionSourceTests: XCTestCase {
    private let clock = FakeClock()

    private func source(_ fakes: FakeSensors? = nil) -> (PhoneMotionSource, () -> [VitalsSample]) {
        let f = fakes ?? FakeSensors()
        let s = PhoneMotionSource(motion: f.motion, pedometer: f.pedometer, altimeter: f.altimeter, clock: clock)
        var out: [VitalsSample] = []
        s.onSample = { out.append($0) }
        s.timeline = RunTimeline(startingOn: clock)
        return (s, { out })
    }

    /// 50 Hz readings of one magnitude (g) over run seconds [from, to).
    private func shake(_ s: PhoneMotionSource, g: Double, from: Double, to: Double, start: TimeInterval) {
        var t = from
        while t < to - 1e-9 {
            clock.uptime = start + t + 0.01
            s.receive(DeviceMotionReading(timestamp: start + t, x: g * 0.6, y: g * 0.8, z: 0))
            t += 0.02
        }
    }

    func testEachSecondOfMotionIsOneEffortScoreOnTheSyntheticScale() {
        let (s, out) = source()
        let start = clock.uptime
        shake(s, g: 0.6, from: 0, to: 2.05, start: start)       // seconds 0 and 1 close; 2 is filling
        let samples = out()
        XCTAssertEqual(samples.map(\.timestamp), [1, 2])
        let expected = s.config.effort(rms: 0.6)
        XCTAssertEqual(samples[0].motion ?? 0, expected, accuracy: 0.5)
        XCTAssertEqual(samples[0].source, .phone)
        XCTAssertNil(samples[0].heartRate)
        // Same scale as the synthetic motion: race-pace shaking is moderate, a still phone stationary.
        XCTAssertEqual(MotionBand(motion: expected), .moderate)
        XCTAssertEqual(MotionBand(motion: s.config.effort(rms: 0.01)), .stationary)
        XCTAssertEqual(s.config.effort(rms: 5), 100)
    }

    func testThinSecondsAreNotScoredAndBadReadingsAreDropped() {
        let (s, out) = source()
        let start = clock.uptime
        // Three readings in second 0: too few to score.
        for i in 0..<3 {
            clock.uptime = start + Double(i) * 0.3
            s.receive(DeviceMotionReading(timestamp: start + Double(i) * 0.3, x: 0.5, y: 0, z: 0))
        }
        clock.uptime = start + 1.1
        s.receive(DeviceMotionReading(timestamp: start + 1.05, x: 0.5, y: 0, z: 0))
        XCTAssertTrue(out().isEmpty)

        s.receive(DeviceMotionReading(timestamp: start + 1.06, x: .nan, y: 0, z: 0))
        XCTAssertEqual(s.dropped.invalid, 1)
        s.receive(DeviceMotionReading(timestamp: start - 20, x: 0.5, y: 0, z: 0))      // stale on arrival
        s.receive(DeviceMotionReading(timestamp: start + 1.0, x: 0.5, y: 0, z: 0))     // older than the last
        XCTAssertEqual(s.dropped.stale, 2)
    }

    func testPedometerCadence() {
        let (s, out) = source()
        clock.uptime += 10
        s.receive(PedometerReading(endDate: clock.now.addingTimeInterval(-1), cadence: 2.9))   // steps a second
        XCTAssertEqual(out().last?.cadence, 174)
        XCTAssertEqual(out().last?.timestamp ?? 0, 9, accuracy: 1e-6)
        XCTAssertEqual(out().last?.source, .phone)

        s.receive(PedometerReading(endDate: clock.now, cadence: nil))
        XCTAssertEqual(out().count, 1, "no cadence in the update: nothing sent")
        s.receive(PedometerReading(endDate: clock.now, cadence: -1))
        s.receive(PedometerReading(endDate: clock.now, cadence: .nan))
        s.receive(PedometerReading(endDate: clock.now, cadence: 9))                            // 540 spm
        XCTAssertEqual(s.dropped.invalid, 3)
        s.receive(PedometerReading(endDate: clock.now.addingTimeInterval(-30), cadence: 2.9))
        XCTAssertEqual(s.dropped.stale, 1)
    }

    func testBarometricAltitude() {
        let (s, out) = source()
        let start = clock.uptime
        clock.uptime += 4
        s.receive(AltimeterReading(timestamp: start + 3.5, relativeAltitude: 2.25))
        XCTAssertEqual(out().last?.altitude, 2.25)
        XCTAssertEqual(out().last?.timestamp ?? 0, 3.5, accuracy: 1e-6)
        XCTAssertNil(out().last?.motion)
        s.receive(AltimeterReading(timestamp: start + 3.8, relativeAltitude: .nan))
        XCTAssertEqual(s.dropped.invalid, 1)
        s.receive(AltimeterReading(timestamp: start - 30, relativeAltitude: 1))
        XCTAssertEqual(s.dropped.stale, 1)
    }

    func testStartRunsWhatThePhoneHasAndAPhoneWithoutSensorsSendsNothing() {
        let fakes = FakeSensors()
        let (s, _) = source(fakes)
        s.start()
        XCTAssertTrue(fakes.motion.isRunning)
        XCTAssertEqual(fakes.motion.interval ?? 0, 1.0 / 50, accuracy: 1e-9)
        XCTAssertTrue(fakes.pedometer.isRunning)
        XCTAssertTrue(fakes.altimeter.isRunning)
        s.stop()
        XCTAssertFalse(fakes.motion.isRunning || fakes.pedometer.isRunning || fakes.altimeter.isRunning)

        // The simulator: no motion sensors at all.
        let none = FakeSensors(motionAvailable: false)
        let (bare, out) = source(none)
        XCTAssertFalse(bare.availability.any)
        bare.start()
        XCTAssertFalse(none.motion.isRunning || none.pedometer.isRunning || none.altimeter.isRunning)
        XCTAssertTrue(out().isEmpty)
    }
}

final class AppInfoTests: XCTestCase {
    /// The app asks for location while in use, explains motion, and may keep
    /// location running with the screen locked.
    func testUsageStringsAndBackgroundLocation() {
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertFalse((info["NSLocationWhenInUseUsageDescription"] as? String ?? "").isEmpty)
        XCTAssertTrue((info["NSMotionUsageDescription"] as? String ?? "").contains("cadence"))
        XCTAssertEqual(info["UIBackgroundModes"] as? [String], ["location", "workout-processing"])
        XCTAssertTrue(SystemLocationProvider.hasBackgroundLocationMode)
    }
}
