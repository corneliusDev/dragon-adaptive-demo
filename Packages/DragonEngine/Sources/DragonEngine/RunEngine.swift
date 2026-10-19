//  RunEngine.swift
//  The coordinator for a run with a RunPlan loaded: ingest → estimate →
//  trigger → capacity → arbitrate → render, every update. The split and
//  pace-gap triggers feed the arbiter, which obeys the budget Capacity works
//  out each step from the state, attention and the display setting; the
//  Renderer lays the chosen cue out to fit that budget. A step carries a new
//  frame only when what is drawn changed, so the glasses aren't sent the same
//  frame again. (The scenario demos run the same trigger → arbiter → render
//  stages through AdaptiveEngine, with ScriptedTrigger.) Every step's
//  decisions go into the engine's cue log (`log`), with the state they were
//  made in, the runner's attention matched to the cue on screen, and the
//  pace-gap and heart-rate cues' outcomes a minute later.
//
//      var engine = RunEngine(plan: plan)
//      engine.ingest(event)               // every sample, in time order
//      engine.displaySetting = .minimal   // any time; next update uses it
//      let step = engine.update(at: t)    // run time; once per tick
//      engine.dismiss(at: t)              // the runner dismissed the cue
//      if let frame = step.frame { backend.apply(frame) }
//      engine.finish(at: t)               // across the line (else noticed by position)
//      try engine.log.jsonLines()         // save the cue log
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
        public var render = RenderConfig()
        public var log = CueLogger.Config()
        /// Label for the cue log's header (e.g. the synthetic profile and seed).
        public var name = ""
        /// Minimal / Balanced / Coach at the start; RunEngine.displaySetting changes it later.
        public var display = DisplaySetting.balanced
        /// Miles or kilometres, for splits, paces and the distances drawn.
        public var unit: DistanceUnit

        /// Splits and paces in `unit`.
        public init(unit: DistanceUnit = .miles) {
            self.unit = unit
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
        /// The frame to send, when it differs from the last one a step carried; nil when unchanged.
        public var frame: HUDFrame?
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
    /// The latest budget, once update(at:) has run.
    public private(set) var budget: Budget?
    /// Builds the cue log from every step's decisions.
    public private(set) var logger: CueLogger
    /// Signature of the last frame a step carried.
    private var sentSignature: String?

    public var current: Cue? { arbiter.showing }

    /// Every decision so far, with its context, response and outcome.
    public var log: CueLog { logger.log }

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
        logger = CueLogger(header: CueLog.Header(name: config.name, targetTime: plan.targetTime,
                                                 distance: plan.distanceMeters, display: config.display),
                           config: config.log)
    }

    public mutating func ingest(_ event: RunEvent) {
        estimator.ingest(event)
        if case .attention(let a) = event {
            capacity.note(a)
            logger.note(a)
        }
    }

    /// The runner crossed the line at run time `t`. Until this is called,
    /// update(at:) logs the first update whose estimated distance reaches the
    /// plan's; this replaces that (the caller knows better).
    public mutating func finish(at t: TimeInterval) {
        logger.finish(at: t)
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
        self.budget = budget
        logger.record(decisions, cues: arbiter.decided, state: s, budget: budget, situation: situation, at: t)
        if s.distance >= plan.distanceMeters && logger.log.header.finishTime == nil { logger.finish(at: t) }
        let drawn = frame()
        let changed = drawn.signature != sentSignature
        if changed { sentSignature = drawn.signature }
        return Step(state: s, proposed: proposed, current: shown, decisions: decisions,
                    budget: budget, situation: situation, frame: changed ? drawn : nil)
    }

    /// The chosen cue (or the quiet status dot), laid out for the latest budget.
    public func frame() -> HUDFrame {
        Renderer.frame(for: current, budget: budget ?? config.capacity.relaxed, state: state,
                       unit: config.unit, config: config.render)
    }
}
