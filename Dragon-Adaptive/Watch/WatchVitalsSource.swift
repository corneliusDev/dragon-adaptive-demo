//  WatchVitalsSource.swift
//  The Apple Watch as a DragonEngine VitalsSource (source .watch): heart rate
//  from the Watch's workout session and its wrist-motion effort score, as
//  WatchMessages over a WatchTransport (WatchLink in the app, a fake in
//  tests).
//
//  Each message's wall-clock time becomes run time on the phone run's
//  RunTimeline, then WatchMessageFilter decides: duplicates (the same
//  message by both routes) are dropped by sequence, anything not newer than
//  the last applied on its stream is dropped, and readings older than the
//  heart-rate allowance (5 s) when they arrive are dropped as stale. What's
//  left goes to the engine, which keeps chunk 3's rule: Watch heart rate
//  only, missing once 5 s old. So a Bluetooth gap shows up as missing heart
//  rate, and the burst that arrives when the Watch is back in range doesn't
//  paper over it.
//
//  start() listens and asks the Watch to start its workout; pause() stops
//  listening (the run clock is stopped too); stop() ends the Watch workout.
//  When the Watch reports its workout ended, `onEndedRemotely` fires so the
//  run ends as well.

import Foundation
import DragonEngine

/// A heart-rate / effort feed timed by the phone run's timeline: the Watch,
/// or the synthetic stand-in. PhoneSensorRun starts, pauses and stops it
/// with the phone's own sensors.
protocol RunVitalsFeed: VitalsSource {
    /// Set by PhoneSensorRun before start(); nothing is sent without it.
    var timeline: RunTimeline? { get set }
    /// Stops sending for a pause (the run will resume).
    func pause()
    /// "Watch: HR 152, 1.2 s ago": what's coming in, for the live screen.
    var summary: String { get }
    /// The feed's end of the run ended without the phone asking (the Watch workout was ended on the Watch).
    var onEndedRemotely: (() -> Void)? { get set }
}

final class WatchVitalsSource: RunVitalsFeed {
    var onSample: ((VitalsSample) -> Void)?
    var onEndedRemotely: (() -> Void)?
    var timeline: RunTimeline?

    let transport: WatchTransport
    let control: WatchWorkoutControlling?
    let clock: SensorClock
    private(set) var filter: WatchMessageFilter

    /// Messages that couldn't be read (wrong version, garbage), by error.
    private(set) var rejected: [WatchMessageError] = []
    /// The Watch workout's latest state.
    private(set) var sessionState: WatchSessionState?
    /// Latest heart rate applied, and its run time.
    private(set) var lastHeartRate: (bpm: Double, t: TimeInterval)?
    /// Seconds between the latest applied reading being taken and arriving.
    private(set) var lastDelay: TimeInterval?
    /// Messages by route, for the developer menu.
    private(set) var byRoute: [WatchRoute: Int] = [:]
    private(set) var isListening = false
    /// The phone asked the Watch to start; stop() then asks it to end.
    private(set) var workoutRequested = false
    /// The request to start the workout couldn't go out.
    private(set) var startFailed = false

    init(transport: WatchTransport, control: WatchWorkoutControlling?, clock: SensorClock,
         filter: WatchMessageFilter.Config = .init()) {
        self.transport = transport
        self.control = control
        self.clock = clock
        self.filter = WatchMessageFilter(config: filter)
    }

    func start() {
        isListening = true
        transport.onReceive = { [weak self] data, route in self?.receive(data, route: route) }
        guard !workoutRequested else { return }
        workoutRequested = true
        control?.startWorkout { [weak self] ok in self?.startFailed = !ok }
    }

    func pause() {
        isListening = false
    }

    func stop() {
        isListening = false
        transport.onReceive = nil
        if workoutRequested {
            workoutRequested = false
            if sessionState != .ended { control?.endWorkout() }
        }
    }

    /// One message's bytes from the transport.
    func receive(_ data: Data, route: WatchRoute) {
        guard isListening, let timeline else { return }
        let message: WatchMessage
        do {
            message = try WatchMessage.decode(data)
        } catch {
            rejected.append(error as? WatchMessageError ?? .malformed)
            return
        }
        byRoute[route, default: 0] += 1
        let sampleTime = timeline.runTime(date: Date(timeIntervalSince1970: message.at))
        let now = timeline.runTime(on: clock)
        switch filter.accept(message, sampleTime: sampleTime, now: now) {
        case .sample(let s):
            lastDelay = max(0, now - s.timestamp)
            if let bpm = s.heartRate { lastHeartRate = (bpm, s.timestamp) }
            onSample?(s)
        case .state(let state, _):
            let wasEnded = sessionState == .ended
            sessionState = state
            if state == .ended, !wasEnded, workoutRequested {
                workoutRequested = false
                onEndedRemotely?()
            }
        case .command, .dropped:
            break
        }
    }

    var summary: String {
        let now = timeline?.runTime(on: clock) ?? 0
        var parts: [String] = []
        if let hr = lastHeartRate {
            let age = max(0, now - hr.t)
            parts.append(age > SourceSelection.heartRateStaleAfter
                         ? "Watch HR missing (\(Int(age)) s)"
                         : "Watch HR \(Int(hr.bpm.rounded())) · \(String(format: "%.1f", lastDelay ?? 0)) s behind")
        } else if startFailed {
            parts.append("Watch: couldn't start the workout; open Dragon on the Watch")
        } else {
            parts.append(isListening ? "Waiting for the Watch" : "Watch idle")
        }
        if let s = sessionState { parts.append("workout \(s.rawValue)") }
        let c = filter.counts
        if c.received > 0 {
            let dropped = c.dropped.values.reduce(0, +)
            parts.append("\(c.applied) in, \(dropped) dropped")
        }
        return parts.joined(separator: " · ")
    }
}
