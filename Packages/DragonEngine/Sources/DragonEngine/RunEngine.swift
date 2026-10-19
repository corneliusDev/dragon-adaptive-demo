//  RunEngine.swift
//  The plan-driven pipeline: estimator → triggers → choice → render, for a
//  run with a RunPlan loaded. (Without a plan the app keeps today's scenario
//  AdaptiveEngine.) Chunk 4 has the split and pace-gap triggers and the
//  placeholder choice; capacity, the arbiter and the cue log come later.
//
//      var engine = RunEngine(plan: plan)
//      engine.ingest(event)               // every sample, in time order
//      let step = engine.update(at: t)    // run time; once per tick
//      backend.apply(engine.frame())
//
//  A value like StateEstimator; it never reads the clock.

import Foundation

public struct RunEngine {
    public struct Config: Sendable, Equatable {
        public var estimator = StateEstimator.Tuning()
        public var split: SplitTrigger.Config
        public var paceGap: PaceGapTrigger.Config

        /// Splits and paces in `unit`.
        public init(unit: DistanceUnit = .miles) {
            split = SplitTrigger.Config(unit: unit)
            paceGap = PaceGapTrigger.Config(unit: unit)
        }
    }

    /// What one update decided.
    public struct Step: Sendable {
        public var state: RunState
        /// Cues the triggers proposed this step.
        public var proposed: [Cue]
        /// What is on screen.
        public var current: Cue?
    }

    public let plan: RunPlan
    public let config: Config
    public private(set) var estimator: StateEstimator
    public private(set) var split: SplitTrigger
    public private(set) var paceGap: PaceGapTrigger
    public private(set) var choice = CueChoice()
    /// The latest state, once update(at:) has run.
    public private(set) var state: RunState?

    public var current: Cue? { choice.current }

    public init(plan: RunPlan, config: Config = Config()) {
        self.plan = plan
        self.config = config
        estimator = StateEstimator(plan: plan, tuning: config.estimator)
        split = SplitTrigger(plan: plan, config: config.split)
        paceGap = PaceGapTrigger(plan: plan, config: config.paceGap)
    }

    public mutating func ingest(_ event: RunEvent) {
        estimator.ingest(event)
    }

    /// Runs the pipeline at run time `t`. Call with non-decreasing `t`.
    @discardableResult
    public mutating func update(at t: TimeInterval) -> Step {
        let s = estimator.state(at: t)
        state = s
        let proposed = split.evaluate(state: s, at: t) + paceGap.evaluate(state: s, at: t)
        let shown = choice.update(proposed: proposed, at: t)
        return Step(state: s, proposed: proposed, current: shown)
    }

    /// The chosen cue (or the quiet screen) as a frame.
    public func frame() -> HUDFrame {
        CueRenderer.frame(for: current, effort: state?.effort ?? .moderate)
    }
}
