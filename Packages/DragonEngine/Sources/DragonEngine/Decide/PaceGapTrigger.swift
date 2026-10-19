//  PaceGapTrigger.swift
//  Behind (or ahead of) the target: the projected finish is more than 15 s
//  off it AND the rolling pace is more than 3% off plan the same way, both
//  for 20 s. Clears when the gap is back under 8 s. Needing both keeps it
//  quiet when only one moves: a projection still carrying an early slow mile
//  while pace is back on plan, or a few fast minutes that don't yet change
//  the finish.
//
//  Rolling pace is grade-adjusted when the estimator has it (a climb is not
//  falling behind), else the 60 s pace. While pace is unknown (GPS stale or
//  poor) the start condition is false, so it never fires on bad data; it
//  doesn't clear on bad data either, only on a gap that's back.

import Foundation

public struct PaceGapTrigger: Trigger {
    public struct Config: Sendable, Equatable {
        /// Seconds the projected finish must be off target to start / to stay on.
        public var startGap: TimeInterval = 15
        public var clearGap: TimeInterval = 8
        /// Fraction rolling pace must be off plan (0.03 = 3%), in the gap's direction.
        public var paceOff = 0.03
        /// Seconds both must hold before it fires.
        public var hold: TimeInterval = 20
        /// Units for the pace needed for the rest of the race.
        public var unit: DistanceUnit = .miles
        public var priority: Priority = .critical
        /// Seconds the cue stays up (design: 5 s).
        public var minShow: TimeInterval = 5
        public var expiresAfter: TimeInterval = 30

        public init(unit: DistanceUnit = .miles) {
            self.unit = unit
        }
    }

    public enum Direction: Sendable, Equatable { case behind, ahead }

    public let plan: RunPlan
    public let config: Config
    /// Gap measured as "seconds behind" and "seconds ahead".
    public private(set) var behind: Hysteresis
    public private(set) var ahead: Hysteresis

    /// Which way it is on, if it is.
    public var active: Direction? {
        behind.isOn ? .behind : ahead.isOn ? .ahead : nil
    }

    public init(plan: RunPlan, config: Config = Config()) {
        self.plan = plan
        self.config = config
        behind = Hysteresis(start: config.startGap, clear: config.clearGap, hold: config.hold)
        ahead = behind
    }

    public mutating func evaluate(state: RunState, at t: TimeInterval) -> [Cue] {
        let gap = state.gapToTarget
        let off = paceOff(state)
        var cues: [Cue] = []
        for direction in [Direction.behind, .ahead] {
            let sign = direction == .behind ? 1.0 : -1.0
            let starting = gap.map { $0 * sign > config.startGap } == true
                && off.map { $0 * sign > config.paceOff } == true
            let clearing = gap.map { $0 * sign < config.clearGap } == true
            let change = direction == .behind
                ? behind.update(starting: starting, clearing: clearing, at: t)
                : ahead.update(starting: starting, clearing: clearing, at: t)
            if change == .fired, let gap {
                cues.append(cue(direction, gap: gap, state: state, at: t))
            }
        }
        return cues
    }

    /// Fraction the rolling pace is off plan (+ = slower); nil while pace is unknown.
    private func paceOff(_ s: RunState) -> Double? {
        guard !s.quality.paceUnknown, let pace = s.gradeAdjustedPace ?? s.pace60s else { return nil }
        return pace / plan.targetPace(at: s.distance) - 1
    }

    private func cue(_ direction: Direction, gap: TimeInterval, state s: RunState, at t: TimeInterval) -> Cue {
        var lines: [CueText] = []
        if let finish = s.projectedFinish {
            lines.append(.phrase([.label("FINISH"), .duration(finish)]))
        }
        let left = plan.distanceMeters - s.distance, timeLeft = plan.targetTime - s.elapsed
        if left > 0, timeLeft > 0 {
            lines.append(.phrase([.label("NEED"), .pace(timeLeft / left, config.unit)]))
        }
        return Cue(key: .paceGap,
                   priority: config.priority,
                   reveal: .auto,
                   content: CueContent(heading: .label(direction == .behind ? "BEHIND PLAN" : "AHEAD OF PLAN"),
                                       main: .gap(gap),
                                       subtitle: lines,
                                       icon: direction == .behind ? .warn : .none),
                   createdAt: t,
                   expiresAt: t + config.expiresAfter,
                   minShow: config.minShow,
                   planGap: gap)
    }
}
