//  EstimatorReplay.swift
//  Test support: a whole synthetic race fed through a StateEstimator, one
//  state per second next to the simulator's ground truth.
//
//      let race = estimatedRace(.slowFade(from: 9 * mile))
//      race.rows.last?.state.projectedFinish   vs   race.finish

import Foundation
import DragonEngine

struct EstimatedRace {
    struct Row {
        let t: TimeInterval
        /// Metres the runner had really covered.
        let trueDistance: Double
        let state: RunState
    }

    let profile: SyntheticProfile
    let plan: RunPlan
    let rows: [Row]
    /// When the runner really crossed the line.
    let finish: TimeInterval

    /// The plan's pace at a distance, seconds per metre.
    func planPace(at d: Double) -> Double { plan.targetPace(at: d) }

    /// The runner's true pace over the `window` seconds before row i, s/m.
    func truePace(endingAt i: Int, window: Int) -> Double? {
        guard i >= window else { return nil }
        let metres = rows[i].trueDistance - rows[i - window].trueDistance
        return metres > 0 ? Double(window) / metres : nil
    }
}

private var raceCache: [String: EstimatedRace] = [:]

/// Runs `profile` to the finish, handing the estimator everything the phone and
/// watch sent each second and asking for the state at that second. Cached, as
/// several tests read the same races.
func estimatedRace(_ profile: SyntheticProfile, seed: UInt64 = 42,
                   tuning: StateEstimator.Tuning = StateEstimator.Tuning()) -> EstimatedRace {
    let key = "\(profile.name)/\(seed)/\(tuning)"
    if let cached = raceCache[key] { return cached }

    var run = SyntheticRun(profile: profile, seed: seed)
    var estimator = StateEstimator(plan: run.plan, tuning: tuning)
    var rows: [EstimatedRace.Row] = []
    while !run.isFinished {
        for event in run.advance(by: 1) { estimator.ingest(event) }
        rows.append(.init(t: run.time, trueDistance: run.distance, state: estimator.state(at: run.time)))
    }
    let race = EstimatedRace(profile: profile, plan: run.plan, rows: rows, finish: run.finishTime!)
    raceCache[key] = race
    return race
}
