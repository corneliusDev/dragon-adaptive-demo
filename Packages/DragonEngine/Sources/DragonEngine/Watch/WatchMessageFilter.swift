//  WatchMessageFilter.swift
//  The phone's side of the Watch link, minus the transport: decides which
//  arriving messages become engine input. Messages come over two routes
//  (workout mirroring and WatchConnectivity), so the same one can arrive
//  twice, late, or after a newer one. In order:
//
//      duplicate     (session, seq) already seen: dropped.
//      before run    taken before the run started (run time < 0): dropped.
//      out of order  not newer than the last one applied on its stream
//                    (heart rate, effort, state each keep their own): dropped.
//                    Streams are ordered by when the reading was taken, in
//                    run time, so an older session's straggler is dropped too.
//      stale         older than `maxAge` in run time when it arrives: dropped.
//                    The engine would treat it as missing anyway (heart rate
//                    is stale after 5 s), and a late burst after a Bluetooth
//                    gap must not paper over the gap.
//      future        more than `maxAhead` ahead of the phone's run time (the
//                    Watch's clock is off): dropped.
//
//  What's left becomes a VitalsSample (source .watch) at the reading's run
//  time, a session state, or a command. The caller turns the message's
//  wall-clock time into run time (it owns the run's timeline); the filter
//  itself is pure and clock-free.

import Foundation

public struct WatchMessageFilter: Sendable {
    public struct Config: Sendable, Equatable {
        /// Seconds; a reading older than this (run time) when it arrives is stale.
        /// Defaults to the heart-rate staleness the estimator uses.
        public var maxAge: TimeInterval = SourceSelection.heartRateStaleAfter
        /// Seconds; a reading further ahead of the phone's run time than this is dropped.
        public var maxAhead: TimeInterval = 10
        /// How many recent (session, seq) pairs are remembered for de-duplication.
        public var dedupeWindow = 2_048

        public init(maxAge: TimeInterval = SourceSelection.heartRateStaleAfter, maxAhead: TimeInterval = 10,
                    dedupeWindow: Int = 2_048) {
            self.maxAge = maxAge
            self.maxAhead = maxAhead
            self.dedupeWindow = dedupeWindow
        }
    }

    public enum DropReason: String, Sendable, CaseIterable {
        case duplicate, beforeRun, outOfOrder, stale, future
    }

    public enum Outcome: Sendable, Equatable {
        case sample(VitalsSample)
        case state(WatchSessionState, t: TimeInterval)
        case command(WatchCommand)
        case dropped(DropReason)
    }

    /// Counts of what came in and what happened to it.
    public struct Counts: Sendable, Equatable {
        public var received = 0
        public var applied = 0
        public var dropped: [DropReason: Int] = [:]

        public init() {}

        public func dropped(_ reason: DropReason) -> Int { dropped[reason] ?? 0 }
    }

    public let config: Config
    public private(set) var counts = Counts()
    /// Run time of the newest reading applied on each stream.
    public private(set) var lastApplied: [WatchMessage.Stream: TimeInterval] = [:]

    private var seen: Set<Key> = []
    private var seenOrder: [Key] = []
    private var seenHead = 0

    private struct Key: Hashable, Sendable {
        var session: String
        var sequence: Int
    }

    public init(config: Config = Config()) {
        self.config = config
    }

    /// One arriving message. `sampleTime` is the run time of the message's
    /// `at` on the phone's timeline; `now` is the phone's run time on arrival.
    public mutating func accept(_ m: WatchMessage, sampleTime: TimeInterval, now: TimeInterval) -> Outcome {
        counts.received += 1
        let key = Key(session: m.session, sequence: m.sequence)
        guard !seen.contains(key) else { return drop(.duplicate) }
        remember(key)

        if case .command(let c) = m.body {
            counts.applied += 1
            return .command(c)
        }
        guard sampleTime >= 0 else { return drop(.beforeRun) }
        if let last = lastApplied[m.stream], sampleTime <= last { return drop(.outOfOrder) }
        guard now - sampleTime <= config.maxAge else { return drop(.stale) }
        guard sampleTime - now <= config.maxAhead else { return drop(.future) }

        lastApplied[m.stream] = sampleTime
        counts.applied += 1
        switch m.body {
        case .heartRate(let bpm, _):
            return .sample(VitalsSample(timestamp: sampleTime, heartRate: bpm, motion: nil, source: .watch))
        case .effort(let score, _):
            return .sample(VitalsSample(timestamp: sampleTime, heartRate: nil, motion: score, source: .watch))
        case .state(let s, _):
            return .state(s, t: sampleTime)
        case .command(let c):
            return .command(c)
        }
    }

    private mutating func drop(_ reason: DropReason) -> Outcome {
        counts.dropped[reason, default: 0] += 1
        return .dropped(reason)
    }

    /// Remembers a key, forgetting the oldest beyond the window.
    private mutating func remember(_ key: Key) {
        seen.insert(key)
        seenOrder.append(key)
        while seenOrder.count - seenHead > max(1, config.dedupeWindow) {
            seen.remove(seenOrder[seenHead])
            seenHead += 1
        }
        // Compact now and then so the array doesn't grow for a whole race.
        if seenHead > 4_096 {
            seenOrder.removeFirst(seenHead)
            seenHead = 0
        }
    }
}
