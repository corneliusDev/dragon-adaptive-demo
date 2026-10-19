//  CueChoice.swift
//  Placeholder for the arbiter (chunk 5): at most one cue on screen, the
//  highest priority wins. A cue stays up for its minShow unless something
//  strictly more important arrives; waiting cues are dropped once they
//  expire; a newer proposal with the same key replaces a waiting one.
//  No budget, no cooldowns yet.

import Foundation

public struct CueChoice: Sendable {
    /// What is on screen now.
    public private(set) var current: Cue?
    /// Run time `current` went up.
    public private(set) var shownAt: TimeInterval = 0
    /// Proposed and not shown yet, oldest first.
    public private(set) var waiting: [Cue] = []

    public init() {}

    /// Takes this step's proposals and returns what to show at run time `t`.
    @discardableResult
    public mutating func update(proposed: [Cue], at t: TimeInterval) -> Cue? {
        for cue in proposed {
            waiting.removeAll { $0.key == cue.key }
            waiting.append(cue)
        }
        waiting.removeAll { $0.expiresAt < t }
        if let c = current, t - shownAt >= c.minShow { current = nil }

        // Highest priority; among equals, the one waiting longest.
        guard let best = waiting.indices.max(by: { a, b in
            waiting[a].priority != waiting[b].priority ? waiting[a].priority < waiting[b].priority : a > b
        }) else { return current }
        if let c = current, waiting[best].priority <= c.priority { return current }
        current = waiting.remove(at: best)
        shownAt = t
        return current
    }
}
