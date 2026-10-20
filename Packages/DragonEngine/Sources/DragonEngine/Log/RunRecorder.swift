//  RunRecorder.swift
//  Captures inputs into a RunRecording, from any source: hook it onto a
//  LocationSource / VitalsSource / AttentionSource (it chains, so whatever
//  handler the source already had keeps getting samples), or feed it directly.
//  Attention events carry no time, so capturing them takes a run-time closure
//  owned by the caller; the recorder itself never reads the clock.

import Foundation

public final class RunRecorder {
    public private(set) var recording: RunRecording

    /// `unit` / `display`: the engine settings, noted for replays.
    public init(name: String = "", plan: RunPlan? = nil, unit: DistanceUnit? = nil, display: DisplaySetting? = nil) {
        recording = RunRecording(name: name, plan: plan, unit: unit, display: display)
    }

    // MARK: Direct

    // Samples normally arrive in time order; an out-of-order one is inserted in place.
    public func record(_ sample: LocationSample) {
        insert(sample, into: &recording.locations, t: \.t)
    }

    public func record(_ sample: VitalsSample) {
        insert(sample, into: &recording.vitals, t: \.timestamp)
    }

    public func record(_ event: AttentionEvent, at t: TimeInterval) {
        insert(AttentionSample(t: t, event: event), into: &recording.attention, t: \.t)
    }

    public func record(_ event: RunEvent) {
        switch event {
        case .location(let s): record(s)
        case .vitals(let s): record(s)
        case .attention(let s): record(s.event, at: s.t)
        }
    }

    /// Notes the update grid a RunPacer ran the engine on (every `step`
    /// seconds of run time through `endedAt`), so a replay can repeat it.
    public func noteUpdates(step: TimeInterval, through endedAt: TimeInterval) {
        recording.updateStep = step
        recording.endedAt = endedAt
    }

    // MARK: Capturing sources

    public func capture(_ source: LocationSource) {
        let previous = source.onSample
        source.onSample = { [weak self] sample in
            self?.record(sample)
            previous?(sample)
        }
    }

    public func capture(_ source: VitalsSource) {
        let previous = source.onSample
        source.onSample = { [weak self] sample in
            self?.record(sample)
            previous?(sample)
        }
    }

    /// `time` returns the current run time; called once per event.
    public func capture(_ source: AttentionSource, time: @escaping () -> TimeInterval) {
        let previous = source.onEvent
        source.onEvent = { [weak self] event in
            self?.record(event, at: time())
            previous?(event)
        }
    }

    private func insert<S>(_ s: S, into list: inout [S], t: KeyPath<S, TimeInterval>) {
        if let last = list.last, last[keyPath: t] > s[keyPath: t] {
            let i = list.lastIndex { $0[keyPath: t] <= s[keyPath: t] }.map { $0 + 1 } ?? 0
            list.insert(s, at: i)
        } else {
            list.append(s)
        }
    }
}
