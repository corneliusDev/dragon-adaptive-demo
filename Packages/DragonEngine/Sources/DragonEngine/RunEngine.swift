//  RunEngine.swift
//  The plan-driven pipeline: estimator → triggers → arbiter → render, for a
//  run with a RunPlan loaded. (Without a plan the app keeps today's scenario
//  AdaptiveEngine.) The split and pace-gap triggers feed the arbiter, which
//  obeys the budget Capacity works out each step from the state, attention
//  and the display setting. The cue log (chunk 8) will keep each step's decisions.
//
//      var engine = RunEngine(plan: plan)
//      engine.ingest(event)               // every sample, in time order
//      engine.displaySetting = .minimal   // any time; next update uses it
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
        public var capacity = CapacityConfig()
        /// Minimal / Balanced / Coach at the start; RunEngine.displaySetting changes it later.
        public var display = DisplaySetting.balanced

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
        /// What the arbiter was allowed to show, and the table row it came from.
        public var budget: Budget
        public var situation: Capacity.Situation
    }

    public let plan: RunPlan
    public let config: Config
    public private(set) var estimator: StateEstimator
    public private(set) var split: SplitTrigger
    public private(set) var paceGap: PaceGapTrigger
    public private(set) var arbiter: Arbiter
    public private(set) var capacity: Capacity
    /// The latest state, once update(at:) has run.
    public private(set) var state: RunState?

    public var current: Cue? { arbiter.showing }

    public var displaySetting: DisplaySetting {
        get { capacity.setting }
        set { capacity.setting = newValue }
    }

    /// Effort score (0–100) the budget uses instead of the measured one; nil
    /// uses the measured one. The app's effort slider, for trying the budget out.
    public var effortOverride: Double?

    public init(plan: RunPlan, config: Config = Config()) {
        self.plan = plan
        self.config = config
        estimator = StateEstimator(plan: plan, tuning: config.estimator)
        split = SplitTrigger(plan: plan, config: config.split)
        paceGap = PaceGapTrigger(plan: plan, config: config.paceGap)
        arbiter = Arbiter(config: config.arbiter)
        capacity = Capacity(config: config.capacity, setting: config.display, raceDistance: plan.distanceMeters)
    }

    public mutating func ingest(_ event: RunEvent) {
        estimator.ingest(event)
        if case .attention(let a) = event { capacity.note(a) }
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
        let situation = capacity.situation(for: s, effort: effortOverride)
        let budget = capacity.budget(for: s, at: t, effort: effortOverride)
        let (shown, decisions) = arbiter.decide(proposed, budget: budget, at: t, distance: s.distance)
        return Step(state: s, proposed: proposed, current: shown, decisions: decisions,
                    budget: budget, situation: situation)
    }

    /// The chosen cue (or the quiet screen) as a frame.
    public func frame() -> HUDFrame {
        CueRenderer.frame(for: current, effort: state?.effort ?? .moderate)
    }
}
