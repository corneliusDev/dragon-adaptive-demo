//  FuelTrigger.swift
//  The plan's fuel schedule (RunPlan.fuelEvery): at each multiple of it in run
//  time, a critical cue ("GEL NOW · FUEL 1 OF 2"). It comes back once, 2 min
//  later, unless the runner acknowledged it with a glance or a held look in
//  between; after the repeat it is left alone. "OF 2" is how many stops fit
//  in the target time. Without fuelEvery it never fires.
//
//  Acknowledgements arrive through note(_:) (RunEngine passes every attention
//  event), so the trigger doesn't depend on how long the cue stayed up.

import Foundation

public struct FuelTrigger: Trigger {
    public struct Config: Sendable, Equatable {
        /// Seconds after a fuel cue that it comes back if not acknowledged.
        public var repeatAfter: TimeInterval = 120
        public var priority: Priority = .critical
        /// Seconds the cue stays up (design: 6 s).
        public var minShow: TimeInterval = 6
        public var expiresAfter: TimeInterval = 60

        public init() {}
    }

    public let plan: RunPlan
    public let config: Config
    /// Fuel stops proposed so far (the next one is `fired + 1`).
    public private(set) var fired = 0
    /// The latest stop's repeat, while it is still due: stop number and run time.
    public private(set) var repeatDue: (stop: Int, at: TimeInterval)?
    /// Run time the latest stop was proposed.
    private var firedAt: TimeInterval?

    public init(plan: RunPlan, config: Config = Config()) {
        self.plan = plan
        self.config = config
    }

    /// Stops that fit in the target time (at least one).
    public var stops: Int {
        guard let every = plan.fuelEvery, every > 0 else { return 0 }
        return max(1, Int(plan.targetTime / every))
    }

    /// A glance or held look after a fuel cue acknowledges it: no repeat.
    public mutating func note(_ attention: AttentionSample) {
        guard attention.event != .idle, let at = firedAt, attention.t >= at else { return }
        repeatDue = nil
    }

    public mutating func evaluate(state s: RunState, at t: TimeInterval) -> [Cue] {
        guard let every = plan.fuelEvery, every > 0 else { return [] }
        var cues: [Cue] = []
        if let due = repeatDue, t >= due.at {
            repeatDue = nil
            cues.append(cue(stop: due.stop, at: t))
        }
        if t >= Double(fired + 1) * every {
            fired += 1
            firedAt = t
            repeatDue = (fired, t + config.repeatAfter)
            cues.append(cue(stop: fired, at: t))
        }
        return cues
    }

    private func cue(stop: Int, at t: TimeInterval) -> Cue {
        Cue(key: .fuel(stop),
            priority: config.priority,
            reveal: .auto,
            content: CueContent(main: .label("GEL NOW"),
                                subtitle: [.label("FUEL \(stop) OF \(max(stops, stop))")],
                                tag: "FUEL",
                                icon: .drop),
            createdAt: t,
            expiresAt: t + config.expiresAfter,
            minShow: config.minShow)
    }
}
