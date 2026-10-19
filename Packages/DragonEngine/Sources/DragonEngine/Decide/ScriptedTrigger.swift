//  ScriptedTrigger.swift
//  The cycling and SOF demos as an ordinary trigger: each Scenario card's
//  time window and reveal become cue proposals.
//
//    - .auto cards are proposed on every evaluate while the scenario clock is
//      in their window (and the scenario is running), unless already on screen.
//    - .glance / .dwell cards are proposed when the runner asks (request):
//      the card in its window for that reveal, else the first one not yet seen.
//      A held look also answers with glance cards.
//
//  The scenario clock is scenario seconds, moved only by advance(by:) while
//  running, and starts over (forgetting which cards were seen) after the
//  loop. Proposed cues expire at once: shown now or not at all. They are meant
//  for an Arbiter configured with `Arbiter.Config.scripted`, where the newest
//  card takes the screen, as the demo cards always have.

import Foundation

public struct ScriptedTrigger: Trigger {
    public struct Config: Sendable, Equatable {
        /// Scenario seconds before the script starts over.
        public var loopLength: Double = 40
        /// Seconds a card answering a glance / a held look stays up. An .auto card
        /// stays the glance time, and comes straight back if its window is still open.
        public var glanceShow: TimeInterval = 5
        public var dwellShow: TimeInterval = 8
        /// .auto cards are the engine forcing something (safety-critical in the demos);
        /// requested cards are information the runner asked for.
        public var autoPriority: Priority = .critical
        public var requestedPriority: Priority = .info

        public init() {}
    }

    public let config: Config
    public private(set) var scenario: Scenario
    /// The scenario clock only moves while running.
    public var running = false
    /// Scenario seconds since the script (re)started.
    public private(set) var clock: Double = 0
    /// Cards shown since the script (re)started.
    public private(set) var seen: Set<String> = []
    /// What is on screen; set by the coordinator before evaluate, so an .auto
    /// card already up is not proposed again.
    public var showing: CueKey?

    public init(scenario: Scenario, config: Config = Config()) {
        self.scenario = scenario
        self.config = config
    }

    /// Back to the start of the script, paused.
    public mutating func reset(to scenario: Scenario? = nil) {
        if let scenario { self.scenario = scenario }
        running = false
        clock = 0
        seen = []
        showing = nil
    }

    /// Moves the scenario clock by `dt` scenario seconds when running; past the
    /// loop it starts over and every card is unseen again.
    public mutating func advance(by dt: Double) {
        guard running else { return }
        clock += dt
        if clock > config.loopLength {
            clock = 0
            seen = []
        }
    }

    /// The card answering a glance or a held look at run time `t`, if any.
    /// Idle asks for nothing.
    public mutating func request(_ event: AttentionEvent, at t: TimeInterval) -> Cue? {
        let want: [Reveal]
        switch event {
        case .glance: want = [.glance]
        case .dwell: want = [.dwell, .glance]
        case .idle: return nil
        }
        guard let card = scenario.cards.first(where: { want.contains($0.reveal) && $0.window.contains(clock) })
            ?? scenario.cards.first(where: { want.contains($0.reveal) && !seen.contains($0.id) })
        else { return nil }
        seen.insert(card.id)
        return cue(for: card, priority: config.requestedPriority,
                   show: event == .dwell ? config.dwellShow : config.glanceShow, at: t)
    }

    /// The .auto cards whose window is open, while running.
    public mutating func evaluate(state: RunState, at t: TimeInterval) -> [Cue] {
        guard running else { return [] }
        return scenario.cards
            .filter { $0.reveal == .auto && $0.window.contains(clock) && showing != .scripted($0.id) }
            .map { card in
                seen.insert(card.id)
                return cue(for: card, priority: config.autoPriority, show: config.glanceShow, at: t)
            }
    }

    /// The scenario card behind a cue key, if it is one of this scenario's.
    public func card(for key: CueKey?) -> ContextCard? {
        guard case .scripted(let id)? = key else { return nil }
        return scenario.cards.first { $0.id == id }
    }

    /// The quiet screen for this scenario: the dashboard standing still, else the ambient read-out.
    public func quietScreen(band: MotionBand, motion: Double, heartRate: Int) -> QuietScreen {
        if band == .stationary { return .dashboard(title: scenario.name, rows: scenario.dashboard) }
        let a = scenario.ambient(band, motion, heartRate)
        return .ambient(big: a.big, unit: a.unit, sub: a.sub)
    }

    /// A card as a cue. It holds the screen for `show` seconds inclusive (the
    /// demos' cards were up until strictly after that time, and the arbiter frees
    /// the screen at exactly minShow, hence the next representable value).
    public func cue(for card: ContextCard, priority: Priority, show: TimeInterval, at t: TimeInterval) -> Cue {
        Cue(key: .scripted(card.id),
            priority: priority,
            reveal: card.reveal,
            content: CueContent(main: .label(card.line1), subtitle: [.label(card.line2)], tag: card.tag,
                                icon: card.glyph),
            createdAt: t,
            expiresAt: t,
            minShow: show.nextUp)
    }
}
