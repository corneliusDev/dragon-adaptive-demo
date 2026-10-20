//  Upcoming.swift
//  Predictable cues announce themselves before they fire: a hint with the
//  run time the trigger expects to propose the cue. RunEngine starts the
//  cue's heads-up the lead time before that (Arbiter.announce), so the cue
//  can show the moment it arrives instead of waiting out its heads-up.
//
//  Which triggers can see their cue coming, and how:
//    split      the next marker (or the crest a marker on a climb waits for)
//               within `within` metres, at the current pace
//    pace gap   while its hysteresis holds: when the hold will be up
//    fuel       the schedule: the next stop, and an unacknowledged stop's repeat
//    terrain    a feature about to come within the announcing window
//    kick clock the last 400 m about to begin
//  Heart rate and form fade can't be foreseen; answers are asked for. None
//  of those has a hint, and the arbiter gives them no heads-up.
//
//  A hint is only a forecast: if the cue comes later than the heads-up's
//  tolerance, the heads-up lapses and the cue gets a fresh one when it can
//  show (it then waits the lead). Hints never read the clock: `pace` (seconds
//  per metre) is the runner's current pace, from RunEngine.

import Foundation

/// A predictable cue its trigger expects to propose soon.
public struct Upcoming: Sendable, Equatable {
    public var key: CueKey
    public var priority: Priority
    /// Run time the trigger expects to propose it.
    public var expectedAt: TimeInterval

    public init(key: CueKey, priority: Priority, expectedAt: TimeInterval) {
        self.key = key
        self.priority = priority
        self.expectedAt = expectedAt
    }
}

/// Run time to cover `meters` more at `pace` seconds per metre.
private func arrival(_ meters: Double, pace: Double, at t: TimeInterval) -> TimeInterval {
    t + max(0, meters) * pace
}

extension SplitTrigger {
    /// The next marker (or the crest a marker on a climb is waiting for) when
    /// it is within `within` metres.
    public func upcoming(state s: RunState, at t: TimeInterval, pace: Double, within: Double) -> [Upcoming] {
        let unit = config.unit.meters
        var out: [Upcoming] = []
        // A split already proposed and waiting for its crest.
        if let last = splits.last {
            let at = Double(last.marker) * unit
            if let crest = hills.first(where: { at >= $0.startDistance && at < $0.endDistance })?.endDistance,
               crest > s.distance, crest - s.distance <= within {
                out.append(Upcoming(key: .split(marker: last.marker, unit: last.unit), priority: config.priority,
                                    expectedAt: arrival(crest - s.distance, pace: pace, at: t)))
            }
        }
        let marker = splits.count + 1
        let at = Double(marker) * unit
        guard at < plan.distanceMeters else { return out }
        // On a climb it waits for the crest: that is when it can show.
        let target = hills.first { at >= $0.startDistance && at < $0.endDistance }?.endDistance ?? at
        let left = target - s.distance
        if left > 0, left <= within {
            out.append(Upcoming(key: .split(marker: marker, unit: config.unit), priority: config.priority,
                                expectedAt: arrival(left, pace: pace, at: t)))
        }
        return out
    }
}

extension PaceGapTrigger {
    /// While the gap and pace hold past the start line: when the hold will be up.
    public func upcoming(at t: TimeInterval) -> [Upcoming] {
        guard active == nil else { return [] }
        return [behind.heldSince, ahead.heldSince].compactMap { $0 }.map {
            Upcoming(key: .paceGap, priority: config.priority, expectedAt: max(t, $0 + config.hold))
        }
    }
}

extension FuelTrigger {
    /// The next stop on the schedule, and the latest stop's repeat while it is due.
    public func upcoming(at t: TimeInterval) -> [Upcoming] {
        guard let every = plan.fuelEvery, every > 0 else { return [] }
        var out = [Upcoming(key: .fuel(fired + 1), priority: config.priority, expectedAt: Double(fired + 1) * every)]
        if let due = repeatDue {
            out.append(Upcoming(key: .fuel(due.stop), priority: config.priority, expectedAt: due.at))
        }
        return out
    }
}

extension TerrainAheadTrigger {
    /// Features about to come within the window, when they are within `within` metres of it.
    public func upcoming(state s: RunState, at t: TimeInterval, pace: Double, within: Double) -> [Upcoming] {
        features.compactMap { f in
            let at = Int(f.distance.rounded())
            let toWindow = f.distance - s.distance - config.farthest
            guard !announced.contains(at), toWindow > 0, toWindow <= within else { return nil }
            return Upcoming(key: .terrain(at: at), priority: config.priority,
                            expectedAt: arrival(toWindow, pace: pace, at: t))
        }
    }
}

extension KickClockTrigger {
    /// The last stretch about to begin, within `within` metres.
    public func upcoming(state s: RunState, at t: TimeInterval, pace: Double, within: Double) -> [Upcoming] {
        let toStretch = plan.distanceMeters - s.distance - config.distanceLeft
        guard !fired, toStretch > 0, toStretch <= within else { return [] }
        return [Upcoming(key: .kickClock, priority: config.priority, expectedAt: arrival(toStretch, pace: pace, at: t))]
    }
}
