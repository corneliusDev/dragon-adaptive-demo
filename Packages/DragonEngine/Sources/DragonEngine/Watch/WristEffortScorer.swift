//  WristEffortScorer.swift
//  The Watch's wrist motion summarised to the 0–100 effort score the engine
//  uses for every motion stream (MotionBand: light from 6, moderate from 38,
//  hard from 72), once a second. The Watch feeds it user acceleration
//  (gravity removed, in g) at 50 Hz; each whole second of readings gives one
//  score: the RMS of the acceleration, placed linearly between an arm barely
//  moving and an all-out sprint's arm swing. A second with too few readings
//  in it (the sensor stalled) isn't scored.
//
//  Pure: the caller passes each reading's own timestamp (any clock, seconds),
//  and gets the score with the time its second ended.

import Foundation

public struct WristEffortScorer: Sendable {
    public struct Config: Sendable, Equatable {
        /// Seconds of motion per score.
        public var window: TimeInterval = 1
        /// A window with fewer readings than this isn't scored (50 Hz gives 50).
        public var minReadingsPerWindow = 10
        /// RMS user acceleration (g) that scores 0: an arm hanging still on a moving body.
        public var restingAcceleration = 0.05
        /// RMS user acceleration (g) that scores 100: a sprint's arm swing.
        /// Race pace lands around 0.8–1.3 g at the wrist. To tune in the field.
        public var fullEffortAcceleration = 2.0

        public init(window: TimeInterval = 1, minReadingsPerWindow: Int = 10,
                    restingAcceleration: Double = 0.05, fullEffortAcceleration: Double = 2.0) {
            self.window = window
            self.minReadingsPerWindow = minReadingsPerWindow
            self.restingAcceleration = restingAcceleration
            self.fullEffortAcceleration = fullEffortAcceleration
        }

        /// Effort score (0–100) for an RMS user acceleration in g.
        public func effort(rms: Double) -> Double {
            let span = fullEffortAcceleration - restingAcceleration
            guard span > 0, rms.isFinite else { return 0 }
            return Swift.min(100, Swift.max(0, (rms - restingAcceleration) / span * 100))
        }
    }

    public struct Score: Sendable, Equatable {
        /// End of the window the score covers (the readings' clock).
        public var t: TimeInterval
        public var effort: Double
    }

    public let config: Config
    /// The window being filled: its index (t ÷ window), Σa², count.
    private var current: (index: Int, sumSquares: Double, count: Int)?

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Adds one reading; returns the previous window's score when this
    /// reading starts a new window (and the previous one had enough readings).
    public mutating func add(t: TimeInterval, x: Double, y: Double, z: Double) -> Score? {
        let a2 = x * x + y * y + z * z
        guard a2.isFinite, t.isFinite, config.window > 0 else { return nil }
        let index = Int((t / config.window).rounded(.down))
        guard var w = current else {
            current = (index, a2, 1)
            return nil
        }
        if index == w.index {
            w.sumSquares += a2
            w.count += 1
            current = w
            return nil
        }
        guard index > w.index else { return nil }   // a reading from an earlier window: ignore
        current = (index, a2, 1)
        guard w.count >= config.minReadingsPerWindow else { return nil }
        let rms = (w.sumSquares / Double(w.count)).squareRoot()
        return Score(t: Double(w.index + 1) * config.window, effort: config.effort(rms: rms))
    }

    /// Forgets the window being filled (the sensor stopped).
    public mutating func reset() {
        current = nil
    }
}
