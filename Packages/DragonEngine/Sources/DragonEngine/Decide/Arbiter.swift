//  Arbiter.swift
//  Stage 4 of the pipeline (Estimate → Trigger → Capacity → Arbiter → Render):
//  at most one cue on screen, chosen by fixed rules, applied in order on
//  every decision:
//
//    1. Empty budget means nothing shows: only safety cues get through (and
//       nothing under the budget's minPriority, except an answer to a glance or
//       held look when the budget answers requests). A cue that needs a
//       reading the budget calls unreliable (GPS, heart rate) is held back too.
//    2. Highest priority wins; ties go to the biggest gap from plan, then to
//       the cue that has waited longest.
//    3. Respect cooldowns: a key that just showed is held back for 90 s, and
//       longer after the runner dismissed it than after it was ignored.
//    4. Let a cue finish: a showing cue keeps the screen for its minimum time
//       unless something more important arrives (and the budget allows it).
//       In the race's final stretch (budget.finalStretch) a cue other than
//       safety is dropped, not held back: it could never show before the finish.
//    5. Drop stale cues: one that can't show by its expiresAt is skipped, not
//       shown late. That holds for deferred cues too.
//    6. Log everything: every cue in play gets a Decision on every call —
//       shown, held back or expired, with the reason — until it leaves play.
//
//  Two more, off unless configured (RunEngine sets them from its segue
//  settings, chunk 14):
//    - Quiet gap: once a cue leaves the screen, the next waits `quietGap`
//      seconds, unless it is safety or critical (`quietGapExempt`) or an
//      answer the runner asked for (Cue.requested).
//    - Heads-up: a predictable cue (CueKind.isPredictable) about to take the
//      screen is first announced, and takes it `headsUpLead` seconds later;
//      meanwhile the screen is kept for it. A cue its trigger announced ahead
//      of time (announce(_:at:), from an Upcoming hint) shows on arrival once
//      its announcement has run the lead; an announcement that runs past the
//      lead by `headsUpTolerance` (or one update, when updates are coarser)
//      without its cue lapses, and the cue gets a fresh one when it can show.
//      headsUp(at:) is the announcement running.
//    The quiet gap doesn't follow a withdrawal (the kick clock at the line):
//    the result it gives way to shows at once.
//
//  A value like the estimator and the triggers: all its state is in the
//  struct and it never reads the clock, only the run time it is given.

import Foundation

/// What the arbiter did with one cue on one call, and why. Chunk 8's cue log
/// keeps these.
public struct Decision: Sendable, Equatable, Codable {
    public enum Outcome: String, Sendable, Codable, CaseIterable {
        /// On screen now (just went up, or still within its minimum time).
        case shown
        /// Still in play, not on screen; it may show on a later call.
        case heldBack
        /// Out of play for good: stale, replaced, finished, cut short or dismissed.
        case expired
    }

    public enum Reason: Sendable, Equatable, Codable {
        // Shown.
        /// The best cue the budget allows, and the screen was free.
        case won
        /// More important than the cue it cut short.
        case interrupted(CueKey)
        /// Keeps the screen for its minimum time, until this run time.
        case onScreen(until: TimeInterval)

        // Held back.
        /// Empty budget: only safety gets through.
        case budgetEmpty
        /// Under the budget's lowest allowed priority.
        case belowBudget(Priority)
        /// Needs a reading that is unreliable right now.
        case unreliable(CueInput)
        /// The same key showed recently.
        case coolingDown(until: TimeInterval)
        /// Waiting for its condition.
        case deferred(Deferral)
        /// Another cue ranked higher.
        case outranked(by: CueKey)
        /// Another cue holds the screen for its minimum time.
        case screenBusy(by: CueKey)
        /// The screen stays dark a moment after the last cue left, until this run time.
        case quietGap(until: TimeInterval)
        /// Its heads-up is running; it shows at this run time.
        case headsUp(until: TimeInterval)

        // Expired.
        /// Couldn't show by its expiresAt.
        case stale
        /// A newer proposal with the same key took its place.
        case replaced
        /// Shown for its minimum time.
        case finished
        /// Taken down by a more important cue.
        case cutShort(by: CueKey)
        /// The runner dismissed it.
        case dismissed
        /// The budget no longer allows it while it was showing.
        case budgetClosed
        /// Not safety, in the race's final stretch: dropped, never shown (the
        /// kick clock owns the last 400 m).
        case finalStretch
        /// Its trigger took it down: what it was about is over (the kick clock
        /// at the finish line).
        case withdrawn

        public var outcome: Outcome {
            switch self {
            case .won, .interrupted, .onScreen: return .shown
            case .budgetEmpty, .belowBudget, .unreliable, .coolingDown, .deferred, .outranked, .screenBusy,
                 .quietGap, .headsUp:
                return .heldBack
            case .stale, .replaced, .finished, .cutShort, .dismissed, .budgetClosed, .finalStretch, .withdrawn:
                return .expired
            }
        }
    }

    /// Run time of the decision.
    public var t: TimeInterval
    public var key: CueKey
    public var priority: Priority
    public var reason: Reason

    public init(t: TimeInterval, key: CueKey, priority: Priority, reason: Reason) {
        self.t = t
        self.key = key
        self.priority = priority
        self.reason = reason
    }

    public var outcome: Outcome { reason.outcome }

    /// The reason in words, for logs and the debug overlay.
    public var text: String {
        func secs(_ s: TimeInterval) -> String { "\(Int(max(0, s).rounded(.up))) s" }
        switch reason {
        case .won: return "highest priority the budget allows"
        case .interrupted(let other): return "more important than the \(other.name)"
        case .onScreen(let until): return "keeps the screen for its minimum time (\(secs(until - t)) more)"
        case .budgetEmpty: return "empty budget: only safety gets through"
        case .belowBudget(let p): return "budget allows \(p) and up"
        case .unreliable(let input): return "\(input == .gps ? "GPS" : "heart rate") unreliable right now"
        case .coolingDown(let until): return "in its cooldown for \(secs(until - t)) more"
        case .deferred(let d):
            switch d {
            case .time(let at): return "deferred for \(secs(at - t))"
            case .distance(let m): return String(format: "deferred until %.0f m", m)
            case .released: return "deferred until released"
            }
        case .outranked(let other): return "outranked by the \(other.name)"
        case .screenBusy(let other): return "the \(other.name) holds the screen for its minimum time"
        case .quietGap(let until): return "a quiet moment after the last cue (\(secs(until - t)) more)"
        case .headsUp(let until): return "heads-up first; shows in \(String(format: "%.1f", max(0, until - t))) s"
        case .stale: return "couldn't show in time; skipped, not shown late"
        case .replaced: return "replaced by a newer proposal"
        case .finished: return "shown for its minimum time"
        case .cutShort(let other): return "cut short by the \(other.name)"
        case .dismissed: return "dismissed by the runner"
        case .budgetClosed: return "budget no longer allows it"
        case .finalStretch: return "final 400 m: only safety until the finish"
        case .withdrawn: return "taken down by its trigger: what it was about is over"
        }
    }
}

public struct Arbiter: Sendable {
    public struct Config: Sendable, Equatable {
        /// Seconds a key is held back after it showed and was ignored (design: one
        /// pace cue per 90 s). Splits have a key per marker, so this only bites
        /// on cues that repeat, like the pace gap.
        public var cooldown: TimeInterval = 90
        /// Seconds a key is held back after the runner dismissed it, counted from
        /// the dismissal. Longer than `cooldown`: they said they don't want it.
        public var dismissedCooldown: TimeInterval = 180
        /// The scripted demos' rule in place of rule 4: a cue proposed on this call
        /// takes the screen whatever is up and whatever its priority, the way the
        /// demo cards always replaced each other (re-proposing the cue on screen
        /// restarts it). Rules 1, 3 and 5 still apply. Off for races.
        public var newestWins = false
        /// Seconds the screen stays dark after a cue leaves before the next may
        /// take it; 0 = off. RunEngine sets SegueConfig.quietGap (1.5 s).
        public var quietGap: TimeInterval = 0
        /// Cues at or above this priority don't wait out the quiet gap (nor do answers).
        public var quietGapExempt: Priority = .critical
        /// Seconds a predictable cue is announced before it shows (its heads-up);
        /// 0 = no heads-ups. RunEngine sets SegueConfig.headsUpLead (1.5 s) while
        /// the HeadsUp setting is on.
        public var headsUpLead: TimeInterval = 0
        /// Seconds past the lead an announcement still counts before it lapses.
        public var headsUpTolerance: TimeInterval = 0.2

        public init() {}

        /// For ScriptedTrigger's demo cards: no cooldowns, the newest card wins.
        public static var scripted: Config {
            var c = Config()
            c.cooldown = 0
            c.dismissedCooldown = 0
            c.newestWins = true
            return c
        }
    }

    /// Fixed for the scripted demos; RunEngine changes the quiet gap and heads-up lead with its settings.
    public internal(set) var config: Config
    /// On screen now.
    public private(set) var showing: Cue?
    /// Run time `showing` went up.
    public private(set) var shownAt: TimeInterval = 0
    /// In play and not on screen, oldest first.
    public private(set) var waiting: [Cue] = []
    /// Run time each key's cooldown ends.
    public private(set) var cooldownUntil: [CueKey: TimeInterval] = [:]
    /// Decisions made between calls (a dismissal), reported by the next decide.
    private var pending: [Decision] = []
    private var pendingCues: [Cue] = []
    /// The cue each of the last decide's decisions was about, in the same order.
    /// A Decision names only the key, and two cues with one key can be in play
    /// at once (one on screen, a newer one waiting); the cue log tells them apart.
    public private(set) var decided: [Cue] = []
    /// Run time the screen last became free (a cue finished, was dismissed, …); nil before the first.
    public private(set) var clearedAt: TimeInterval?
    /// Heads-ups running: run time each key was announced.
    public private(set) var announced: [CueKey: TimeInterval] = [:]
    /// Cues the last decide held for their heads-up: theirs doesn't lapse
    /// while they wait it out (an update can come later than the lead).
    private var waitingOutHeadsUp: Set<CueKey> = []
    /// Run time of the last decide, and the seconds between the last two.
    private var lastDecideAt: TimeInterval?
    public private(set) var updateInterval: TimeInterval = 0

    public init(config: Config = Config()) {
        self.config = config
    }

    /// The runner dismissed what is on screen: it comes down now and its key
    /// cools down for `dismissedCooldown`. Reported in the next decide's
    /// decisions. Returns false if nothing was showing.
    @discardableResult
    public mutating func dismiss(at t: TimeInterval) -> Bool {
        guard let c = showing else { return false }
        showing = nil
        clearedAt = t
        cooldownUntil[c.key] = max(cooldownUntil[c.key] ?? 0, t + config.dismissedCooldown)
        pending.append(Decision(t: t, key: c.key, priority: c.priority, reason: .dismissed))
        pendingCues.append(c)
        return true
    }

    /// Takes every cue with this key out of play, on screen or waiting: its
    /// trigger says what it was about is over. Reported in the next decide's
    /// decisions (as `.withdrawn`); no cooldown.
    public mutating func withdraw(_ key: CueKey, at t: TimeInterval) {
        if let c = showing, c.key == key {
            // No quiet gap after a withdrawal: what it was about is over and
            // its successor (the result after the kick clock) takes over at once.
            showing = nil
            pending.append(Decision(t: t, key: c.key, priority: c.priority, reason: .withdrawn))
            pendingCues.append(c)
        }
        waiting.removeAll { cue in
            guard cue.key == key else { return false }
            pending.append(Decision(t: t, key: cue.key, priority: cue.priority, reason: .withdrawn))
            pendingCues.append(cue)
            return true
        }
    }

    /// Starts the heads-up for `key` at `t` (its trigger expects it in the
    /// lead time), unless one is already running for it.
    public mutating func announce(_ key: CueKey, at t: TimeInterval) {
        guard config.headsUpLead > 0, fresh(key, at: t) == nil, !waitingOutHeadsUp.contains(key) else { return }
        announced[key] = t
    }

    /// The heads-up running at `t`, if any: the latest announcement that hasn't lapsed.
    public func headsUp(at t: TimeInterval) -> (key: CueKey, since: TimeInterval)? {
        announced.filter { $0.value <= t && (t - $0.value <= config.headsUpLead + slack
                                             || waitingOutHeadsUp.contains($0.key)) }
            .max { $0.value < $1.value || $0.value == $1.value && $0.key.name < $1.key.name }
            .map { ($0.key, $0.value) }
    }

    /// The earliest run time a cue like this could take the screen, as far as
    /// the cue on screen, the quiet gap and its key's cooldown say (the budget
    /// can still hold it back). `interrupts`: the budget lets a more important
    /// cue cut the one on screen short.
    public func freeAt(priority: Priority, key: CueKey, requested: Bool = false, interrupts: Bool,
                       at t: TimeInterval) -> TimeInterval {
        var at = t
        let gap = exempt(priority: priority, requested: requested) ? 0 : config.quietGap
        if let c = showing {
            if !(priority > c.priority && (interrupts || priority == .safety)) {
                at = max(at, shownAt + c.minShow + gap)
            }
        } else if let cleared = clearedAt {
            at = max(at, cleared + gap)
        }
        if let until = cooldownUntil[key] { at = max(at, until) }
        return at
    }

    private func exempt(priority: Priority, requested: Bool) -> Bool {
        requested || priority >= config.quietGapExempt
    }

    /// When `key`'s heads-up started, if it is still running at `t`.
    private func fresh(_ key: CueKey, at t: TimeInterval) -> TimeInterval? {
        guard let since = announced[key], t - since <= config.headsUpLead + slack else { return nil }
        return since
    }

    /// How far past the lead an announcement still counts: the tolerance,
    /// or with updates coarser than twice that (a 1 s replay), one update
    /// interval, since the cue can only show on an update.
    public var slack: TimeInterval {
        updateInterval > 2 * config.headsUpTolerance ? updateInterval : config.headsUpTolerance
    }

    /// Lets a waiting cue deferred `.released` show. No effect on anything else.
    public mutating func release(_ key: CueKey) {
        for i in waiting.indices where waiting[i].key == key && waiting[i].deferUntil == .released {
            waiting[i].deferUntil = nil
        }
    }

    /// Takes this call's proposals and decides what is on screen at run time `t`.
    /// `distance` (metres covered) is what `.distance` deferrals wait for.
    /// Every cue in play — the one showing, those waiting and the new ones —
    /// gets exactly one decision. Call with non-decreasing `t`.
    public mutating func decide(_ candidates: [Cue], budget: Budget, at t: TimeInterval,
                                distance: Double? = nil) -> (showing: Cue?, decisions: [Decision]) {
        var out = pending
        var cues = pendingCues
        pending = []
        pendingCues = []
        func record(_ c: Cue, _ reason: Decision.Reason) {
            out.append(Decision(t: t, key: c.key, priority: c.priority, reason: reason))
            cues.append(c)
        }
        defer { decided = cues }
        if let last = lastDecideAt, t > last { updateInterval = t - last }
        lastDecideAt = t
        announced = announced.filter {
            t - $0.value <= config.headsUpLead + slack || waitingOutHeadsUp.contains($0.key)
        }
        let waitedOut = waitingOutHeadsUp
        waitingOutHeadsUp = []

        // Rule 4 (end of it) and rule 1 for the cue on screen.
        if let c = showing {
            if t - shownAt >= c.minShow {
                record(c, .finished)
                showing = nil
            } else if !budget.admits(c) {
                record(c, budget.finalStretch ? .finalStretch : .budgetClosed)
                showing = nil
            } else if budget.finalStretch && c.priority != .safety {
                record(c, .finalStretch)
                showing = nil
            }
            if showing == nil { clearedAt = t }
        }

        // New proposals join the queue; one per key, the newest.
        for cue in candidates {
            if let i = waiting.firstIndex(where: { $0.key == cue.key }) {
                record(waiting.remove(at: i), .replaced)
            }
            waiting.append(cue)
        }

        // Rule 5: stale cues leave play.
        waiting.removeAll { cue in
            guard t > cue.expiresAt else { return false }
            record(cue, .stale)
            return true
        }

        // Rule 1 in the final stretch: everything but safety leaves play.
        if budget.finalStretch {
            waiting.removeAll { cue in
                guard cue.priority != .safety else { return false }
                record(cue, .finalStretch)
                return true
            }
        }

        // Rules 1, 3 and deferral: what may show at all.
        var held: [Int: Decision.Reason] = [:]
        for (i, cue) in waiting.enumerated() {
            if !budget.admits(cue) {
                held[i] = budget.isEmpty ? .budgetEmpty : .belowBudget(budget.minPriority)
            } else if let input = budget.distrusted(cue) {
                held[i] = .unreliable(input)
            } else if let until = cooldownUntil[cue.key], t < until {
                held[i] = .coolingDown(until: until)
            } else if let wait = cue.deferUntil, !Arbiter.ready(wait, at: t, distance: distance) {
                held[i] = .deferred(wait)
            }
        }

        // The quiet gap: a free screen stays dark a moment after the last cue left.
        let gapUntil = showing == nil && config.quietGap > 0 ? clearedAt.map { $0 + config.quietGap } : nil
        if let g = gapUntil, t < g {
            for (i, cue) in waiting.enumerated() where held[i] == nil && !exempt(priority: cue.priority, requested: cue.requested) {
                held[i] = .quietGap(until: g)
            }
        }

        // Heads-up: a predictable cue about to take the screen is announced
        // first and takes it once its heads-up has run the lead. Until then
        // the screen is kept for it.
        func headsUpDone(_ i: Int) -> Bool {
            let cue = waiting[i]
            guard config.headsUpLead > 0, cue.key.kind.isPredictable else { return true }
            let since = (waitedOut.contains(cue.key) ? announced[cue.key] : nil) ?? fresh(cue.key, at: t) ?? t
            announced[cue.key] = since
            guard t + 1e-6 < since + config.headsUpLead else { return true }
            held[i] = .headsUp(until: since + config.headsUpLead)
            waitingOutHeadsUp.insert(cue.key)
            return false
        }
        // A predictable cue waiting for the screen: announced so its heads-up
        // has run the lead when the screen frees at `freeAt`.
        func announceAhead(_ cue: Cue, freeAt: TimeInterval) {
            guard cue.key.kind.isPredictable, t >= freeAt - config.headsUpLead else { return }
            announce(cue.key, at: t)
        }

        // Rule 2: the best of the rest (scripted: the best of this call's proposals, if any may show).
        let proposed = Set(candidates.map(\.key))       // one waiting cue per key: the newest
        var best: Int?
        for i in waiting.indices where held[i] == nil {
            if best.map({ Arbiter.outranks(waiting[i], waiting[$0]) }) ?? true { best = i }
        }
        if config.newestWins, let newest = waiting.indices.filter({ proposed.contains(waiting[$0].key) && held[$0] == nil })
            .reduce(nil as Int?, { b, i in b.map { Arbiter.outranks(waiting[i], waiting[$0]) ? i : $0 } ?? i }) {
            best = newest
        }

        // Rule 4: the cue on screen keeps it unless the best is more important
        // (scripted: unless the best was proposed on this call).
        var winner: Int?
        if let b = best {
            if let c = showing {
                let more = waiting[b].priority > c.priority
                let newest = config.newestWins && proposed.contains(waiting[b].key)
                if newest || (more && (budget.allowInterrupt || waiting[b].priority == .safety)) {
                    if headsUpDone(b) {
                        record(c, c.key == waiting[b].key ? .replaced : .cutShort(by: waiting[b].key))
                        winner = b
                        held[b] = .interrupted(c.key)
                    } else {
                        record(c, .onScreen(until: shownAt + c.minShow))
                    }
                } else {
                    record(c, .onScreen(until: shownAt + c.minShow))
                    let cue = waiting[b]
                    announceAhead(cue, freeAt: shownAt + c.minShow
                                  + (exempt(priority: cue.priority, requested: cue.requested) ? 0 : config.quietGap))
                    for i in waiting.indices where held[i] == nil { held[i] = .screenBusy(by: c.key) }
                }
            } else if headsUpDone(b) {
                winner = b
                held[b] = .won
            }
        } else if let c = showing {
            record(c, .onScreen(until: shownAt + c.minShow))
        }
        // The quiet gap's best: its heads-up runs so it shows as the gap ends.
        if best == nil, let g = gapUntil, t < g,
           let q = waiting.indices.filter({ if case .quietGap = held[$0] { return true } else { return false } })
            .reduce(nil as Int?, { b, i in b.map { Arbiter.outranks(waiting[i], waiting[$0]) ? i : $0 } ?? i }) {
            announceAhead(waiting[q], freeAt: g)
        }
        // Whoever has the screen (or has it kept for their heads-up) outranks the rest.
        if let w = winner ?? best {
            for i in waiting.indices where held[i] == nil { held[i] = .outranked(by: waiting[w].key) }
        }

        // Rule 6: one decision for each waiting cue, in queue order.
        for (i, cue) in waiting.enumerated() {
            if let reason = held[i] { record(cue, reason) }
        }
        if let w = winner {
            let cue = waiting.remove(at: w)
            showing = cue
            shownAt = t
            announced[cue.key] = nil
            cooldownUntil[cue.key] = max(cooldownUntil[cue.key] ?? 0, t + config.cooldown)
        }
        return (showing, out)
    }

    /// Strictly ahead of `b`: higher priority, else a bigger gap from plan.
    /// Equal on both keeps the earlier one (it has waited longer).
    static func outranks(_ a: Cue, _ b: Cue) -> Bool {
        if a.priority != b.priority { return a.priority > b.priority }
        return abs(a.planGap ?? 0) > abs(b.planGap ?? 0)
    }

    static func ready(_ d: Deferral, at t: TimeInterval, distance: Double?) -> Bool {
        switch d {
        case .time(let at): return t >= at
        case .distance(let m): return distance.map { $0 >= m } ?? false
        case .released: return false
        }
    }
}
