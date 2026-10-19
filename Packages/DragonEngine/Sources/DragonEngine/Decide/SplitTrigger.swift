//  SplitTrigger.swift
//  A cue at every mile (or kilometre) marker: the split just run and how it
//  compares with the plan's split for the same stretch.
//
//  The crossing time is interpolated between the last state before the
//  marker and the first one past it, so a coarse update rate, or GPS jumping
//  across a marker between two samples, still gives one cue per marker with
//  a sensible split. Markers are counted, never re-fired: distance wandering
//  back over a marker does nothing. The finish line isn't a split.

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

    public init(plan: RunPlan, config: Config = Config()) {
        self.plan = plan
        self.config = config
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
            cues.append(cue(for: split, at: t))
        }
        return cues
    }

    private func cue(for split: Split, at t: TimeInterval) -> Cue {
        Cue(key: .split(marker: split.marker, unit: split.unit),
            priority: config.priority,
            reveal: .auto,
            content: CueContent(heading: .marker(split.marker, split.unit),
                                main: .duration(split.time),
                                subtitle: [.phrase([.gap(split.vsPlan), .label("VS PLAN")])],
                                tag: "SPLIT"),
            createdAt: t,
            expiresAt: t + config.expiresAfter,
            minShow: config.minShow,
            planGap: split.vsPlan)
    }
}
