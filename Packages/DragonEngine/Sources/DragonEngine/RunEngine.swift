//  RunEngine.swift
//  The plan-driven pipeline: estimator → triggers → arbiter → render, for a
//  run with a RunPlan loaded. (Without a plan the app keeps today's scenario
//  AdaptiveEngine.) The split and pace-gap triggers feed the arbiter; until
//  chunk 6 computes capacity it gets the fixed `config.budget`. The cue log
//  (chunk 8) will keep each step's decisions.
//
//      var engine = RunEngine(plan: plan)
//      engine.ingest(event)               // every sample, in time order
//      let step = engine.update(at: t)    // run time; once per tick
//      engine.dismiss(at: t)              // the runner dismissed the cue
//      backend.apply(engine.frame())
//
//  A value like StateEstimator; it never reads the clock.

import Foundation

public struct RunEngine {
    public struct Config: Sendable, Equatable {
        public var estimator = StateEstimator.Tuning()
        public var split: SplitTrigger.Config
        public var paceGap: PaceGapTrigger.Config
        public var arbiter = Arbiter.Config()
        /// What the arbiter may show. Fixed until chunk 6: 2 elements, advisory and up.
        public var budget = Budget.steady

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
        /// The arbiter's decision for every cue in play this step.
        public var decisions: [Decision]
    }

    public let plan: RunPlan
    public let config: Config
    public private(set) var estimator: StateEstimator
    public private(set) var split: SplitTrigger
    public private(set) var paceGap: PaceGapTrigger
    public private(set) var arbiter: Arbiter
    /// The latest state, once update(at:) has run.
    public private(set) var state: RunState?

    public var current: Cue? { arbiter.showing }

    public init(plan: RunPlan, config: Config = Config()) {
        self.plan = plan
        self.config = config
        estimator = StateEstimator(plan: plan, tuning: config.estimator)
        split = SplitTrigger(plan: plan, config: config.split)
        paceGap = PaceGapTrigger(plan: plan, config: config.paceGap)
        arbiter = Arbiter(config: config.arbiter)
    }

    public mutating func ingest(_ event: RunEvent) {
        estimator.ingest(event)
    }

    /// The runner dismissed the cue on screen: it comes down and its key cools
    /// down for longer than if it had been ignored. Returns false if nothing showed.
    @discardableResult
    public mutating func dismiss(at t: TimeInterval) -> Bool {
        arbiter.dismiss(at: t)
    }

    /// Runs the pipeline at run time `t`. Call with non-decreasing `t`.
    @discardableResult
    public mutating func update(at t: TimeInterval) -> Step {
        let s = estimator.state(at: t)
        state = s
        let proposed = split.evaluate(state: s, at: t) + paceGap.evaluate(state: s, at: t)
        let (shown, decisions) = arbiter.decide(proposed, budget: config.budget, at: t, distance: s.distance)
        return Step(state: s, proposed: proposed, current: shown, decisions: decisions)
    }

    /// The chosen cue (or the quiet screen) as a frame.
    public func frame() -> HUDFrame {
        CueRenderer.frame(for: current, effort: state?.effort ?? .moderate)
    }
}
