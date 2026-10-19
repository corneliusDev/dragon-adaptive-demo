//  TerrainAheadTrigger.swift
//  Before, never during: a hill or a sharp turn that starts 150–250 m ahead is
//  an advisory cue ("HILL 0.16 MI · HOLD EFFORT"), once per feature, with the
//  distance counting down while it is up. It is only worth anything until the
//  runner reaches the feature, so it expires then (at the plan's pace) rather
//  than showing on the climb itself.
//
//  The features come from the plan's course (Course.hills() and turns()), so
//  an aid station in between doesn't hide the hill behind it. The split that
//  falls on a climb is held to the crest by SplitTrigger with the same hills
//  (Cue.deferUntil .distance(crest)); this trigger only gives the warning.
//  Needs GPS: a position that is a guess shouldn't say where the hill starts.

import Foundation

public struct TerrainAheadTrigger: Trigger {
    public struct Config: Sendable, Equatable {
        /// Metres ahead of the runner the feature's start must be within to announce it.
        public var nearest = 150.0
        public var farthest = 250.0
        /// Warn of sharp turns (Course.turns(): 60° and more) as well as hills.
        public var turns = true
        public var priority: Priority = .advisory
        /// Seconds the cue stays up (design: 4 s).
        public var minShow: TimeInterval = 4

        public init() {}
    }

    public let plan: RunPlan
    public let config: Config
    /// The course's hills and sharp turns, by where they start.
    public let features: [CourseFeature]
    /// Starts (whole metres) of the features already announced.
    public private(set) var announced: Set<Int> = []

    public init(plan: RunPlan, config: Config = Config()) {
        self.plan = plan
        self.config = config
        let hills = plan.course?.hills().map(CourseFeature.hill) ?? []
        let turns = config.turns ? plan.course?.turns().map(CourseFeature.turn) ?? [] : []
        features = (hills + turns).sorted { $0.distance < $1.distance }
    }

    public mutating func evaluate(state s: RunState, at t: TimeInterval) -> [Cue] {
        var cues: [Cue] = []
        for f in features {
            let ahead = f.distance - s.distance
            let at = Int(f.distance.rounded())
            guard ahead >= config.nearest, ahead <= config.farthest, !announced.contains(at) else { continue }
            announced.insert(at)
            cues.append(cue(f, ahead: ahead, state: s, at: t))
        }
        return cues
    }

    private func cue(_ f: CourseFeature, ahead: Double, state s: RunState, at t: TimeInterval) -> Cue {
        let content: CueContent
        switch f {
        case .turn(let turn):
            content = CueContent(main: .phrase([.label("TURN"), .distanceLeft(to: f.distance)]),
                                 subtitle: [.label(turn.angle >= 0 ? "SHARP RIGHT" : "SHARP LEFT")],
                                 tag: "TERRAIN", icon: .arrow)
        case .hill, .aidStation:
            content = CueContent(main: .phrase([.label("HILL"), .distanceLeft(to: f.distance)]),
                                 subtitle: [.label("HOLD EFFORT")],
                                 tag: "TERRAIN", icon: .hill)
        }
        return Cue(key: .terrain(at: Int(f.distance.rounded())),
                   priority: config.priority,
                   reveal: .auto,
                   content: content,
                   createdAt: t,
                   // Worth nothing once the runner is on it.
                   expiresAt: t + ahead * plan.targetPace(at: s.distance),
                   minShow: config.minShow,
                   needs: [.gps])
    }
}
