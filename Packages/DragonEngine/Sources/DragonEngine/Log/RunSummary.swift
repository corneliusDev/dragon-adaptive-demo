//  RunSummary.swift
//  A cue log in a few numbers, for the post-race screen and for comparing runs:
//  how many cues of each kind showed, were held back or expired without
//  showing; what the runner did about the ones that showed; whether the
//  pace-gap and heart-rate cues helped; and the finish against the target.
//
//  Counts are of cues (proposals), not of decisions, so they don't depend on
//  how often the engine was updated. A cue held back and later shown counts
//  under both shown and held back; expired counts only the cues that left
//  play without ever showing (stale, replaced, dropped in the final stretch).

import Foundation

public struct RunSummary: Sendable, Equatable, Codable {
    public struct Counts: Sendable, Equatable, Codable {
        public var shown = 0
        public var heldBack = 0
        public var expired = 0

        public init(shown: Int = 0, heldBack: Int = 0, expired: Int = 0) {
            self.shown = shown
            self.heldBack = heldBack
            self.expired = expired
        }
    }

    public struct KindCounts: Sendable, Equatable, Codable {
        public var kind: CueKind
        public var counts: Counts
    }

    /// Cue kinds that appeared in the log, in CueKind order.
    public var byKind: [KindCounts]
    public var total: Counts
    /// Decisions logged by outcome (every update's, so these do depend on the update rate).
    public var decisions: [Decision.Outcome: Int]
    /// Responses to the cues that showed; `pendingResponses` were still up when the log ended.
    public var responses: [CueResponse: Int]
    public var pendingResponses: Int
    /// Outcomes read: improved, not improved, and still waiting (or unknown).
    public var improved: Int
    public var notImproved: Int
    public var pendingOutcomes: Int
    public var targetTime: TimeInterval
    public var finishTime: TimeInterval?

    /// finish − target: + = slower than the target.
    public var finishVsTarget: TimeInterval? { finishTime.map { $0 - targetTime } }

    public init(_ log: CueLog) {
        var shown = Set<Int>(), held = Set<Int>(), seen: [Int: CueKind] = [:]
        var decisions: [Decision.Outcome: Int] = [:]
        for e in log.events {
            seen[e.cue.id] = e.cue.kind
            decisions[e.decision, default: 0] += e.count
            switch e.decision {
            case .shown: shown.insert(e.cue.id)
            case .heldBack: held.insert(e.cue.id)
            case .expired: break
            }
        }
        var kinds: [CueKind: Counts] = [:]
        for (id, kind) in seen {
            var c = kinds[kind] ?? Counts()
            if shown.contains(id) { c.shown += 1 } else { c.expired += 1 }
            if held.contains(id) { c.heldBack += 1 }
            kinds[kind] = c
        }
        // A cue still in play when the log ended (never shown, never expired) isn't expired.
        var stillInPlay = Set(seen.keys).subtracting(shown)
        for e in log.events where e.decision == .expired { stillInPlay.remove(e.cue.id) }
        for id in stillInPlay { kinds[seen[id]!]!.expired -= 1 }

        byKind = CueKind.allCases.compactMap { k in kinds[k].map { KindCounts(kind: k, counts: $0) } }
        total = byKind.reduce(Counts()) {
            Counts(shown: $0.shown + $1.counts.shown, heldBack: $0.heldBack + $1.counts.heldBack,
                   expired: $0.expired + $1.counts.expired)
        }
        self.decisions = decisions

        let appearances = log.appearances
        var responses: [CueResponse: Int] = [:]
        for r in appearances.compactMap(\.response) { responses[r, default: 0] += 1 }
        self.responses = responses
        pendingResponses = appearances.filter { $0.response == nil }.count
        let outcomes = appearances.compactMap(\.outcome)
        improved = outcomes.filter { $0.improved == true }.count
        notImproved = outcomes.filter { $0.improved == false }.count
        pendingOutcomes = outcomes.filter { $0.improved == nil }.count
        targetTime = log.header.targetTime
        finishTime = log.header.finishTime
    }

    public func counts(_ kind: CueKind) -> Counts {
        byKind.first { $0.kind == kind }?.counts ?? Counts()
    }
}

extension CueLog {
    public var summary: RunSummary { RunSummary(self) }
}
