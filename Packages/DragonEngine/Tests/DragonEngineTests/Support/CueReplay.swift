//  CueReplay.swift
//  Test support: a whole synthetic race through the RunEngine pipeline, one
//  update per second, keeping what the triggers proposed, what the arbiter
//  decided, what was shown and the frame drawn. Optionally an update at the
//  gun (run time 0, before anyone moves) and updates for a while after the
//  finish, with nothing more from the devices.
//
//      let race = cueRace(.onPlan)
//      race.proposed.filter { $0.cue.key == .paceGap }
//      let full = cueRace(.designWalkthrough, atGun: true, afterFinish: 15)

import Foundation
import DragonEngine

struct CueRace {
    struct Row {
        let t: TimeInterval
        let trueDistance: Double
        let state: RunState
        let proposed: [Cue]
        let current: Cue?
        /// The arbiter's decisions this step.
        let decisions: [Decision]
        /// Pace-gap trigger's direction after this step, if on.
        let paceGap: PaceGapTrigger.Direction?
        /// What the arbiter was allowed to show, and the capacity row it came from.
        let budget: Budget
        let situation: Capacity.Situation
        /// The frame RunEngine would send now.
        let frame: HUDFrame

        /// The frame's strings, top to bottom as drawn.
        var texts: [String] {
            frame.ops.compactMap { op -> String? in
                if case .text(_, _, _, _, _, let s) = op { return s } else { return nil }
            }
        }
    }

    let profile: SyntheticProfile
    let plan: RunPlan
    let rows: [Row]
    let splits: [SplitTrigger.Split]
    /// Run time the runner really crossed the line.
    let finishTime: TimeInterval
    /// The engine at the end, for its triggers and log.
    let engine: RunEngine

    /// Every proposal with the row it came from.
    var proposed: [(row: Row, cue: Cue)] {
        rows.flatMap { row in row.proposed.map { (row, $0) } }
    }

    func proposals(_ key: CueKey) -> [(row: Row, cue: Cue)] {
        proposed.filter { $0.cue.key == key }
    }

    var splitProposals: [(row: Row, cue: Cue)] {
        proposed.filter { if case .split = $0.cue.key { return true } else { return false } }
    }

    /// Rows where a cue with this key went on screen.
    func appearances(_ key: CueKey) -> [Row] {
        rows.filter { $0.decisions.contains { $0.key == key && appeared($0) } }
    }

    /// Rows where a cue of this kind went on screen.
    func appearances(kind: CueKind) -> [Row] {
        rows.filter { $0.decisions.contains { $0.key.kind == kind && appeared($0) } }
    }
}

/// The decision put the cue on screen (rather than kept it there).
func appeared(_ d: Decision) -> Bool {
    switch d.reason {
    case .won, .interrupted: return true
    default: return false
    }
}

private var cueRaceCache: [String: CueRace] = [:]

/// `atGun`: also update at run time 0 with only what was sent at the gun.
/// `afterFinish`: seconds of updates after the finish, once a second, with
/// nothing more from the devices. `extra`: events to ingest as well, each
/// once run time reaches it.
func cueRace(_ profile: SyntheticProfile, seed: UInt64 = 42, config: RunEngine.Config = RunEngine.Config(),
             atGun: Bool = false, afterFinish: TimeInterval = 0, extra: [RunEvent] = []) -> CueRace {
    let key = "\(profile.name)/\(seed)/\(config)/\(atGun)/\(afterFinish)/\(extra)"
    if let cached = cueRaceCache[key] { return cached }

    var run = SyntheticRun(profile: profile, seed: seed)
    var engine = RunEngine(plan: run.plan, config: config)
    var rows: [CueRace.Row] = []
    var pending = extra.sorted { $0.t < $1.t }
    func step(at t: TimeInterval, distance: Double) {
        while let e = pending.first, e.t <= t {
            engine.ingest(e)
            pending.removeFirst()
        }
        let step = engine.update(at: t)
        rows.append(.init(t: t, trueDistance: distance, state: step.state, proposed: step.proposed,
                          current: step.current, decisions: step.decisions, paceGap: engine.paceGap.active,
                          budget: step.budget, situation: step.situation, frame: engine.frame()))
    }
    if atGun {
        for event in run.samples(until: 0) { engine.ingest(event) }
        step(at: 0, distance: 0)
    }
    while !run.isFinished {
        for event in run.advance(by: 1) { engine.ingest(event) }
        step(at: run.time, distance: run.distance)
    }
    let end = run.time
    var t = end
    while t < end + afterFinish {
        t += 1
        step(at: t, distance: run.distance)
    }
    let race = CueRace(profile: profile, plan: run.plan, rows: rows, splits: engine.split.splits,
                       finishTime: run.finishTime ?? end, engine: engine)
    cueRaceCache[key] = race
    return race
}
