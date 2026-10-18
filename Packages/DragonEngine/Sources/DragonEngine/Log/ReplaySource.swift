//  ReplaySource.swift
//  Plays a RunRecording back. Steppable, like the synthetic generators: the
//  caller advances it by run-time seconds (multiply by a speed for 10x, or
//  jump straight to a time), and it hands back every input that falls in
//  that step, in time order.
//
//  It also exposes the recording as ordinary sources (`location`, `vitals`,
//  `attention`), so code written against LocationSource / VitalsSource /
//  AttentionSource can't tell a replay from the live thing. Each one only
//  delivers while started.

import Foundation

public final class ReplaySource {
    public let recording: RunRecording
    /// Run time reached so far.
    public private(set) var time: TimeInterval = 0

    public let location = LocationFeed()
    public let vitals = VitalsFeed()
    public let attention = AttentionFeed()

    private var cursor = RunRecording.Cursor()

    public init(_ recording: RunRecording) {
        self.recording = recording
    }

    /// True once every input has been played.
    public var isFinished: Bool {
        cursor.location >= recording.locations.count
            && cursor.vitals >= recording.vitals.count
            && cursor.attention >= recording.attention.count
    }

    /// Advances run time by dt seconds; returns the inputs in that step.
    @discardableResult
    public func advance(by dt: TimeInterval) -> [RunEvent] {
        samples(until: time + dt)
    }

    /// Advances run time to `t` (never backwards); returns the inputs up to and including t.
    @discardableResult
    public func samples(until t: TimeInterval) -> [RunEvent] {
        var out: [RunEvent] = []
        time = max(time, t)
        cursor.drain(recording, through: time) { event in
            out.append(event)
            switch event {
            case .location(let s): location.deliver(s)
            case .vitals(let s): vitals.deliver(s)
            case .attention(let s): attention.deliver(s.event)
            }
        }
        return out
    }

    /// Back to the start of the recording.
    public func reset() {
        time = 0
        cursor = RunRecording.Cursor()
    }

    // MARK: Feeds

    public final class LocationFeed: LocationSource {
        public var onSample: ((LocationSample) -> Void)?
        public private(set) var isStarted = false
        public func start() { isStarted = true }
        public func stop() { isStarted = false }
        func deliver(_ s: LocationSample) { if isStarted { onSample?(s) } }
    }

    public final class VitalsFeed: VitalsSource {
        public var onSample: ((VitalsSample) -> Void)?
        public private(set) var isStarted = false
        public func start() { isStarted = true }
        public func stop() { isStarted = false }
        func deliver(_ s: VitalsSample) { if isStarted { onSample?(s) } }
    }

    public final class AttentionFeed: AttentionSource {
        public var onEvent: ((AttentionEvent) -> Void)?
        public private(set) var isStarted = false
        public func start() { isStarted = true }
        public func stop() { isStarted = false }
        func deliver(_ e: AttentionEvent) { if isStarted { onEvent?(e) } }
    }
}
