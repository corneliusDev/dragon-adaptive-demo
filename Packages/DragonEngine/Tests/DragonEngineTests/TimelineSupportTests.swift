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
}
