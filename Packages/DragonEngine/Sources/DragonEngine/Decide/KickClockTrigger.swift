//  KickClockTrigger.swift
//  The last 0.25 mi (402 m): one safety cue with the time left to beat the
//  target ("TO BEAT 1:45:00 · 1:38 · LEFT 0.16 MI"), counting down live
//  (CueText.timeLeft / .distanceLeft) until the line. It is the only cue in
//  the final stretch: the budget there is safety only and the arbiter drops
//  everything else. It stays up until RunEngine withdraws it at the finish;
//  its minimum time and expiry are only a generous bound on the stretch.

import Foundation

public struct KickClockTrigger: Trigger {
    public struct Config: Sendable, Equatable {
        /// Metres before the finish where it comes on (0.25 mi).
        public var distanceLeft = 0.25 * DistanceUnit.metersPerMile
        public var priority: Priority = .safety
        /// The stretch at the plan's pace times this bounds how long it may stay up.
        public var allowance = 3.0

        public init() {}
    }

    public let plan: RunPlan
    public let config: Config
    /// Proposed already (it comes once).
    public private(set) var fired = false

    public init(plan: RunPlan, config: Config = Config()) {
        self.plan = plan
        self.config = config
    }

    public mutating func evaluate(state s: RunState, at t: TimeInterval) -> [Cue] {
        let left = plan.distanceMeters - s.distance
        guard !fired, left <= config.distanceLeft, left > 0 else { return [] }
        fired = true
        let bound = max(60, left * plan.targetPace(at: s.distance) * config.allowance)
        return [Cue(key: .kickClock,
                    priority: config.priority,
                    reveal: .auto,
                    content: CueContent(heading: .phrase([.label("TO BEAT"), .duration(plan.targetTime)]),
                                        main: .timeLeft(until: plan.targetTime),
                                        subtitle: [.phrase([.label("LEFT"), .distanceLeft(to: plan.distanceMeters)])]),
                    createdAt: t,
                    expiresAt: t + bound,
                    minShow: bound)]
    }
}
