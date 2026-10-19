//  Trigger.swift
//  A trigger watches RunState for one condition and proposes cues when it
//  happens. Triggers may keep state between calls (markers passed, how long
//  a condition has held); they never read the clock, only the run time given.

import Foundation

public protocol Trigger {
    /// Called with every new state, in time order; returns the cues to propose now.
    mutating func evaluate(state: RunState, at t: TimeInterval) -> [Cue]
}

/// Keeps a noisy reading from making a cue flicker: the condition has to
/// pass `start` and stay past it for `hold` seconds before it turns on, and
/// once on it stays on until the reading falls below `clear` (≤ start).
/// A reading that dips back under `start` before the hold is up starts the
/// wait again. An unknown reading (nil) neither starts nor clears it.
public struct Hysteresis: Sendable, Equatable {
    public enum Change: Sendable, Equatable { case fired, cleared }

    public var start: Double
    public var clear: Double
    public var hold: TimeInterval

    public private(set) var isOn = false
    /// Run time the start condition began holding, while waiting to fire.
    public private(set) var heldSince: TimeInterval?

    public init(start: Double, clear: Double, hold: TimeInterval) {
        precondition(clear <= start, "clear threshold must not be above the start threshold")
        self.start = start
        self.clear = clear
        self.hold = hold
    }

    /// Feed one reading: on above `start` (after the hold), off below `clear`.
    public mutating func update(_ value: Double?, at t: TimeInterval) -> Change? {
        guard let value else { return update(starting: false, clearing: false, at: t) }
        return update(starting: value > start, clearing: value < clear, at: t)
    }

    /// The same rule for a condition that isn't one number: `starting` is "past
    /// the start threshold", `clearing` is "past the clear threshold".
    public mutating func update(starting: Bool, clearing: Bool, at t: TimeInterval) -> Change? {
        if isOn {
            guard clearing else { return nil }
            isOn = false
            return .cleared
        }
        guard starting else {
            heldSince = nil
            return nil
        }
        let since = heldSince ?? t
        heldSince = since
        guard t - since >= hold else { return nil }
        isOn = true
        heldSince = nil
        return .fired
    }
}
