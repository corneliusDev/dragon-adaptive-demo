//  AdaptiveEngine.swift
//  The scenario demos (cycling / SOF) on the pipeline: a thin adapter that
//  keeps today's API for the app and the characterisation tests. The cards
//  are proposed by ScriptedTrigger, chosen by an Arbiter with the scripted
//  rules (newest card wins, no cooldowns), and drawn by Renderer; what is left
//  here is the demo's own state: the motion reading, the heart rate estimate,
//  the attention read-out and the flywheel count.
//  Clock-free: every call that cares about time takes run time `t`
//  (seconds since run start, monotonic) from the caller.

import Foundation

public enum MotionBand: Int, Sendable {
    case stationary, light, moderate, hard

    /// Band for a 0–100 motion/exertion reading.
    public init(motion: Double) {
        switch motion {
        case ..<6:
            self = .stationary
        case ..<38:
            self = .light
        case ..<72:
            self = .moderate
        default:
            self = .hard
        }
    }

    public var label: String {
        ["STATIONARY", "LIGHT", "MODERATE", "HARD"][rawValue]
    }
}

public final class AdaptiveEngine {
    /// The demos have no capacity model: every card gets its full layout.
    public static let budget = Budget.relaxed
    /// Seconds a glance / a held look stays the attention read-out.
    public static let glanceHold: TimeInterval = 1.5
    public static let dwellHold: TimeInterval = 2.6

    public private(set) var trigger: ScriptedTrigger
    public private(set) var arbiter = Arbiter(config: .scripted)
    public var scenario: Scenario { trigger.scenario }
    public var motion: Double = 0

    /// Latest real HR reading, or nil when none is fresh.
    public var measuredHeartRate: Int?

    /// Falls back to an estimate from motion when no reading is available.
    public var heartRate: Int { measuredHeartRate ?? Int(96 + motion * 0.92) }

    public private(set) var attention: AttentionEvent = .idle
    private var attnUntil: TimeInterval?          // run time when attention falls back to idle
    private var lastT: TimeInterval = 0

    /// Cards shown for their full time (the flywheel the cue log will replace).
    public private(set) var flywheel = 0
    public var onFlywheel: ((Int) -> Void)?

    public init(scenario: Scenario) {
        trigger = ScriptedTrigger(scenario: scenario)
    }

    public var band: MotionBand { MotionBand(motion: motion) }

    public var running: Bool {
        get { trigger.running }
        set { trigger.running = newValue }
    }

    /// Scenario seconds, loops at 40.
    public var clock: Double { trigger.clock }

    /// The card on screen.
    public var active: ContextCard? { trigger.card(for: arbiter.showing?.key) }

    public func setScenario(_ s: Scenario) {
        reset()
        trigger.reset(to: s)
    }

    public func reset() {
        attention = .idle
        attnUntil = nil
        arbiter = Arbiter(config: .scripted)
        flywheel = 0
        trigger.reset()
    }

    // MARK: - Attention

    /// Applies an attention event that arrived at run time `t`: a glance or a
    /// held look puts up the card that answers it straight away.
    public func handle(_ e: AttentionEvent, at t: TimeInterval) {
        attention = e
        guard e == .glance || e == .dwell else { return }
        attnUntil = t + (e == .dwell ? AdaptiveEngine.dwellHold : AdaptiveEngine.glanceHold)
        if let cue = trigger.request(e, at: t) {
            _ = arbiter.decide([cue], budget: AdaptiveEngine.budget, at: t)
        }
    }

    // MARK: - Tick

    /// Advances the scenario clock by `dt` (when running), lets attention and
    /// cards time out against run time `t`, and returns the frame to draw.
    public func tick(dt: Double, at t: TimeInterval) -> HUDFrame {
        lastT = t
        trigger.advance(by: dt)

        if let until = attnUntil, t > until {
            attention = .idle
            attnUntil = nil
        }

        // Cards whose time is up come down first; then the open windows propose.
        let finished = arbiter.decide([], budget: AdaptiveEngine.budget, at: t).decisions
            .filter { $0.reason == .finished }.count
        if finished > 0 {
            flywheel += finished
            onFlywheel?(flywheel)
        }
        trigger.showing = arbiter.showing?.key
        let proposed = trigger.evaluate(state: state(at: t), at: t)
        let shown = proposed.isEmpty ? arbiter.showing
            : arbiter.decide(proposed, budget: AdaptiveEngine.budget, at: t).showing
        // A card the engine forces clears the attention read-out.
        if let s = shown, s.reveal == .auto, arbiter.shownAt == t, proposed.contains(where: { $0.key == s.key }) {
            attention = .idle
        }
        return render()
    }

    // MARK: - Render

    public func render() -> HUDFrame {
        Renderer.frame(for: arbiter.showing, budget: AdaptiveEngine.budget, state: state(at: lastT), unit: .miles,
                       quiet: trigger.quietScreen(band: band, motion: motion, heartRate: heartRate))
    }

    /// What the renderer needs to know of the demo: the effort band.
    private func state(at t: TimeInterval) -> RunState {
        RunState(elapsed: t, distance: 0, effort: band)
    }
}
