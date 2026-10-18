//  Timeline.swift
//  Test-support shell for timeline assertions over a replayed run:
//
//      let timeline = replay(recording, scenario: Scenarios.cyclingTri)
//      expect(timeline, at: 13.5, shows: "hr")
//
//  Empty until RunRecording carries inputs; the API is here so later chunks
//  can fill it in without reshaping tests.

import XCTest
import DragonEngine

/// What the engine showed at one run time.
struct TimelineEntry: Equatable {
    let t: TimeInterval
    let activeCardID: String?
    let band: MotionBand
}

/// Replays a recording through a fresh engine at `step` seconds per tick.
/// RunRecording is empty today, so this yields an empty timeline.
func replay(_ recording: RunRecording, scenario: Scenario, step: TimeInterval = 1.0 / 20.0) -> [TimelineEntry] {
    _ = AdaptiveEngine(scenario: scenario)
    return []
}

/// Asserts the card on screen at run time `t` (nil = no card).
func expect(
    _ timeline: [TimelineEntry],
    at t: TimeInterval,
    shows cardID: String?,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard let entry = timeline.last(where: { $0.t <= t }) else {
        XCTFail("timeline has no entry at or before t=\(t)", file: file, line: line)
        return
    }
    XCTAssertEqual(entry.activeCardID, cardID, "at t=\(t)", file: file, line: line)
}
