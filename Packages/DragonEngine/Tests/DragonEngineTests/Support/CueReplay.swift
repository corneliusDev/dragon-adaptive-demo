//  CueReplay.swift
//  Test support: a whole synthetic race through the RunEngine pipeline, one
//  update per second, keeping what the triggers proposed, what the arbiter
//  decided and what was shown.
//
//      let race = cueRace(.onPlan)
//      race.proposed.filter { $0.cue.key == .paceGap }

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
    }

    let profile: SyntheticProfile
    let plan: RunPlan
    let rows: [Row]
    let splits: [SplitTrigger.Split]

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
}

private var cueRaceCache: [String: CueRace] = [:]

func cueRace(_ profile: SyntheticProfile, seed: UInt64 = 42, config: RunEngine.Config = RunEngine.Config()) -> CueRace {
    let key = "\(profile.name)/\(seed)/\(config)"
    if let cached = cueRaceCache[key] { return cached }

    var run = SyntheticRun(profile: profile, seed: seed)
    var engine = RunEngine(plan: run.plan, config: config)
    var rows: [CueRace.Row] = []
    while !run.isFinished {
        for event in run.advance(by: 1) { engine.ingest(event) }
        let step = engine.update(at: run.time)
        rows.append(.init(t: run.time, trueDistance: run.distance, state: step.state, proposed: step.proposed,
                          current: step.current, decisions: step.decisions, paceGap: engine.paceGap.active))
    }
    let race = CueRace(profile: profile, plan: run.plan, rows: rows, splits: engine.split.splits)
    cueRaceCache[key] = race
    return race
}
