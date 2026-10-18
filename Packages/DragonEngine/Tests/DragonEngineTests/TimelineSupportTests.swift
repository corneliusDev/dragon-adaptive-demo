//  TimelineSupportTests.swift

import XCTest
import DragonEngine

final class TimelineSupportTests: XCTestCase {
    func testEmptyRecordingReplaysToEmptyTimeline() {
        XCTAssertEqual(replay(RunRecording(), scenario: Scenarios.cyclingTri), [])
    }

    func testRunRecordingRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(RunRecording())
        XCTAssertEqual(try JSONDecoder().decode(RunRecording.self, from: data), RunRecording())
    }

    func testExpectReadsTheLatestEntryAtOrBeforeT() {
        let timeline = [
            TimelineEntry(t: 0, activeCardID: nil, band: .stationary),
            TimelineEntry(t: 13, activeCardID: "hr", band: .moderate),
        ]
        expect(timeline, at: 12.9, shows: nil)
        expect(timeline, at: 13.5, shows: "hr")
    }

    func testReplayDrivesTheEngineFromRecordedInputs() {
        let recording = RunRecording(
            vitals: (1...200).map { VitalsSample(timestamp: Double($0) / 10, heartRate: 150, motion: 50) },
            attention: [AttentionSample(t: 6, event: .glance)])
        let timeline = replay(recording, scenario: Scenarios.cyclingTri)

        expect(timeline, at: 5.9, shows: nil)
        expect(timeline, at: 6.5, shows: "turn")             // glance at t=6 surfaces the window's card
        XCTAssertEqual(timeline.last?.band, .moderate)       // motion 50 from the vitals
        XCTAssertEqual(timeline.last?.t ?? 0, 20, accuracy: 0.1)
    }

    func testSyntheticProfileReplaysInTimeOrder() {
        let recording = syntheticRecording(.onPlan, seed: 1,
                                           plan: RunPlan(distanceMeters: 1_000, targetTime: 300))
        let events = replaySamples(recording)

        XCTAssertEqual(events, recording.events)
        XCTAssertEqual(events.count, recording.locations.count + recording.vitals.count)
        XCTAssertEqual(events.map(\.t), events.map(\.t).sorted())
        XCTAssertTrue(events.contains { if case .location = $0 { return true } else { return false } })
        XCTAssertTrue(events.contains { if case .vitals = $0 { return true } else { return false } })
    }
}
