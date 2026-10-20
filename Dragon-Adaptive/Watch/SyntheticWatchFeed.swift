//  SyntheticWatchFeed.swift
//  The synthetic Watch for a phone-sensor run: SyntheticVitalsGenerator's
//  heart rate and wrist motion, timed by the run's own clock (its samples
//  carry run time), so a real run can be tried with heart-rate cues and no
//  Watch. Source .synthetic, which plays the Watch's role in the engine.
//  A timer ticks 4 times a second; tests call tick() themselves.

import Foundation
import DragonEngine

final class SyntheticWatchFeed: RunVitalsFeed {
    var onSample: ((VitalsSample) -> Void)?
    var onEndedRemotely: (() -> Void)?
    var timeline: RunTimeline?

    let clock: SensorClock
    private(set) var generator: SyntheticVitalsGenerator
    private(set) var lastHeartRate: Double?
    private var timer: Timer?

    init(clock: SensorClock, seed: UInt64 = 42) {
        self.clock = clock
        generator = SyntheticVitalsGenerator(seed: seed)
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func pause() { stopTimer() }
    func stop() { stopTimer() }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// Brings the generator up to the run's time and sends what it made.
    /// Its elapsed time is run time, so its samples' timestamps are too.
    func tick() {
        guard let timeline else { return }
        let now = timeline.runTime(on: clock)
        while generator.elapsed + 1e-9 < now {
            let dt = min(0.1, now - generator.elapsed)
            if let s = generator.advance(by: dt) {
                if let hr = s.heartRate { lastHeartRate = hr }
                onSample?(s)
            }
        }
    }

    var summary: String {
        lastHeartRate.map { "Synthetic HR \(Int($0.rounded()))" } ?? "Synthetic HR starting"
    }
}
