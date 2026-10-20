//  PhoneRunTests.swift
//  The phone-sensor run, driven by fakes: permissions are explained before
//  they're asked, a denied location says why and leaves synthetic data
//  usable, and a real run's recording saves, reloads and replays through
//  RunEngine (and through the live screen's replay) with identical decisions.

import XCTest
import CoreLocation
import DragonEngine
@testable import Dragon_Adaptive

final class SensorPermissionsTests: XCTestCase {
    func testEachRequestIsExplainedBeforeTheSystemAsks() {
        let fakes = FakeSensors(location: .notDetermined, motion: .notDetermined)
        let permissions = SensorPermissions(fakes.providers)
        permissions.prepare()
        XCTAssertEqual(permissions.prompt, .location)
        XCTAssertEqual(permissions.explanation, SensorPermissions.locationExplanation)
        XCTAssertEqual(fakes.location.requested, 0, "explained first, not asked yet")

        permissions.allow()
        XCTAssertEqual(fakes.location.requested, 1)
        XCTAssertEqual(permissions.location, .allowed)
        XCTAssertTrue(permissions.canRun)
        XCTAssertEqual(permissions.prompt, .motion)
        XCTAssertEqual(permissions.explanation, SensorPermissions.motionExplanation)
        XCTAssertEqual(fakes.pedometer.requested, 0)

        permissions.allow()
        XCTAssertEqual(fakes.pedometer.requested, 1)
        XCTAssertEqual(permissions.motion, .allowed)
        XCTAssertNil(permissions.prompt)
        XCTAssertNil(permissions.motionNote)
    }

    func testNotNowMovesOnWithoutAsking() {
        let fakes = FakeSensors(location: .allowed, motion: .notDetermined)
        let permissions = SensorPermissions(fakes.providers)
        permissions.prepare()
        XCTAssertEqual(permissions.prompt, .motion)
        permissions.skip()
        XCTAssertNil(permissions.prompt)
        XCTAssertEqual(fakes.pedometer.requested, 0)
        XCTAssertTrue(permissions.canRun, "motion is optional")
        XCTAssertNotNil(permissions.motionNote)
    }

    func testNoMotionSensorsMeansGPSOnlyAndNoMotionRequest() {
        let fakes = FakeSensors(location: .allowed, motionAvailable: false)
        let permissions = SensorPermissions(fakes.providers)
        permissions.prepare()
        XCTAssertEqual(permissions.motion, .unavailable)
        XCTAssertNil(permissions.prompt)
        XCTAssertTrue(permissions.motionNote?.contains("GPS only") ?? false)
    }

    /// The acceptance: location denied shows the explanation, the phone run
    /// won't start, and synthetic data still runs.
    func testDeniedLocationExplainsAndSyntheticStillRuns() {
        let env = AppEnvironment.temporary()
        env.runSource.source = .phone
        let fakes = FakeSensors(location: .denied)
        let setup = LiveRunSetup(environment: env, sensors: { fakes.run() })

        let phone = setup.model(for: SampleData.parkFiveK)
        XCTAssertEqual(phone.kind, .phone)
        let permissions = try! XCTUnwrap(phone.permissions)
        permissions.prepare()
        XCTAssertNil(permissions.prompt, "nothing left to ask: the system already said no")
        XCTAssertFalse(permissions.canRun)
        let problem = try! XCTUnwrap(permissions.locationProblem)
        XCTAssertTrue(problem.contains("Settings"), problem)
        XCTAssertTrue(problem.contains("synthetic"), problem)

        phone.start(timer: false)
        XCTAssertFalse(phone.hasStarted, "no location: the real run doesn't start")
        XCTAssertTrue(fakes.location.started.isEmpty)

        // "Use synthetic": a race that runs, and the choice is remembered.
        let synthetic = setup.switchSource(of: phone, to: .synthetic, timer: false)
        XCTAssertEqual(synthetic.kind, .synthetic)
        XCTAssertEqual(env.runSource.source, .synthetic)
        XCTAssertTrue(synthetic.hasStarted)
        synthetic.speed = 10
        synthetic.advance(realSeconds: 6)
        XCTAssertGreaterThan(synthetic.state?.distance ?? 0, 100)
        XCTAssertEqual(setup.model(for: SampleData.parkFiveK).kind, .synthetic)
    }
}

final class PhoneRunRecordingTests: XCTestCase {
    /// A mile on the synthetic course (as if from a GPX file).
    private var plan: SavedPlan {
        let base = RunPlan(distanceMeters: 1_609, targetTime: 480)
        return SavedPlan(name: "Track mile", preset: .custom, distanceMeters: 1_609, unit: .miles, targetTime: 480,
                         pacing: .even, course: SyntheticRun(profile: .onPlan, seed: 11, plan: base).plan.course,
                         courseFileName: "mile.gpx", zones: nil, fuelEvery: nil, display: .balanced)
    }

    /// The model's state 5 minutes in.
    private var midRun: RunState?

    /// Plays a synthetic runner through the fakes as the phone would see it:
    /// GPS fixes arriving 0.7 s after they're taken, 50 Hz motion, the
    /// pedometer every 2 s, the barometer every second, and a 30 s pause.
    private func runOnFakes(_ model: LiveRunModel, _ fakes: FakeSensors) {
        var run = SyntheticRun(profile: .onPlan, seed: 11, plan: plan.runPlan)
        let clock = fakes.clock
        let start = clock.uptime
        var paused: TimeInterval = 0
        var pending: [RunEvent] = []
        var runClock = 0.0
        var nextMotion = 0.0, nextAltitude = 0.0
        model.start(timer: false)
        XCTAssertTrue(model.hasStarted)
        while runClock < plan.targetTime + 60 {
            runClock += 0.05
            clock.uptime = start + runClock + paused
            if !run.isFinished { pending += run.advance(by: 0.05) }
            // Fixes and cadence arrive 0.7 s late.
            while let e = pending.first, e.t <= runClock - 0.7 {
                pending.removeFirst()
                let taken = clock.date(uptime: start + e.t + paused)
                switch e {
                case .location(let s):
                    fakes.location.deliver([.fix(s.latitude, s.longitude, at: taken, accuracy: s.horizontalAccuracy,
                                                 speed: s.speed ?? -1, altitude: 30 + e.t * 0.01)])
                case .vitals(let v):
                    if let c = v.cadence { fakes.pedometer.deliver(PedometerReading(endDate: taken, cadence: c / 60)) }
                case .attention:
                    break
                }
            }
            while nextMotion <= runClock {
                let g = 0.7 + 0.05 * sin(nextMotion * 9)
                fakes.motion.deliver(DeviceMotionReading(timestamp: start + nextMotion + paused, x: g, y: 0, z: 0))
                nextMotion += 0.02
            }
            while nextAltitude <= runClock {
                fakes.altimeter.deliver(AltimeterReading(timestamp: start + nextAltitude + paused,
                                                         relativeAltitude: nextAltitude * 0.01))
                nextAltitude += 1
            }
            model.advance(realSeconds: 0.05)
            if abs(runClock - 300) < 0.025 { midRun = model.state }
            if abs(runClock - 200) < 0.025 {
                // A 30 s stop at a crossing: paused, then resumed.
                model.pause()
                XCTAssertFalse(fakes.location.isUpdating)
                paused += 30
                clock.uptime = start + runClock + paused
                model.resume(timer: false)
                XCTAssertTrue(fakes.location.isUpdating)
            }
        }
    }

    /// The acceptance: a recording made from the phone-sensor path saves,
    /// reloads and replays through RunEngine with identical decisions.
    func testPhoneRunRecordsAndReplaysWithIdenticalDecisions() throws {
        let env = AppEnvironment.temporary()
        let fakes = FakeSensors()
        let model = LiveRunModel(plan: plan, feed: .phone(fakes.run()))
        var frames = 0
        model.onFrame = { _ in frames += 1 }
        runOnFakes(model, fakes)

        XCTAssertEqual(fakes.location.started, [true, true], "started, then resumed after the pause")
        XCTAssertGreaterThan(frames, 0)
        XCTAssertTrue(model.isFinished, "the mile is run: \(model.state?.distance ?? 0) m")
        XCTAssertEqual(model.state?.distance ?? 0, 1_609, accuracy: 40)
        XCTAssertEqual(model.finishTime ?? 0, 480, accuracy: 30, "the pause isn't run time")
        XCTAssertEqual(midRun?.quality.effortSource, .phone, "effort from the phone's motion")
        XCTAssertEqual(midRun?.effort, .moderate)
        XCTAssertEqual(midRun?.cadence ?? 0, 172, accuracy: 6)
        XCTAssertEqual(midRun?.quality.cadenceSource, .phone)
        XCTAssertGreaterThan(model.engine.log.appearances.count, 0)
        XCTAssertTrue(model.sensorText?.hasPrefix("GPS ±") ?? false, model.sensorText ?? "")

        let record = try model.end(store: env.runs)
        XCTAssertEqual(record.source, "Phone sensors")
        let file = try XCTUnwrap(record.recordingFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.runs.recordings.appendingPathComponent(file).path))
        XCTAssertEqual(env.runs.recorded().map(\.id), [record.id])
        // The review offers the recording for sharing (to replay it with swift test).
        XCTAssertEqual(try ReviewModel(record: record, store: env.runs).recordingURL?.lastPathComponent, file)
        XCTAssertEqual(file, (record.cueLogFile as NSString).deletingPathExtension + ".json", "named like its cue log")

        // Reloaded from disk...
        let reloaded = try XCTUnwrap(env.runs.record(record.id))
        let recording = try XCTUnwrap(env.runs.recording(for: reloaded))
        XCTAssertEqual(recording, model.recorder?.recording)
        XCTAssertFalse(recording.locations.isEmpty)
        XCTAssertTrue(recording.vitals.contains { $0.motion != nil })
        XCTAssertTrue(recording.vitals.contains { $0.cadence != nil })
        XCTAssertTrue(recording.vitals.contains { $0.altitude != nil })
        XCTAssertEqual(recording.endedAt, model.raceTime)

        // ...replayed through RunEngine: the same decisions, cue for cue.
        let replayed = RunEngine.replay(recording, plan: reloaded.plan.runPlan,
                                        config: LiveRunModel.engineConfig(for: reloaded.plan))
        XCTAssertEqual(replayed.log, model.engine.log)
        // The recording alone (as `swift test` gets it from the field) sets the engine up the same way.
        XCTAssertEqual(RunEngine.replay(recording).log, model.engine.log)
        XCTAssertEqual(try env.runs.log(for: reloaded).events, model.engine.log.events)

        // ...and through the live screen's replay (Developer menu), at 10x.
        let replay = try XCTUnwrap(LiveRunSetup(environment: env).replay(reloaded, store: env.runs))
        XCTAssertEqual(replay.kind, .replay)
        replay.start(timer: false)
        replay.speed = 10
        while replay.isRunning { replay.advance(realSeconds: 0.5) }
        XCTAssertEqual(replay.engine.log, model.engine.log)
        XCTAssertEqual(replay.raceTime, model.raceTime, accuracy: 1e-9)
    }

    /// The simulator: GPS but no motion sensors. The run goes on GPS alone.
    func testAPhoneWithoutMotionSensorsRunsOnGPS() {
        let fakes = FakeSensors(motionAvailable: false)
        let model = LiveRunModel(plan: plan, feed: .phone(fakes.run()))
        model.start(timer: false)
        let clock = fakes.clock
        let start = clock.uptime
        for i in 1...60 {
            clock.uptime = start + Double(i)
            fakes.location.deliver([.fix(51.5 + Double(i) * 3.4 / 111_195, -0.1, at: clock.now.addingTimeInterval(-0.5))])
            model.advance(realSeconds: 1)
        }
        XCTAssertGreaterThan(model.state?.distance ?? 0, 150)
        XCTAssertNil(model.state?.quality.effortSource)
        XCTAssertTrue(model.sensorText?.contains("no motion sensors") ?? false, model.sensorText ?? "")
        XCTAssertTrue(model.recorder?.recording.vitals.isEmpty ?? false)
    }
}
