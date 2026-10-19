//  MovementPhase.swift
//  What the runner's body is doing right now, from the speed series (GPS) and
//  the motion effort score. One input to the capacity budget.
//
//      stopped   5 s speed under 0.8 m/s (or no speed and effort under 6), or
//                before the run has any motion reading and too few fixes for a
//                speed: at the gun, nothing yet says the runner is moving
//      kick      in the last 400 m, with speed or effort rising above what the
//                runner did over the 200 m before it. Two tests, either will do:
//                  level  10 s speed ≥ 5% above, or 3 s effort ≥ 5 points above,
//                         the baseline (a clear, settled rise);
//                  early  the last 4 s mean effort above the baseline by 3.5
//                         standard errors (the baseline's own sample spread
//                         over √n) and by at least 3 points: a rise still well
//                         short of the level test's but already beyond noise,
//                         so a ramp-up is caught sooner after it starts.
//      surging   5 s speed ≥ 15% above the 60 s before the last 10 s: the rise
//                happened within about 10 s. A surge held for longer becomes the
//                new baseline and the phase settles back to steady.
//
//  Speeds are compared as if flat (× GradeModel factor), so cresting a hill and
//  running faster down the other side is not a surge or a kick.
//      climbing  grade under the runner over 3%
//      steady    anything else
//
//  Checked in that order. A pure function of its inputs; the estimator hands it
//  its fixes and motion readings.

import Foundation

public enum MovementPhase: String, Sendable, Equatable, Codable, CaseIterable {
    case stopped, steady, surging, climbing, kick
}

/// One point of the speed series: a good GPS fix.
public struct MovementSample: Sendable, Equatable {
    /// Run time, seconds.
    public var t: TimeInterval
    /// Metres along the course (or integrated) at this fix.
    public var distance: Double
    /// Receiver (Doppler) speed, m/s, when the fix carries one.
    public var speed: Double?
    /// GradeModel pace factor where the fix was taken; speed × this is the flat-equivalent speed.
    public var gradeFactor: Double

    public init(t: TimeInterval, distance: Double, speed: Double?, gradeFactor: Double = 1) {
        self.t = t
        self.distance = distance
        self.speed = speed
        self.gradeFactor = gradeFactor
    }
}

/// One motion effort reading (0–100) from the device effort is taken from.
public struct EffortSample: Sendable, Equatable {
    public var t: TimeInterval
    public var value: Double

    public init(t: TimeInterval, value: Double) {
        self.t = t
        self.value = value
    }
}

public struct MovementPhaseClassifier: Sendable {
    public struct Config: Sendable, Equatable {
        /// m/s; slower than this over `stoppedWindow` is stopped.
        public var stoppedSpeed = 0.8
        public var stoppedWindow: TimeInterval = 5
        /// Effort (0–100) under which a runner with no speed reading counts as
        /// stopped (MotionBand's stationary line).
        public var stoppedEffort = 6.0

        /// Fraction the short-window speed must be above the baseline (0.15 = 15%).
        public var surgeRise = 0.15
        /// Window of "speed now".
        public var surgeWindow: TimeInterval = 5
        /// The baseline ends this long before now: the rise has to happen within it.
        public var surgeLag: TimeInterval = 10
        /// Length of the baseline window. A faster pace held for most of this
        /// becomes the baseline, so a surge lasts at most ~half of it.
        public var surgeBaseline: TimeInterval = 60

        /// Rise over flat, as a fraction (0.03 = 3%), above which the runner is climbing.
        public var climbGrade = 0.03

        /// Metres from the finish where a kick can start.
        public var kickDistance = 400.0
        /// Metres of running before `kickDistance` that set the kick's baseline.
        public var kickBaseline = 200.0
        /// Windows of "speed now" and "effort now" in the kick. Effort reads at
        /// 10 Hz, so a shorter window is as steady as GPS speed over a longer one.
        public var kickSpeedWindow: TimeInterval = 10
        public var kickEffortWindow: TimeInterval = 3
        /// Fraction faster than the baseline that counts as a kick.
        public var kickSpeedRise = 0.05
        /// Effort points above the baseline that count as a kick.
        public var kickEffortRise = 5.0

        /// Early test, on effort only: window of "effort now". GPS speed is no
        /// use here: its error wanders over tens of seconds, so a few seconds'
        /// mean can sit 4–6% off for no reason.
        public var kickEarlyEffortWindow: TimeInterval = 4
        /// Standard errors above the baseline that count as rising.
        public var kickEarlySigmas = 3.5
        /// And never less than this many effort points: a runner's pace (so
        /// effort) drifts by 2+ points on a steady finish. With 3.0, over 65
        /// synthetic races (seeds 1–12 and 42) the early test adds one false kick
        /// (130 m out) and catches the walkthrough's kick about 15 m sooner
        /// (≈ 370 m to go instead of ≈ 355 m). 2.5 catches it a few metres sooner
        /// still, with three times the false kicks.
        public var kickEarlyEffortFloor = 3.0

        public init() {}
    }

    public let config: Config

    public init(config: Config = Config()) {
        self.config = config
    }

    /// The phase at run time `t`.
    /// - speeds: good fixes, oldest first (at least the last couple of minutes).
    /// - efforts: effort readings from one device, oldest first.
    /// - grade: under the runner now, if known.
    /// - distance: metres covered now; `total`: race length, if there is a finish.
    public func phase(at t: TimeInterval, speeds: [MovementSample], efforts: [EffortSample],
                      grade: Double?, distance: Double, total: Double?) -> MovementPhase {
        let c = config
        let now = MovementPhaseClassifier.speed(speeds, from: t - c.stoppedWindow, to: t)
        if let v = now, v < c.stoppedSpeed { return .stopped }
        if now == nil, let e = MovementPhaseClassifier.mean(efforts, from: t - c.stoppedWindow, to: t),
           e < c.stoppedEffort {
            return .stopped
        }
        if now == nil, efforts.isEmpty, speeds.count < 3 { return .stopped }

        if let total, total - distance <= c.kickDistance, isKicking(at: t, speeds: speeds, efforts: efforts, total: total) {
            return .kick
        }

        if let v = MovementPhaseClassifier.speed(speeds, from: t - c.surgeWindow, to: t),
           let base = MovementPhaseClassifier.speed(speeds, from: t - c.surgeLag - c.surgeBaseline, to: t - c.surgeLag),
           base > 0, v >= base * (1 + c.surgeRise) {
            return .surging
        }

        if let g = grade, g > c.climbGrade { return .climbing }
        return .steady
    }

    /// Speed or effort over the last `kickWindow` clearly above the stretch
    /// before the last `kickDistance`.
    private func isKicking(at t: TimeInterval, speeds: [MovementSample], efforts: [EffortSample], total: Double) -> Bool {
        let c = config
        let start = total - c.kickDistance
        // The baseline stretch, by distance (fixes are in time order, distance nearly so).
        let before = Array(speeds.filter { $0.distance >= start - c.kickBaseline && $0.distance < start })
        guard let first = before.first, let last = before.last, last.t > first.t else { return false }

        if let v = MovementPhaseClassifier.speed(speeds, from: t - c.kickSpeedWindow, to: t),
           let base = MovementPhaseClassifier.speed(before, from: first.t - 1, to: last.t),
           base > 0, v >= base * (1 + c.kickSpeedRise) {
            return true
        }
        if let e = MovementPhaseClassifier.mean(efforts, from: t - c.kickEffortWindow, to: t),
           let base = MovementPhaseClassifier.mean(efforts, from: first.t, to: last.t),
           e >= base + c.kickEffortRise {
            return true
        }

        // Early: a small rise that is already beyond the baseline's noise.
        let baseEfforts = MovementPhaseClassifier.window(efforts, from: first.t, to: last.t, t: \.t).map(\.value)
        let nowEfforts = MovementPhaseClassifier.window(efforts, from: t - c.kickEarlyEffortWindow, to: t, t: \.t)
            .map(\.value)
        if MovementPhaseClassifier.isAbove(nowEfforts, baseline: baseEfforts, sigmas: c.kickEarlySigmas,
                                           floor: { _ in c.kickEarlyEffortFloor }) {
            return true
        }
        return false
    }

    /// The mean of `now` is above the mean of `baseline` by at least `sigmas`
    /// standard errors (baseline sample spread ÷ √count of `now`) and by at
    /// least `floor(baseline mean)`. Needs 3 values in `now` and 10 in the baseline.
    static func isAbove(_ now: [Double], baseline: [Double], sigmas: Double, floor: (Double) -> Double) -> Bool {
        guard now.count >= 3, baseline.count >= 10 else { return false }
        let base = baseline.reduce(0, +) / Double(baseline.count)
        let variance = baseline.reduce(0) { $0 + ($1 - base) * ($1 - base) } / Double(baseline.count - 1)
        let mean = now.reduce(0, +) / Double(now.count)
        let margin = max(floor(base), sigmas * variance.squareRoot() / Double(now.count).squareRoot())
        return mean >= base + margin
    }

    /// Flat-equivalent speed over the samples in (from, to]: mean Doppler speed
    /// when most fixes carry it, else the least-squares slope of distance on
    /// time; times the mean grade factor. Needs at least 3 samples spanning half the window.
    static func speed(_ samples: [MovementSample], from: TimeInterval, to: TimeInterval) -> Double? {
        let w = window(samples, from: from, to: to, t: \.t)
        guard w.count >= 3, let first = w.first, let last = w.last, last.t - first.t >= (to - from) / 2 else { return nil }
        let doppler = w.compactMap { s in s.speed.map { $0 * s.gradeFactor } }
        if Double(doppler.count) >= 0.8 * Double(w.count) {
            return doppler.reduce(0, +) / Double(doppler.count)
        }
        let factor = w.reduce(0) { $0 + $1.gradeFactor } / Double(w.count)
        return StateEstimator.slope(w.map { ($0.t, $0.distance) }).map { $0 * factor }
    }

    /// Mean effort over (from, to]; nil with no readings in it.
    static func mean(_ samples: [EffortSample], from: TimeInterval, to: TimeInterval) -> Double? {
        let w = window(samples, from: from, to: to, t: \.t)
        return w.isEmpty ? nil : w.reduce(0) { $0 + $1.value } / Double(w.count)
    }

    /// The samples with from < t ≤ to, found by binary search (samples are in time order).
    static func window<S>(_ samples: [S], from: TimeInterval, to: TimeInterval,
                          t: KeyPath<S, TimeInterval>) -> ArraySlice<S> {
        func firstIndex(after x: TimeInterval) -> Int {
            var lo = 0, hi = samples.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if samples[mid][keyPath: t] <= x { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
        let a = firstIndex(after: from), b = firstIndex(after: to)
        return a < b ? samples[a..<b] : []
    }
}
