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
            case .budgetEmpty, .belowBudget, .unreliable, .coolingDown, .deferred, .outranked, .screenBusy: return .heldBack
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

    public let config: Config
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
                    record(c, c.key == waiting[b].key ? .replaced : .cutShort(by: waiting[b].key))
                    winner = b
                    held[b] = .interrupted(c.key)
                } else {
                    record(c, .onScreen(until: shownAt + c.minShow))
                    for i in waiting.indices where held[i] == nil { held[i] = .screenBusy(by: c.key) }
                }
            } else {
                winner = b
                held[b] = .won
            }
        } else if let c = showing {
            record(c, .onScreen(until: shownAt + c.minShow))
        }
        if let w = winner {
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
