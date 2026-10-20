//  SegueReplay.swift
//  Test support: a whole synthetic race through RunEngine at a fine update
//  rate (0.25 s by default, as the app's 20 Hz loop would see it to the
//  nearest quarter second), keeping each step's presented frame, target
//  frame, heads-up and decisions, for the segue and heads-up tests.
//
//      let race = segueRace(.designWalkthrough)
//      race.appearances.filter { $0.cue.key.kind.isPredictable }

import Foundation
import DragonEngine

struct SegueRace {
    struct Row {
        let t: TimeInterval
        let state: RunState
        let current: Cue?
        let decisions: [Decision]
        /// What the renderer drew for the cue (Step.frame's content, every step).
        let target: HUDFrame
        /// What went to the glasses: the presented frame as of this step.
        let presented: HUDFrame
        let headsUp: RunEngine.HeadsUpSignal?
        let headsUpBegan: Bool
    }

    /// A cue going on screen, and the row it went up in.
    struct Appearance {
        let index: Int
        let row: Row
        let cue: Cue
    }

    let profile: SyntheticProfile
    let step: TimeInterval
    let rows: [Row]
    let engine: RunEngine

    var appearances: [Appearance] {
        rows.enumerated().compactMap { i, row in
            guard let cue = row.current,
                  row.decisions.contains(where: { $0.key == cue.key && appeared($0) }) else { return nil }
            return Appearance(index: i, row: row, cue: cue)
        }
    }

    /// Run time each cue left the screen (finished, dismissed, cut short, …), in order.
    var departures: [(t: TimeInterval, key: CueKey)] {
        rows.flatMap { row in
            row.decisions.filter {
                switch $0.reason {
                case .finished, .dismissed, .budgetClosed, .finalStretch, .withdrawn, .cutShort: return true
                case .replaced: return true
                default: return false
                }
            }.map { (row.t, $0.key) }
        }
    }
}

private var segueRaceCache: [String: SegueRace] = [:]

func segueRace(_ profile: SyntheticProfile, seed: UInt64 = 42, step: TimeInterval = 0.25,
               config: RunEngine.Config = RunEngine.Config(), extra: [RunEvent] = []) -> SegueRace {
    let key = "\(profile.name)/\(seed)/\(step)/\(config)/\(extra)"
    if let cached = segueRaceCache[key] { return cached }
    var run = SyntheticRun(profile: profile, seed: seed)
    var engine = RunEngine(plan: run.plan, config: config)
    var rows: [SegueRace.Row] = []
    var pending = extra.sorted { $0.t < $1.t }
    var presented = HUDFrame()
    while !run.isFinished {
        for event in run.advance(by: step) { engine.ingest(event) }
        while let e = pending.first, e.t <= run.time {
            engine.ingest(e)
            pending.removeFirst()
        }
        let s = engine.update(at: run.time)
        if let p = s.presented { presented = p }
        rows.append(.init(t: run.time, state: s.state, current: s.current, decisions: s.decisions,
                          target: engine.frame(), presented: presented, headsUp: s.headsUp,
                          headsUpBegan: s.headsUpBegan))
    }
    let race = SegueRace(profile: profile, step: step, rows: rows, engine: engine)
    segueRaceCache[key] = race
    return race
}
