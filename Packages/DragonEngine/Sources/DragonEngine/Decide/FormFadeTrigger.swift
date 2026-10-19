//  FormFadeTrigger.swift
//  Form going: in the last third of the race, cadence more than 5% under the
//  runner's own earlier baseline while heart rate is drifting up, held for
//  30 s. It is Info and shown on a glance (design: "On a glance"): while it is
//  on, the next glance is answered with it ("CADENCE -6% · SHORTEN STRIDE")
//  instead of the status, once per episode. It clears when cadence is back
//  within 3% of the baseline (recovered), and can then come on again.
//
//      baseline  mean cadence while the runner covered 10–50% of the distance
//                (settled, before any fatigue)
//      now       mean cadence over the last 60 s
//      drop      1 − now / baseline (0.05 = 5% fewer steps a minute)
//      drift     RunState.heartDrift: bpm gained over 5 min at a steady pace
//
//  Unknown cadence (no fresh pedometer or Watch reading) neither starts nor
//  clears it. Heart rate drift is only needed to start it.

import Foundation

public struct FormFadeTrigger: Trigger {
    public struct Config: Sendable, Equatable {
        /// Fraction cadence must be under the baseline to start, and back within to clear.
        public var startDrop = 0.05
        public var clearDrop = 0.03
        /// bpm per 5 minutes of drift (RunState.heartDrift) needed to start.
        public var minDrift = 2.0
        /// Seconds the condition must hold before it comes on.
        public var hold: TimeInterval = 30
        /// Fraction of the distance from which it may come on (the last third).
        public var from = 2.0 / 3
        /// Fractions of the distance that make the baseline, and readings it needs.
        public var baselineFrom = 0.1
        public var baselineTo = 0.5
        public var baselineMinReadings = 60
        /// Seconds of cadence averaged into "now".
        public var window: TimeInterval = 60
        /// Words for the advice.
        public var advice = "SHORTEN STRIDE"
        public var priority: Priority = .info
        /// Seconds the cue stays up once a glance brings it (design: 3 s).
        public var minShow: TimeInterval = 3
        /// A glance's answer shows then or not at all.
        public var expiresAfter: TimeInterval = 1.5

        public init() {}
    }

    public let plan: RunPlan
    public let config: Config
    public private(set) var hysteresis: Hysteresis
    /// Cadence drop as of the last evaluate (0.04 = 4% under the baseline); nil until known.
    public private(set) var drop: Double?
    /// Mean cadence over the baseline stretch, once it has enough readings.
    public var baseline: Double? {
        baselineCount >= config.baselineMinReadings ? baselineSum / Double(baselineCount) : nil
    }
    /// The current episode's cue has been shown on a glance.
    public private(set) var answered = false
    private var baselineSum = 0.0
    private var baselineCount = 0
    private var recent: [(t: TimeInterval, cadence: Double)] = []

    public init(plan: RunPlan, config: Config = Config()) {
        self.plan = plan
        self.config = config
        hysteresis = Hysteresis(start: config.startDrop, clear: config.clearDrop, hold: config.hold)
    }

    /// On, and its cue not yet shown this episode: the next glance gets it.
    public var wantsGlance: Bool { hysteresis.isOn && !answered }

    public mutating func evaluate(state s: RunState, at t: TimeInterval) -> [Cue] {
        let progress = s.distance / plan.distanceMeters
        if let c = s.cadence {
            if progress >= config.baselineFrom && progress < config.baselineTo {
                baselineSum += c
                baselineCount += 1
            }
            recent.append((t, c))
        }
        recent.removeAll { t - $0.t > config.window }
        if let base = baseline, !recent.isEmpty, s.cadence != nil {
            drop = 1 - recent.reduce(0) { $0 + $1.cadence } / Double(recent.count) / base
        } else {
            drop = nil
        }
        guard let drop else {
            _ = hysteresis.update(starting: false, clearing: false, at: t)
            return []
        }
        let starting = progress >= config.from && drop > config.startDrop
            && (s.heartDrift ?? -.infinity) >= config.minDrift
        if hysteresis.update(starting: starting, clearing: drop < config.clearDrop, at: t) != nil {
            answered = false
        }
        return []
    }

    /// The answer to a glance while form is fading, once per episode; nil otherwise.
    public mutating func answer(_ event: AttentionEvent, at t: TimeInterval) -> Cue? {
        guard event == .glance, wantsGlance, let drop else { return nil }
        answered = true
        return Cue(key: .formFade,
                   priority: config.priority,
                   reveal: .glance,
                   content: CueContent(main: .label("CADENCE -\(Int((drop * 100).rounded()))%"),
                                       subtitle: [.label(config.advice)],
                                       tag: "FORM",
                                       icon: .gauge),
                   createdAt: t,
                   expiresAt: t + config.expiresAfter,
                   minShow: config.minShow)
    }
}
