//  FinishTrigger.swift
//  Across the line: the result for 10 s ("1:44:29 · TARGET MET -0:31"), then
//  the display goes dark (RunEngine draws nothing once the race is over).
//
//  The crossing is noticed on the first state whose distance reaches the
//  plan's, and its time interpolated between that state and the one before,
//  like a split. A crossing noticed by position counts once the estimate has
//  stayed at the line for 5 s (GPS can put the runner over it a few metres
//  early); the caller can say it instead (crossed(at:)), knowing better, and
//  that counts at once. The cue comes on the first evaluate after it counts,
//  once RunEngine has let the finished budget in, so the final stretch's
//  safety-only budget never sees it.

import Foundation

public struct FinishTrigger: Trigger {
    public struct Config: Sendable, Equatable {
        public var priority: Priority = .info
        /// Seconds the result stays up (design: 10 s).
        public var minShow: TimeInterval = 10
        public var expiresAfter: TimeInterval = 30
        /// Seconds a crossing noticed by position must stand before it counts.
        public var confirmAfter: TimeInterval = 5

        public init() {}
    }

    public let plan: RunPlan
    public let config: Config
    /// Run time the runner crossed the line, once they have.
    public private(set) var crossedAt: TimeInterval?
    /// The result has been proposed.
    public private(set) var fired = false
    /// Run time the crossing counts from: the caller's word at once, a noticed one after `confirmAfter`.
    public private(set) var countsFrom: TimeInterval?
    private var last: (t: TimeInterval, d: Double)?

    public init(plan: RunPlan, config: Config = Config()) {
        self.plan = plan
        self.config = config
    }

    /// The runner crossed the line at run time `t` (replaces the noticed time).
    public mutating func crossed(at t: TimeInterval) {
        crossedAt = t
        countsFrom = min(countsFrom ?? t, t)
    }

    /// Whether the runner is over the line as of run time `t`.
    public func isFinished(at t: TimeInterval) -> Bool {
        countsFrom.map { t >= $0 } ?? false
    }

    public mutating func evaluate(state s: RunState, at t: TimeInterval) -> [Cue] {
        defer { last = (t, s.distance) }
        if let finish = crossedAt {
            guard !fired, isFinished(at: t) else { return [] }
            fired = true
            return [cue(finish: finish, at: t)]
        }
        let total = plan.distanceMeters
        guard s.distance >= total else { return [] }
        if let last, last.d < total, s.distance > last.d {
            crossedAt = last.t + (t - last.t) * (total - last.d) / (s.distance - last.d)
        } else {
            crossedAt = t
        }
        countsFrom = t + config.confirmAfter
        return []
    }

    private func cue(finish: TimeInterval, at t: TimeInterval) -> Cue {
        // To the second once, so the time and the margin agree (1:44:29, -0:31).
        let finish = finish.rounded()
        let vs = finish - plan.targetTime
        return Cue(key: .finish,
                   priority: config.priority,
                   reveal: .auto,
                   content: CueContent(main: .duration(finish),
                                       subtitle: [.phrase([.label(vs <= 0 ? "TARGET MET" : "TARGET MISSED"), .gap(vs)])],
                                       tag: "FINISH",
                                       icon: .flag),
                   createdAt: t,
                   expiresAt: t + config.expiresAfter,
                   minShow: config.minShow,
                   planGap: vs)
    }
}
