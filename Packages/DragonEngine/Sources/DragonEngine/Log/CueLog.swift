//  CueLog.swift
//  The cue log: every decision of a run, with the state it was made in, what
//  the runner did about it, and whether it helped. The design's "one record
//  per decision": held-back and expired cues are logged too, because knowing
//  what was safe to skip matters as much as knowing what helped. It replaces
//  the demo's flywheel counter, and it is what thresholds get tuned from.
//
//  A CueEvent is one decision, or a run of identical ones: the arbiter decides
//  about every cue in play on every update, so a split waiting out a cooldown
//  gets the same "held back, cooling down until 1:02:10" once a second (or 20
//  times a second, in the app). Consecutive identical decisions about the same
//  cue are one event with a `count` and the run time of the first and the last
//  (`t` … `through`), so the log's size follows what happened, not the update
//  rate. Nothing is dropped: the counts add up to every Decision the arbiter made.
//
//  CueLogger builds the log as the run goes (RunEngine owns one); CueLog is
//  the finished value: Codable, saved as JSON lines (one header line, then one
//  event per line), summarised by RunSummary. Like the rest of the engine it
//  never reads the clock.

import Foundation

/// What the runner did about a cue that went on screen.
public enum CueResponse: String, Sendable, Codable, CaseIterable {
    /// Glanced at it within the response window of it appearing.
    case glanced
    /// Held a look at it within the window.
    case heldLook
    /// Left the screen with no attention in the window.
    case ignored
    /// Dismissed it (at any time while it showed).
    case dismissed
}

/// The runner's answer after the race, per cue.
public enum CueRating: String, Sendable, Codable, CaseIterable {
    case tooMuch, justRight, tooLittle
}

/// The cue a log event is about.
public struct LoggedCue: Sendable, Equatable, Codable {
    /// Serial number of this cue within the run (one per proposal), so the
    /// events about one cue can be found when another with the same key is in play.
    public var id: Int
    public var key: CueKey
    public var kind: CueKind
    public var priority: Priority
    public var content: CueContent
    /// Run time it was proposed, and after which it was stale.
    public var createdAt: TimeInterval
    public var expiresAt: TimeInterval

    public init(id: Int, cue: Cue) {
        self.id = id
        key = cue.key
        kind = cue.key.kind
        priority = cue.priority
        content = cue.content
        createdAt = cue.createdAt
        expiresAt = cue.expiresAt
    }
}

/// The part of RunState (and the budget) worth keeping with a decision:
/// "mi 10.5 · +0:48 · HR 171 · moderate". Rounded to what is worth reading
/// back (0.1 m, 0.1 s, 0.0001 s/m, 1 bpm), which keeps the log small.
public struct CueStateSnapshot: Sendable, Equatable, Codable {
    public var elapsed: TimeInterval
    public var distance: Double
    /// Seconds per metre over the last 30 s.
    public var pace: Double?
    /// Projected finish − target: + = behind.
    public var gap: TimeInterval?
    public var heartRate: Double?
    public var zone: Int?
    public var effort: MotionBand
    public var effortScore: Double?
    public var phase: MovementPhase
    public var budget: Budget
    public var situation: Capacity.Situation?

    public init(_ s: RunState, budget: Budget, situation: Capacity.Situation? = nil) {
        func round(_ x: Double?, _ step: Double) -> Double? { x.map { ($0 / step).rounded() * step } }
        elapsed = s.elapsed
        distance = round(s.distance, 0.1)!
        pace = round(s.pace30s, 0.0001)
        gap = round(s.gapToTarget, 0.1)
        heartRate = round(s.heartRate, 1)
        zone = s.heartZone
        effort = s.effort
        effortScore = round(s.effortScore, 0.1)
        phase = s.phase
        self.budget = budget
        self.situation = situation
    }
}

/// Did it help: how the number a cue was about moved in the minute after it showed.
public struct CueOutcome: Sendable, Equatable, Codable {
    public enum Measure: String, Sendable, Codable {
        /// Projected finish − target, seconds (+ = behind). Improved = closer to 0.
        case gap
        /// bpm. Improved = lower.
        case heartRate
    }

    public var measure: Measure
    /// Run time the cue went on screen, and of the reading `after` (≈ shownAt + 60 s).
    public var shownAt: TimeInterval
    public var at: TimeInterval
    public var atShow: Double?
    public var after: Double?
    /// after − atShow; nil if either is unknown.
    public var delta: Double?
    /// nil if either is unknown.
    public var improved: Bool?

    public init(measure: Measure, shownAt: TimeInterval, at: TimeInterval, atShow: Double?, after: Double?) {
        self.measure = measure
        self.shownAt = shownAt
        self.at = at
        self.atShow = atShow
        self.after = after
        if let a = atShow, let b = after {
            delta = b - a
            improved = measure == .gap ? abs(b) < abs(a) : b < a
        }
    }

    /// The reading this measure takes from a state.
    static func value(_ measure: Measure, _ s: RunState) -> Double? {
        switch measure {
        case .gap: return s.gapToTarget
        case .heartRate: return s.heartRate
        }
    }
}

/// One decision about one cue (or a run of identical consecutive ones).
public struct CueEvent: Sendable, Equatable, Codable {
    public var cue: LoggedCue
    public var decision: Decision.Outcome
    public var reason: Decision.Reason
    /// Run time of the first decision in the run, and of the last.
    public var t: TimeInterval
    public var through: TimeInterval
    /// Decisions this event stands for (1 unless identical ones followed).
    public var count: Int
    /// The state at the first.
    public var state: CueStateSnapshot
    /// Set on the event where the cue went on screen (won or interrupted).
    public var response: CueResponse?
    public var outcome: CueOutcome?
    public var rating: CueRating?

    public init(cue: LoggedCue, reason: Decision.Reason, t: TimeInterval, through: TimeInterval? = nil,
                count: Int = 1, state: CueStateSnapshot, response: CueResponse? = nil,
                outcome: CueOutcome? = nil, rating: CueRating? = nil) {
        self.cue = cue
        decision = reason.outcome
        self.reason = reason
        self.t = t
        self.through = through ?? t
        self.count = count
        self.state = state
        self.response = response
        self.outcome = outcome
        self.rating = rating
    }

    /// The decision that went on screen (rather than one that kept it there).
    public var appeared: Bool {
        switch reason {
        case .won, .interrupted: return true
        default: return false
        }
    }

    /// The first decision of the run, as the arbiter made it.
    public var firstDecision: Decision {
        Decision(t: t, key: cue.key, priority: cue.priority, reason: reason)
    }

    /// The reason in words ("outranked by the pace gap").
    public var text: String { firstDecision.text }
}

public struct CueLog: Sendable, Equatable, Codable {
    /// The first line of a saved log: what run it was.
    public struct Header: Sendable, Equatable, Codable {
        /// Format version of the file.
        public var version = 1
        /// Free-form label (the synthetic profile and seed, or the race name).
        public var name: String
        public var targetTime: TimeInterval
        public var distance: Double
        public var display: DisplaySetting
        /// Run time the runner crossed the line, once known.
        public var finishTime: TimeInterval?

        public init(name: String = "", targetTime: TimeInterval, distance: Double,
                    display: DisplaySetting = .balanced, finishTime: TimeInterval? = nil) {
            self.name = name
            self.targetTime = targetTime
            self.distance = distance
            self.display = display
            self.finishTime = finishTime
        }
    }

    public var header: Header
    /// In the order they started.
    public var events: [CueEvent]

    public init(header: Header, events: [CueEvent] = []) {
        self.header = header
        self.events = events
    }

    /// The events where a cue went on screen: one per cue shown, carrying its
    /// response, outcome and rating.
    public var appearances: [CueEvent] { events.filter(\.appeared) }

    /// Decisions logged (each event counts as many as it stands for).
    public var decisionCount: Int { events.reduce(0) { $0 + $1.count } }

    /// The runner's rating for a cue that showed (by LoggedCue.id). Returns false if it never showed.
    @discardableResult
    public mutating func rate(cue id: Int, _ rating: CueRating?) -> Bool {
        guard let i = events.firstIndex(where: { $0.cue.id == id && $0.appeared }) else { return false }
        events[i].rating = rating
        return true
    }

    // MARK: JSON lines

    /// One line for the header, then one per event; sorted keys, so the same log
    /// always encodes to the same bytes.
    public func jsonLines() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var out = try encoder.encode(header)
        out.append(0x0A)
        for event in events {
            out.append(try encoder.encode(event))
            out.append(0x0A)
        }
        return out
    }

    /// Reads what jsonLines() wrote. Blank lines are skipped.
    public init(jsonLines data: Data) throws {
        let decoder = JSONDecoder()
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard let first = lines.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "empty cue log"))
        }
        header = try decoder.decode(Header.self, from: Data(first))
        events = try lines.dropFirst().map { try decoder.decode(CueEvent.self, from: Data($0)) }
    }
}

/// Builds a CueLog from the arbiter's decisions as a run goes: matches the
/// runner's attention to the cue on screen, and fills in each pace-gap and
/// heart-rate cue's outcome a minute after it showed.
public struct CueLogger: Sendable {
    public struct Config: Sendable, Equatable {
        /// Seconds after a cue appears within which a glance or held look counts
        /// as the runner's response to it (and only while it is still up).
        public var responseWindow: TimeInterval = 3
        /// Seconds after a cue shows that its outcome is read.
        public var outcomeDelay: TimeInterval = 60
        /// Kinds whose outcome is recorded, and what is measured for each.
        public var outcomes: [CueKind: CueOutcome.Measure] = [.paceGap: .gap, .heartCeiling: .heartRate]

        public init() {}
    }

    /// One proposal: a cue's key and when it was proposed.
    private struct Instance: Hashable {
        let key: CueKey
        let createdAt: TimeInterval
    }

    public let config: Config
    public private(set) var log: CueLog

    private var ids: [Instance: Int] = [:]
    /// Each cue decided about on the last call → index of its latest event, which
    /// a matching decision on this call extends.
    private var open: [Int: Int] = [:]
    /// The cue on screen: its id, when it appeared, and its appearance event.
    private var onScreen: (id: Int, at: TimeInterval, event: Int)?
    /// Appearance events still waiting for their outcome reading, and when it is due.
    private var awaiting: [(event: Int, due: TimeInterval)] = []

    public init(header: CueLog.Header, config: Config = Config()) {
        self.config = config
        log = CueLog(header: header)
    }

    /// Logs one update's decisions. `cues[i]` is the cue `decisions[i]` was about
    /// (Arbiter.decided). `state` and `budget` are what the update decided under.
    public mutating func record(_ decisions: [Decision], cues: [Cue], state: RunState, budget: Budget,
                                situation: Capacity.Situation? = nil, at t: TimeInterval) {
        precondition(decisions.count == cues.count, "one cue per decision")
        var snapshot: CueStateSnapshot?
        var touched: [Int: Int] = [:]
        for (d, cue) in zip(decisions, cues) {
            let id = self.id(for: cue)
            let i: Int
            if let last = open[id], log.events[last].reason == d.reason {
                i = last
                log.events[i].through = d.t
                log.events[i].count += 1
            } else {
                if snapshot == nil { snapshot = CueStateSnapshot(state, budget: budget, situation: situation) }
                log.events.append(CueEvent(cue: LoggedCue(id: id, cue: cue), reason: d.reason, t: d.t, state: snapshot!))
                i = log.events.count - 1
            }
            touched[id] = i

            if log.events[i].appeared && log.events[i].count == 1 {
                onScreen = (id, d.t, i)
                if let measure = config.outcomes[cue.key.kind] {
                    // Start the outcome now, with the reading at show; the rest a minute later.
                    log.events[i].outcome = CueOutcome(measure: measure, shownAt: d.t, at: d.t,
                                                       atShow: CueOutcome.value(measure, state), after: nil)
                    awaiting.append((i, d.t + config.outcomeDelay))
                }
            } else if d.outcome == .expired, let shown = onScreen, shown.id == id {
                // Off the screen: dismissed, or ignored if nothing came in the window.
                if d.reason == .dismissed {
                    log.events[shown.event].response = .dismissed
                } else if log.events[shown.event].response == nil {
                    log.events[shown.event].response = .ignored
                }
                onScreen = nil
            }
        }
        open = touched

        // Outcomes now due.
        awaiting.removeAll { item in
            guard t >= item.due, let o = log.events[item.event].outcome else { return false }
            log.events[item.event].outcome = CueOutcome(measure: o.measure, shownAt: o.shownAt, at: t,
                                                        atShow: o.atShow, after: CueOutcome.value(o.measure, state))
            return true
        }
    }

    /// An attention event. A glance or held look within the response window of
    /// the cue on screen appearing is the runner's response to it; a held look
    /// outranks a glance, and a dismissal outranks both.
    public mutating func note(_ attention: AttentionSample) {
        guard attention.event != .idle, let shown = onScreen,
              attention.t >= shown.at, attention.t - shown.at <= config.responseWindow else { return }
        let response: CueResponse = attention.event == .dwell ? .heldLook : .glanced
        switch log.events[shown.event].response {
        case nil, .glanced?: log.events[shown.event].response = response == .heldLook ? .heldLook : .glanced
        default: break
        }
    }

    /// The runner crossed the line at run time `t` (a later call replaces it).
    public mutating func finish(at t: TimeInterval) {
        log.header.finishTime = t
    }

    private mutating func id(for cue: Cue) -> Int {
        let instance = Instance(key: cue.key, createdAt: cue.createdAt)
        if let id = ids[instance] { return id }
        let id = ids.count + 1
        ids[instance] = id
        return id
    }
}
