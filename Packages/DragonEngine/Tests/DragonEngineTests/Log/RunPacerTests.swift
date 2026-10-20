//  RunPacerTests.swift
//  A real run's inputs arrive late and in bursts; the pacer updates the
//  engine on a fixed grid behind the sensors' clock, records what the engine
//  took, and a replay of that recording (saved and loaded) gives the same
//  decisions, cue for cue.

import XCTest
import DragonEngine

final class RunPacerTests: XCTestCase {
    private let plan = RunPlan(distanceMeters: 3_000, targetTime: 900)

    func testUpdatesOnTheGridBehindTheClock() {
        var engine = RunEngine(plan: plan)
        var pacer = RunPacer(config: RunPacer.Config(step: 0.25, lag: 2))
        var times: [TimeInterval] = []
        pacer.advance(to: 1.9, engine: &engine, stepped: { times.append($0.state.elapsed) })
        XCTAssertTrue(times.isEmpty, "nothing is due until the clock is a lag past run time 0")
        pacer.advance(to: 3, engine: &engine, stepped: { times.append($0.state.elapsed) })
        XCTAssertEqual(pacer.updates, 5)                       // 0, 0.25, 0.5, 0.75, 1.0
        XCTAssertEqual(pacer.lastUpdate, 1.0)
    }

    func testLateInputsAreDroppedAndCounted() {
        var engine = RunEngine(plan: plan)
        var pacer = RunPacer(config: RunPacer.Config(step: 0.5, lag: 1))
        let fix = { (t: TimeInterval) in
            RunEvent.location(LocationSample(t: t, latitude: 0, longitude: 0, horizontalAccuracy: 5))
        }
        XCTAssertTrue(pacer.receive(fix(0.4)))
        var ingested: [TimeInterval] = []
        pacer.advance(to: 2, engine: &engine, ingested: { ingested.append($0.t) })   // updates 0, 0.5, 1.0
        XCTAssertEqual(ingested, [0.4])
        XCTAssertFalse(pacer.receive(fix(0.9)), "run time 0.9 was updated at 1.0")
        XCTAssertFalse(pacer.receive(fix(1.0)))
        XCTAssertTrue(pacer.receive(fix(1.1)))
        XCTAssertEqual(pacer.lateDropped, 2)
        XCTAssertEqual(pacer.pending, 1)
    }

    func testOutOfOrderArrivalsAreIngestedInTimeOrder() {
        var engine = RunEngine(plan: plan)
        var pacer = RunPacer(config: RunPacer.Config(step: 1, lag: 0))
        let vitals = RunEvent.vitals(VitalsSample(timestamp: 0.5, heartRate: nil, motion: 40, source: .phone))
        let fixLate = RunEvent.location(LocationSample(t: 0.5, latitude: 0, longitude: 0, horizontalAccuracy: 5))
        let early = RunEvent.vitals(VitalsSample(timestamp: 0.2, heartRate: nil, motion: 30, source: .phone))
        pacer.receive(vitals)
        pacer.receive(fixLate)
        pacer.receive(early)
        var order: [RunEvent] = []
        pacer.advance(to: 1, engine: &engine, ingested: { order.append($0) })
        // Time order; at a tie, location before vitals (as RunRecording merges).
        XCTAssertEqual(order, [early, fixLate, vitals])
    }

    /// The acceptance: a run fed live (late, bursty arrivals), recorded,
    /// saved, loaded and replayed gives identical decisions.
    func testRecordedLiveRunReplaysWithIdenticalDecisions() throws {
        let source = syntheticRecording(.slowFade(from: 1_000), seed: 3, plan: plan)
        let events = source.events
        // Each input arrives 0–2.5 s after it was taken (some after the lag, so
        // dropped), on a fixed scrambled pattern.
        let arrivals = events.enumerated()
            .map { (arrive: $0.element.t + Double(($0.offset * 7_919) % 251) / 100, event: $0.element) }
            .sorted { $0.arrive < $1.arrive }

        var config = RunEngine.Config()
        config.name = "pacer test"
        var engine = RunEngine(plan: plan, config: config)
        var pacer = RunPacer()
        let recorder = RunRecorder(name: "pacer test", plan: plan)
        var liveDecisions: [[Decision]] = []
        var next = 0
        var clock = 0.0
        let end = source.duration + 20
        while clock < end {
            clock += 0.05                                      // the 20 Hz timer
            while next < arrivals.count, arrivals[next].arrive <= clock {
                pacer.receive(arrivals[next].event)
                next += 1
            }
            pacer.advance(to: clock, engine: &engine, ingested: recorder.record,
                          stepped: { liveDecisions.append($0.decisions) })
        }
        recorder.noteUpdates(step: pacer.config.step, through: pacer.lastUpdate ?? 0)
        XCTAssertGreaterThan(pacer.lateDropped, 0, "the test should exercise late inputs")
        XCTAssertGreaterThan(engine.log.appearances.count, 0, "the run should show cues")

        let loaded = try RunRecording(jsonData: recorder.recording.jsonData())
        XCTAssertEqual(loaded, recorder.recording)
        var replayDecisions: [[Decision]] = []
        let replayed = RunEngine.replay(loaded, config: config, stepped: { replayDecisions.append($0.decisions) })
        XCTAssertEqual(replayDecisions.count, liveDecisions.count)
        XCTAssertEqual(replayDecisions, liveDecisions)
        XCTAssertEqual(replayed.log, engine.log)
    }

    func testVitalsAltitudeRoundTripsAndOldSamplesDecode() throws {
        let s = VitalsSample(timestamp: 3, heartRate: nil, motion: nil, altitude: 12.5, source: .phone)
        XCTAssertEqual(try JSONDecoder().decode(VitalsSample.self, from: JSONEncoder().encode(s)), s)
        let old = #"{"timestamp":1,"motion":20,"source":"phone"}"#
        XCTAssertNil(try JSONDecoder().decode(VitalsSample.self, from: Data(old.utf8)).altitude)
        let noAltitude = VitalsSample(timestamp: 1, heartRate: nil, motion: 20, source: .phone)
        let json = String(decoding: try JSONEncoder().encode(noAltitude), as: UTF8.self)
        XCTAssertFalse(json.contains("altitude"), "samples without altitude encode as before")
    }
}
