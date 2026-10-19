//  SplitTrigger.swift
//  A cue at every mile (or kilometre) marker: the split just run and how it
//  compares with the plan's split for the same stretch.
//
//  The crossing time is interpolated between the last state before the
//  marker and the first one past it, so a coarse update rate, or GPS jumping
//  across a marker between two samples, still gives one cue per marker with
//  a sensible split. Markers are counted, never re-fired: distance wandering
//  back over a marker does nothing. The finish line isn't a split.
//  A split needs no reliable GPS: dead-reckoned distance carries it through
//  an outage (the time is then an estimate, but the marker still passed).
//  A marker that falls on one of the course's climbs is deferred to the crest
//  (design: "splits deferred to the crest"): the budget allows only critical
//  cues on a climb, so an advisory split shown there never would. Its expiry
//  is pushed back by the time the rest of the climb takes, so it still shows
//  once the runner is over the top and the budget opens again.

import Foundation

public struct SplitTrigger: Trigger {
    public struct Config: Sendable, Equatable {
        /// Miles or kilometres.
        public var unit: DistanceUnit = .miles
        public var priority: Priority = .advisory
        /// Seconds the split stays up (design: 3 s).
        public var minShow: TimeInterval = 3
        /// A split that can't show within this many seconds is skipped, not shown late.
        public var expiresAfter: TimeInterval = 20
        /// Hold a split that falls on a climb until the crest.
        public var deferOnClimbs = true
        /// The rest of a climb is allowed this many times the plan's pace when
        /// pushing a deferred split's expiry back (runners slow on a climb; 1.5
        /// covers a 6% grade with room). The split then has `expiresAfter` from
        /// the crest, which outlasts the budget's settle after it.
        public var climbPaceAllowance = 1.5

        public init(unit: DistanceUnit = .miles) {
            self.unit = unit
        }
    }

    /// One marker passed.
    public struct Split: Sendable, Equatable {
        /// 1-based marker number.
        public var marker: Int
        public var unit: DistanceUnit
        /// Run time the marker was crossed.
        public var crossedAt: TimeInterval
        /// Seconds since the previous marker (or the start).
        public var time: TimeInterval
        /// The plan's seconds for the same stretch.
        public var planTime: TimeInterval
        /// time − planTime: + = slower than plan.
        public var vsPlan: TimeInterval { time - planTime }
    }

    public let plan: RunPlan
    public let config: Config
    public private(set) var splits: [Split] = []
    /// Furthest point reached so far (run time, metres).
    private var furthest: (t: TimeInterval, d: Double) = (0, 0)
    /// The course's climbs, for deferring splits to the crest.
    private let hills: [Hill]

    public init(plan: RunPlan, config: Config = Config()) {
        self.plan = plan
        self.config = config
        hills = config.deferOnClimbs ? plan.course?.hills() ?? [] : []
    }

    public mutating func evaluate(state: RunState, at t: TimeInterval) -> [Cue] {
        let d = state.distance
        guard d > furthest.d else { return [] }
        let from = furthest
        furthest = (t, d)

        var cues: [Cue] = []
        let unit = config.unit.meters
        while true {
            let marker = splits.count + 1
            let at = Double(marker) * unit
            guard at < plan.distanceMeters, d >= at else { break }
            // Linear between the furthest point before and this state.
            let crossed = from.t + (t - from.t) * (at - from.d) / (d - from.d)
            let previous = splits.last?.crossedAt ?? 0
            let split = Split(marker: marker, unit: config.unit, crossedAt: crossed, time: crossed - previous,
                              planTime: plan.planTime(at: at) - plan.planTime(at: at - unit))
            splits.append(split)
            cues.append(cue(for: split, at: t, distance: d))
        }
        return cues
    }

    private func cue(for split: Split, at t: TimeInterval, distance d: Double) -> Cue {
        let at = Double(split.marker) * split.unit.meters
        // On a climb: wait for the crest, and expire `expiresAfter` after reaching it.
        let crest = hills.first { at >= $0.startDistance && at < $0.endDistance }?.endDistance
        let toCrest = crest.map { max(0, $0 - d) * plan.targetPace(at: d) * config.climbPaceAllowance } ?? 0
        return Cue(key: .split(marker: split.marker, unit: split.unit),
            priority: config.priority,
            reveal: .auto,
            content: CueContent(heading: .marker(split.marker, split.unit),
                                main: .duration(split.time),
                                subtitle: [.phrase([.gap(split.vsPlan), .label("VS PLAN")])],
                                tag: "SPLIT"),
            createdAt: t,
            expiresAt: t + toCrest + config.expiresAfter,
            minShow: config.minShow,
            planGap: split.vsPlan,
            deferUntil: crest.map { .distance($0) })
    }
}
