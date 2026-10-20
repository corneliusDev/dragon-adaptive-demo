//  RunEngine.swift
//  The coordinator for a run with a RunPlan loaded: ingest → estimate →
//  trigger → capacity → arbitrate → render, every update. The triggers —
//  split, pace gap, heart ceiling, terrain ahead, fuel, form fade, kick clock,
//  finish, and the on-demand answers to glances and held looks — feed the
//  arbiter, which obeys the budget Capacity works
//  out each step from the state, attention and the display setting; the
//  Renderer lays the chosen cue out to fit that budget. A step carries a new
//  frame only when what is drawn changed, so the glasses aren't sent the same
//  frame again. (The scenario demos run the same trigger → arbiter → render
//  stages through AdaptiveEngine, with ScriptedTrigger.) Every step's
//  decisions go into the engine's cue log (`log`), with the state they were
//  made in, the runner's attention matched to the cue on screen, and the
//  pace-gap and heart-rate cues' outcomes a minute later.
//
//  Attention: each glance or held look is a request, answered on the next
//  update by the form-fade cue when form is fading (a glance), else by the
//  on-demand trigger; it also acknowledges a fuel cue. The finish: once the
//  runner is across the line (noticed by position, or finish(at:)), the next
//  update takes the kick clock down, lets the finished budget in and shows
//  the result; after it the display is dark.
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
//  Segues and heads-ups (chunk 14): the step's `frame` is the target (the
//  renderer's frame for the cue); `presented` is what to send the glasses
//  now, with the change between cues eased by the Segue setting (Presenter)
//  and the heads-up drawn over it. Predictable cues are announced ahead from
//  their triggers' Upcoming hints, so their heads-up runs the lead before
//  they appear; the arbiter keeps a quiet gap between cues.
//
//      engine.segue = .slide; engine.headsUp = [.dotPulse, .ledBlink]
//      if let frame = step.presented { backend.apply(frame) }
//      if step.headsUpBegan, let h = step.headsUp { watch.tap(h) }
//
//  A value like StateEstimator; it never reads the clock.

import Foundation

public struct RunEngine {
    public struct Config: Sendable, Equatable {
        public var estimator = StateEstimator.Tuning()
        public var split: SplitTrigger.Config
        public var paceGap: PaceGapTrigger.Config
        public var heart: HeartCeilingTrigger.Config
        public var terrain = TerrainAheadTrigger.Config()
        public var fuel = FuelTrigger.Config()
        public var formFade = FormFadeTrigger.Config()
        public var kickClock = KickClockTrigger.Config()
        public var onDemand: OnDemandTrigger.Config
        public var finish = FinishTrigger.Config()
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
        /// How cues ease on and off; RunEngine.segue changes it later.
        public var segue = Segue.default
        /// What warns of a predictable cue (empty: Off); RunEngine.headsUp changes it later.
        public var headsUp = HeadsUpKind.defaultSetting
        /// Segue and heads-up timings. The arbiter's quiet gap and heads-up lead
        /// come from here (overriding `arbiter`'s).
        public var segues = SegueConfig()

        /// Splits and paces in `unit`.
        public init(unit: DistanceUnit = .miles) {
            self.unit = unit
            split = SplitTrigger.Config(unit: unit)
            paceGap = PaceGapTrigger.Config(unit: unit)
            heart = HeartCeilingTrigger.Config(unit: unit)
            onDemand = OnDemandTrigger.Config(unit: unit)
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
        /// The frame to show now — mid-change or settled, with the heads-up
        /// over it — when it differs from the last one presented; nil when unchanged.
        public var presented: HUDFrame?
        /// The heads-up running, if any.
        public var headsUp: HeadsUpSignal?
        /// The heads-up began on this step (for the Watch tap).
        public var headsUpBegan: Bool
    }

    /// A heads-up: which cue is coming, how much it matters and when it should appear.
    public struct HeadsUpSignal: Sendable, Equatable {
        public var key: CueKey
        /// Run time it began.
        public var since: TimeInterval
        /// Run time the cue is due on screen.
        public var dueAt: TimeInterval
        /// The coming cue's priority (the Watch tap is strong for critical and safety).
        public var priority: Priority

        public init(key: CueKey, since: TimeInterval, dueAt: TimeInterval, priority: Priority = .advisory) {
            self.key = key
            self.since = since
            self.dueAt = dueAt
            self.priority = priority
        }
    }

    public let plan: RunPlan
    public let config: Config
    public private(set) var estimator: StateEstimator
    public private(set) var split: SplitTrigger
    public private(set) var paceGap: PaceGapTrigger
    public private(set) var heart: HeartCeilingTrigger
    public private(set) var terrain: TerrainAheadTrigger
    public private(set) var fuel: FuelTrigger
    public private(set) var formFade: FormFadeTrigger
    public private(set) var kickClock: KickClockTrigger
    public let onDemand: OnDemandTrigger
    public private(set) var finishLine: FinishTrigger
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
    /// Plays the changes between cues and draws the heads-up.
    public private(set) var presentation: Presentation
    /// The frame presented by the latest update.
    public private(set) var presentedFrame = HUDFrame()
    private var presentedSignature: String?
    /// The predictable cues the triggers expect next (latest update).
    public private(set) var upcoming: [Upcoming] = []
    /// The heads-up running after the latest update.
    public private(set) var headsUpSignal: HeadsUpSignal?
    /// Recent (run time, distance), for the pace hints are timed at.
    private var recent: [(t: TimeInterval, d: Double)] = []
    /// Glances and held looks not answered yet, oldest first.
    private var requests: [AttentionSample] = []
    /// Run time the runner crossed the line, once the engine has acted on it.
    public private(set) var finishedAt: TimeInterval?

    public var current: Cue? { arbiter.showing }

    /// Every decision so far, with its context, response and outcome.
    public var log: CueLog { logger.log }

    public var displaySetting: DisplaySetting {
        get { capacity.setting }
        set { capacity.setting = newValue }
    }

    /// How cues ease on and off; the next change uses it.
    public var segue: Segue {
        get { presentation.segue }
        set { presentation.segue = newValue }
    }

    /// What warns of a predictable cue; empty turns heads-ups off (and the
    /// arbiter stops holding predictable cues for them).
    public var headsUp: Set<HeadsUpKind> {
        get { presentation.headsUp }
        set {
            presentation.headsUp = newValue
            arbiter.config.headsUpLead = newValue.isEmpty ? 0 : presentation.config.headsUpLead
        }
    }

    /// Segue and heads-up timings (the developer screen's sliders).
    public var segueConfig: SegueConfig {
        get { presentation.config }
        set {
            presentation.config = newValue
            arbiter.config.quietGap = newValue.quietGap
            arbiter.config.headsUpTolerance = newValue.headsUpTolerance
            arbiter.config.headsUpLead = presentation.headsUp.isEmpty ? 0 : newValue.headsUpLead
        }
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
        heart = HeartCeilingTrigger(plan: plan, config: config.heart)
        terrain = TerrainAheadTrigger(plan: plan, config: config.terrain)
        fuel = FuelTrigger(plan: plan, config: config.fuel)
        formFade = FormFadeTrigger(plan: plan, config: config.formFade)
        kickClock = KickClockTrigger(plan: plan, config: config.kickClock)
        onDemand = OnDemandTrigger(plan: plan, config: config.onDemand)
        finishLine = FinishTrigger(plan: plan, config: config.finish)
        var arbiterConfig = config.arbiter
        arbiterConfig.quietGap = config.segues.quietGap
        arbiterConfig.headsUpLead = config.headsUp.isEmpty ? 0 : config.segues.headsUpLead
        arbiterConfig.headsUpTolerance = config.segues.headsUpTolerance
        arbiter = Arbiter(config: arbiterConfig)
        presentation = Presentation(segue: config.segue, headsUp: config.headsUp, config: config.segues)
        capacity = Capacity(config: config.capacity, setting: config.display, raceDistance: plan.distanceMeters)
        logger = CueLogger(header: CueLog.Header(name: config.name, targetTime: plan.targetTime,
                                                 distance: plan.distanceMeters, display: config.display),
                           plan: plan, config: config.log)
    }

    public mutating func ingest(_ event: RunEvent) {
        estimator.ingest(event)
        if case .attention(let a) = event {
            capacity.note(a)
            logger.note(a)
            fuel.note(a)
            if a.event != .idle { requests.append(a) }
        }
    }

    /// The runner crossed the line at run time `t`. Until this is called,
    /// update(at:) logs the first update whose estimated distance reaches the
    /// plan's (and takes the finish as standing 5 s later); this replaces
    /// that (the caller knows better) and counts at once.
    public mutating func finish(at t: TimeInterval) {
        logger.finish(at: t)
        finishLine.crossed(at: t)
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
        // Across the line on an earlier update: the race's cues give way to the result.
        if finishedAt == nil, finishLine.isFinished(at: t), let crossed = finishLine.crossedAt {
            finishedAt = crossed
            capacity.finish(at: crossed)
            arbiter.withdraw(.kickClock, at: t)
        }
        var proposed: [Cue] = []
        if finishedAt == nil {
            proposed += split.evaluate(state: s, at: t) + paceGap.evaluate(state: s, at: t)
                + heart.evaluate(state: s, at: t) + terrain.evaluate(state: s, at: t)
                + fuel.evaluate(state: s, at: t) + formFade.evaluate(state: s, at: t)
                + kickClock.evaluate(state: s, at: t)
            for request in requests {
                if var cue = formFade.answer(request.event, at: t)
                    ?? onDemand.answer(request.event, state: s, splits: split.splits, at: t) {
                    cue.requested = true            // asked for: appears at once
                    proposed.append(cue)
                }
            }
        }
        requests = []
        proposed += finishLine.evaluate(state: s, at: t)
        let situation = capacity.situation(for: s, effort: effortOverride)
        let budget = capacity.budget(for: s, at: t, effort: effortOverride)
        announceUpcoming(state: s, budget: budget, at: t)
        let (shown, decisions) = arbiter.decide(proposed, budget: budget, at: t, distance: s.distance)
        self.budget = budget
        logger.record(decisions, cues: arbiter.decided, state: s, budget: budget, situation: situation, at: t)
        if s.distance >= plan.distanceMeters && logger.log.header.finishTime == nil { logger.finish(at: t) }
        let drawn = frame()
        let changed = drawn.signature != sentSignature
        if changed { sentSignature = drawn.signature }

        // The heads-up running, and the frame to show now.
        let before = headsUpSignal
        headsUpSignal = arbiter.headsUp(at: t).map { h in
            // The cue's priority: waiting in the arbiter, or as its trigger forecast it.
            let priority = arbiter.waiting.first { $0.key == h.key }?.priority
                ?? upcoming.first { $0.key == h.key }?.priority ?? before.flatMap { $0.key == h.key ? $0.priority : nil }
                ?? .advisory
            return HeadsUpSignal(key: h.key, since: h.since, dueAt: h.since + presentation.config.headsUpLead,
                                 priority: priority)
        }
        let began = headsUpSignal.map { now in before.map { $0.key != now.key || $0.since != now.since } ?? true } ?? false
        presentedFrame = presentation.frame(target: drawn, cue: shown, headsUpSince: headsUpSignal?.since, at: t)
        let presentedChanged = presentedFrame.signature != presentedSignature
        if presentedChanged { presentedSignature = presentedFrame.signature }
        return Step(state: s, proposed: proposed, current: shown, decisions: decisions,
                    budget: budget, situation: situation, frame: changed ? drawn : nil,
                    presented: presentedChanged ? presentedFrame : nil,
                    headsUp: headsUpSignal, headsUpBegan: began)
    }

    /// Starts the heads-up of each predictable cue its trigger expects within
    /// the lead (from when the screen can take it), if the budget would let it
    /// show. It starts the lead less the tolerance ahead: a cue a little later
    /// than forecast (or seen an update late) still lands within the
    /// tolerance, and one a little early waits out the rest of its lead.
    private mutating func announceUpcoming(state s: RunState, budget: Budget, at t: TimeInterval) {
        recent.append((t, s.distance))
        recent.removeAll { t - $0.t > 10 }
        guard finishedAt == nil else { upcoming = []; return }
        let within = presentation.config.announceWithin
        let pace = currentPace(s)
        upcoming = split.upcoming(state: s, at: t, pace: pace, within: within) + paceGap.upcoming(at: t)
            + fuel.upcoming(at: t) + terrain.upcoming(state: s, at: t, pace: pace, within: within)
            + kickClock.upcoming(state: s, at: t, pace: pace, within: within)
        let lead = arbiter.config.headsUpLead - arbiter.config.headsUpTolerance
        guard arbiter.config.headsUpLead > 0 else { return }
        // Updates coarser than the tolerance can't hit the moment: announce on
        // the last update before it (the arbiter allows one update's slack).
        let interval = recent.count > 1 ? t - recent[recent.count - 2].t : 0
        let coarse = interval > 2 * arbiter.config.headsUpTolerance
        for hint in upcoming where budget.admits(hint.priority) {
            let free = arbiter.freeAt(priority: hint.priority, key: hint.key, interrupts: budget.allowInterrupt, at: t)
            let at = max(hint.expectedAt, free) - lead
            if t >= at || coarse && t + interval > at { arbiter.announce(hint.key, at: t) }
        }
    }

    /// Seconds per metre over the last few seconds of estimated distance (what
    /// the split trigger crosses markers on), else the rolling pace, else the plan's.
    private func currentPace(_ s: RunState) -> Double {
        if let first = recent.first, let last = recent.last, last.t - first.t >= 2, last.d > first.d {
            return (last.t - first.t) / (last.d - first.d)
        }
        return s.pace30s ?? s.pace60s ?? plan.targetPace(at: s.distance)
    }

    /// The chosen cue (or the quiet status dot; nothing once the race is over),
    /// laid out for the latest budget.
    public func frame() -> HUDFrame {
        Renderer.frame(for: current, budget: budget ?? config.capacity.relaxed, state: state,
                       unit: config.unit, quiet: finishedAt == nil ? .statusDot : .dark, config: config.render)
    }
}
