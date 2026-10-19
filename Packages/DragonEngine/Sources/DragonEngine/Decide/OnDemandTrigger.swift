//  OnDemandTrigger.swift
//  Ask and it answers. A glance gets the status: projected finish against the
//  target ("PROJECTED FINISH · 1:45:01 · +0:01 ON PLAN") for 1.5 s. A held look
//  gets the detail: the last 3 splits, the pace still needed to beat the
//  target, and the projection ("NEED 7:49 / MI · PROJ 1:45:22 +0:22") for
//  2.6 s. Before the start (standing, nothing covered yet) either one gets the
//  target and the plan ("TARGET · 1:45:00 · 8:01 / MI EVEN") for 4 s.
//
//  Answers are Info with reveal .glance / .dwell: the budget lets an answer
//  through below its usual lowest priority (Budget.answersRequests), but not
//  in a safety-only stretch, and it shows then or not at all (it expires as
//  the look does). RunEngine passes each request in with the latest splits.

import Foundation

public struct OnDemandTrigger {
    public struct Config: Sendable, Equatable {
        /// Seconds each answer stays up (design: 1.5 s, 2.6 s, 4 s).
        public var glanceShow: TimeInterval = 1.5
        public var dwellShow: TimeInterval = 2.6
        public var targetShow: TimeInterval = 4
        /// A projected finish within this many seconds of the target reads "ON PLAN"
        /// (the pace-gap trigger's start threshold: closer than that is not a problem).
        public var onPlanWithin: TimeInterval = 15
        /// Metres covered under which a standing runner hasn't started yet.
        public var startDistance = 10.0
        /// Splits in the held look's table.
        public var splits = 3
        public var unit: DistanceUnit = .miles
        public var priority: Priority = .info

        public init(unit: DistanceUnit = .miles) {
            self.unit = unit
        }
    }

    public let plan: RunPlan
    public let config: Config

    public init(plan: RunPlan, config: Config = Config()) {
        self.plan = plan
        self.config = config
    }

    /// The answer to `event` in state `s` at run time `t`; nil for idle, or a
    /// status asked for before there is a projection.
    public func answer(_ event: AttentionEvent, state s: RunState, splits: [SplitTrigger.Split],
                       at t: TimeInterval) -> Cue? {
        guard event != .idle else { return nil }
        if s.distance < config.startDistance && s.phase == .stopped {
            return cue(.target, reveal: event == .dwell ? .dwell : .glance, show: config.targetShow,
                       content: target(), at: t)
        }
        if event == .dwell {
            return cue(.detail, reveal: .dwell, show: config.dwellShow, content: detail(s, splits: splits), at: t)
        }
        guard let finish = s.projectedFinish else { return nil }
        let gap = finish - plan.targetTime
        let words = abs(gap) < config.onPlanWithin ? "ON PLAN" : gap > 0 ? "BEHIND" : "AHEAD"
        return cue(.status, reveal: .glance, show: config.glanceShow,
                   content: CueContent(heading: .label("PROJECTED FINISH"), main: .duration(finish),
                                       subtitle: [.phrase([.gap(gap), .label(words)])], tag: "STATUS"),
                   at: t)
    }

    /// Before the gun: the target, its pace and the pacing, and a hint.
    private func target() -> CueContent {
        let pacing: String
        switch plan.pacing {
        case .even: pacing = "EVEN"
        case .negativeSplit: pacing = "NEGATIVE"
        case .perSplit: pacing = "BY SPLIT"
        }
        return CueContent(heading: .label("TARGET"), main: .duration(plan.targetTime),
                          subtitle: [.phrase([.pace(plan.targetTime / plan.distanceMeters, config.unit),
                                              .label(pacing)])],
                          footer: .label("GLANCE FOR STATUS"))
    }

    /// The held look: recent splits, the pace that still beats the target, the projection.
    private func detail(_ s: RunState, splits: [SplitTrigger.Split]) -> CueContent {
        let recent = splits.suffix(config.splits)
        let left = plan.distanceMeters - s.distance, timeLeft = plan.targetTime - s.elapsed
        let need: CueText = left > 0 && timeLeft > 0
            ? .phrase([.label("NEED"), .pace(timeLeft / left, config.unit)]) : .label("TARGET GONE")
        var footer: CueText?
        if let finish = s.projectedFinish {
            footer = .phrase([.label("PROJ"), .duration(finish), .gap(finish - plan.targetTime)])
        }
        return CueContent(heading: .label(recent.isEmpty ? "NO SPLITS YET" : "LAST \(recent.count) SPLITS"),
                          main: need,
                          rows: recent.map { CueRow(.marker($0.marker, $0.unit), .duration($0.time)) },
                          footer: footer)
    }

    private func cue(_ key: CueKey, reveal: Reveal, show: TimeInterval, content: CueContent,
                     at t: TimeInterval) -> Cue {
        Cue(key: key, priority: config.priority, reveal: reveal, content: content,
            createdAt: t, expiresAt: t + show, minShow: show)
    }
}
