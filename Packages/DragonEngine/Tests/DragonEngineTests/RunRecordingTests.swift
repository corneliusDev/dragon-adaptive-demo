//  RunRecordingTests.swift
//  Saving, loading, recording and replaying runs.

import XCTest
import DragonEngine

final class RunRecordingTests: XCTestCase {
    private func shortRace(seed: UInt64 = 1) -> RunRecording {
        syntheticRecording(.hilly, seed: seed, plan: RunPlan(distanceMeters: 3_000, targetTime: 900))
    }

    func testSavedAndLoadedRecordingReplaysIdenticalSamples() throws {
        let original = shortRace()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("race-\(UUID()).json")
        try original.jsonData().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try RunRecording(jsonData: Data(contentsOf: url))
        XCTAssertEqual(loaded, original)
        XCTAssertEqual(loaded.plan?.course, original.plan?.course)
        XCTAssertEqual(replaySamples(loaded, step: 0.5), replaySamples(original, step: 7))
        XCTAssertEqual(try loaded.jsonData(), try original.jsonData())
    }

    func testPlanRoundTripsWithItsPacing() throws {
        let plan = RunPlan(distanceMeters: 10_000, targetTime: 2_700, pacing: .negativeSplit(percent: 2),
                           heartRateZones: HeartRateZones(resting: 50, threshold: 170, max: 188), fuelEvery: 1_800)
        let decoded = try JSONDecoder().decode(RunPlan.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(decoded, plan)
        XCTAssertEqual(decoded.planTime(at: 5_000), plan.planTime(at: 5_000))
    }

    func testReplayIsSteppableAtAnySpeed() {
        let recording = shortRace()
        let replay = ReplaySource(recording)
        var oneX: [RunEvent] = []
        for _ in 0..<200 { oneX += replay.advance(by: 1.0 / 20) }      // 10 s of run time at 1x ticks
        XCTAssertEqual(replay.time, 10, accuracy: 1e-9)
        XCTAssertTrue(oneX.allSatisfy { $0.t <= 10 + 1e-9 })

        let tenX = replay.advance(by: 10.0 / 20 * 200)                 // the next 100 s in one 10x burst
        XCTAssertTrue(tenX.allSatisfy { $0.t > 10 && $0.t <= 110 + 1e-9 })
        XCTAssertEqual(oneX + tenX, recording.events.filter { $0.t <= 110 + 1e-9 })

        replay.samples(until: .infinity)
        XCTAssertTrue(replay.isFinished)
        replay.reset()
        XCTAssertEqual(replay.advance(by: 10), oneX)
    }

    func testRecorderCapturesSourcesAndKeepsExistingHandlers() {
        let original = shortRace()
        let replay = ReplaySource(original)
        let recorder = RunRecorder(name: original.name, plan: original.plan)

        var seenByApp = 0
        replay.vitals.onSample = { _ in seenByApp += 1 }
        recorder.capture(replay.location)
        recorder.capture(replay.vitals)
        replay.location.start()
        replay.vitals.start()

        while !replay.isFinished { replay.advance(by: 0.5) }
        XCTAssertEqual(recorder.recording, original)
        XCTAssertEqual(seenByApp, original.vitals.count)
    }

    func testRecorderTimesAttentionWithTheCallersRunTime() {
        let attention = SimulatedAttentionSource()
        let recorder = RunRecorder()
        var now = 12.5
        recorder.capture(attention) { now }
        attention.fire(.glance)
        now = 20
        attention.fire(.dwell)
        recorder.record(.idle, at: 15)          // late arrival goes in time order

        XCTAssertEqual(recorder.recording.attention.map(\.t), [12.5, 15, 20])
        XCTAssertEqual(recorder.recording.attention.map(\.event), [.glance, .idle, .dwell])
    }

    func testStoppedFeedsDeliverNothing() {
        let replay = ReplaySource(shortRace())
        var got = 0
        replay.location.onSample = { _ in got += 1 }
        replay.advance(by: 30)
        XCTAssertEqual(got, 0)
        replay.location.start()
        replay.advance(by: 30)
        XCTAssertEqual(got, 30)
    }
}
