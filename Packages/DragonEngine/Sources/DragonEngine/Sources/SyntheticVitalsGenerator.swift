//  SyntheticVitalsGenerator.swift
//  Fake Apple Watch stream for testing without hardware.
//  Shaped like a real watch: HR ~1 Hz and lagging behind effort, motion ~10 Hz,
//  jittered timing, sensor noise, dropped HR readings, and short outages.
//  Seeded RNG, so the same seed replays the same run.
//  Pure and clock-free: the caller drives it with advance(by:). The app wraps it
//  in a run-loop-driven VitalsSource (SyntheticVitalsSource).

import Foundation

public struct SyntheticVitalsGenerator {
    // Tuning
    public var hrTimeConstant: Double = 15     // seconds for HR to close ~63% of the gap to target
    public var restingHR: Double = 95
    public var maxHR: Double = 185
    public var dropoutsEnabled = true

    private let motionInterval = 0.1
    private let hrInterval = 1.0
    private let profilePeriod = 40.0    // matches the scenario loop

    private let seed: UInt64
    private var rng: SeededRNG

    public private(set) var elapsed: Double = 0
    private var hr: Double
    private var nextMotionAt: Double = 0
    private var nextHRAt: Double = 0
    private var outageUntil: Double = -1

    /// HR at elapsed 0; resting unless the run starts already warmed up.
    private let startHR: Double

    public init(seed: UInt64 = 42) {
        self.seed = seed
        self.rng = SeededRNG(seed: seed)
        self.startHR = restingHR
        self.hr = restingHR
    }

    /// A generator tuned for a particular athlete: HR spans restingHR...maxHR
    /// as exertion goes 0...100, starting from `startHR` (resting if nil).
    public init(seed: UInt64, restingHR: Double, maxHR: Double, hrTimeConstant: Double, startHR: Double? = nil) {
        self.seed = seed
        self.rng = SeededRNG(seed: seed)
        self.restingHR = restingHR
        self.maxHR = maxHR
        self.hrTimeConstant = hrTimeConstant
        self.startHR = startHR ?? restingHR
        self.hr = self.startHR
    }

    /// Rewinds to the start of the run; the same seed replays the same samples.
    public mutating func reset() {
        elapsed = 0
        hr = startHR
        nextMotionAt = 0
        nextHRAt = 0
        outageUntil = -1
        rng = SeededRNG(seed: seed)
    }

    /// Target exertion (0–100) at a point in the workout.
    /// Steady effort with surges at 12–20s and 30–38s, lined up with the
    /// scenario's auto and dwell cards.
    public func exertion(at t: Double) -> Double {
        let p = t.truncatingRemainder(dividingBy: profilePeriod)
        var m = 30 + 28 * sin(p / 3.2) + 18 * sin(p / 1.3)

        if p > 12 && p < 20 {
            m += 30
        }

        if p > 30 && p < 38 {
            m += 20
        }

        return max(0, min(100, m))
    }

    /// Advances simulated time by dt seconds and returns whatever the watch
    /// would have sent in that step, or nil if it sent nothing.
    public mutating func advance(by dt: Double) -> VitalsSample? {
        advance(by: dt, exertion: exertion(at: elapsed + dt))
    }

    /// Same as advance(by:), but with the exertion (0–100) at the end of the
    /// step supplied by the caller instead of the built-in 40 s loop. This is
    /// how SyntheticRun drives HR and motion from a runner's pace and grade.
    /// `heartOffset` (bpm) moves the heart rate the effort calls for without
    /// touching motion: cardiac drift, heat, a surge the legs don't show yet.
    public mutating func advance(by dt: Double, exertion effort: Double, heartOffset: Double = 0) -> VitalsSample? {
        elapsed += dt
        let effort = max(0, min(100, effort))

        // HR keeps responding to effort even while the watch isn't sending.
        let target = restingHR + (maxHR - restingHR) * effort / 100 + heartOffset
        hr += (target - hr) * min(1, dt / hrTimeConstant)

        // Roughly one 2–5s outage per minute.
        if dropoutsEnabled, elapsed >= outageUntil, rng.chance(dt / 60) {
            outageUntil = elapsed + rng.uniform(2...5)
        }
        let inOutage = elapsed < outageUntil

        var motion: Double?
        var heartRate: Double?

        if elapsed >= nextMotionAt {
            nextMotionAt = elapsed + motionInterval * rng.uniform(0.7...1.3)
            if !inOutage {
                motion = max(0, min(100, effort + rng.gaussian() * 3))
            }
        }

        if elapsed >= nextHRAt {
            nextHRAt = elapsed + hrInterval * rng.uniform(0.7...1.3)
            let dropped = dropoutsEnabled && rng.chance(0.05)
            if !inOutage, !dropped {
                heartRate = (hr + rng.gaussian() * 1.5).rounded()
            }
        }

        guard motion != nil || heartRate != nil else {
            return nil
        }

        return VitalsSample(timestamp: elapsed, heartRate: heartRate, motion: motion, source: .synthetic)
    }
}
