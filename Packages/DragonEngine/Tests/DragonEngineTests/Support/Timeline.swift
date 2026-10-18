//  Timeline.swift
//  Test support for replaying recorded or synthetic runs:
//
//      let recording = syntheticRecording(.hilly, seed: 3)
//      for event in replaySamples(recording) { ... }          // inputs in time order
//
//      let timeline = replay(recording, scenario: Scenarios.cyclingTri)
//      expect(timeline, at: 13.5, shows: "hr")
//
//  replay(...) drives today's AdaptiveEngine from the recording's vitals and
//  attention; the pipeline engine slots in here without reshaping tests.

import XCTest
import DragonEngine

/// What the engine showed at one run time.
struct TimelineEntry: Equatable {
    let t: TimeInterval
    let activeCardID: String?
    let band: MotionBand
}

/// A whole synthetic race as a recording.
func syntheticRecording(_ profile: SyntheticProfile, seed: UInt64 = 42, plan: RunPlan? = nil) -> RunRecording {
    SyntheticRun.record(profile, seed: seed, plan: plan)
}

/// Every input in the recording, in time order, as a ReplaySource delivers it
/// when stepped at `step` run-time seconds per tick.
func replaySamples(_ recording: RunRecording, step: TimeInterval = 1) -> [RunEvent] {
    let source = ReplaySource(recording)
    var out: [RunEvent] = []
    while !source.isFinished {
        out += source.advance(by: step)
    }
    return out
}

/// Replays a recording through a fresh, running engine at `step` seconds per
/// tick: motion and HR from vitals (HR goes stale after 5 s, like the app),
/// attention events at their run time. One entry per tick.
func replay(_ recording: RunRecording, scenario: Scenario, step: TimeInterval = 1.0 / 20.0) -> [TimelineEntry] {
    guard !recording.isEmpty else { return [] }
    let engine = AdaptiveEngine(scenario: scenario)
    engine.running = true
    let source = ReplaySource(recording)
    var lastHR: (bpm: Double, t: TimeInterval)?
    var timeline: [TimelineEntry] = []
    var t = 0.0

    while !source.isFinished {
        t += step
        for event in source.samples(until: t) {
            switch event {
            case .vitals(let v):
                if let m = v.motion { engine.motion = m }
                if let hr = v.heartRate { lastHR = (hr, v.timestamp) }
            case .attention(let a):
                engine.handle(a.event, at: a.t)
            case .location:
                break
            }
        }
        engine.measuredHeartRate = lastHR.flatMap { t - $0.t < 5 ? Int($0.bpm) : nil }
        _ = engine.tick(dt: step, at: t)
        timeline.append(TimelineEntry(t: t, activeCardID: engine.active?.id, band: engine.band))
    }
    return timeline
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
