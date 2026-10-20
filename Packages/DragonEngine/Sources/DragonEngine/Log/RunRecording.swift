//  RunRecording.swift
//  A recorded run: the plan plus every timestamped input the engine saw
//  (GPS, vitals, attention). Codable JSON, so recordings can be saved from the
//  app, generated from synthetic profiles, and checked in as test fixtures.
//  The cue log (CueLog) is saved beside it, as JSON lines.

import Foundation

/// An attention event with the run time it happened at.
public struct AttentionSample: Sendable, Equatable, Codable {
    public let t: TimeInterval
    public let event: AttentionEvent

    public init(t: TimeInterval, event: AttentionEvent) {
        self.t = t
        self.event = event
    }
}

/// One input in a run, of any kind.
public enum RunEvent: Sendable, Equatable {
    case location(LocationSample)
    case vitals(VitalsSample)
    case attention(AttentionSample)

    public var t: TimeInterval {
        switch self {
        case .location(let s): return s.t
        case .vitals(let s): return s.timestamp
        case .attention(let s): return s.t
        }
    }
}

public struct RunRecording: Codable, Equatable, Sendable {
    /// Free-form label, e.g. the synthetic profile and seed it came from.
    public var name: String
    public var plan: RunPlan?
    /// Each list in time order.
    public var locations: [LocationSample]
    public var vitals: [VitalsSample]
    public var attention: [AttentionSample]
    /// For a recording made by a RunPacer (a real run): the engine was
    /// updated every `updateStep` seconds of run time, from 0 through
    /// `endedAt`. RunEngine.replaying(_:) repeats exactly that. nil for
    /// recordings made any other way (synthetic, older files).
    public var updateStep: TimeInterval?
    public var endedAt: TimeInterval?
    /// The engine settings the run had (with `name`), so a replay can set
    /// the engine up the same way from the file alone; nil when not noted.
    public var unit: DistanceUnit?
    public var display: DisplaySetting?

    public init(name: String = "",
                plan: RunPlan? = nil,
                locations: [LocationSample] = [],
                vitals: [VitalsSample] = [],
                attention: [AttentionSample] = [],
                updateStep: TimeInterval? = nil,
                endedAt: TimeInterval? = nil,
                unit: DistanceUnit? = nil,
                display: DisplaySetting? = nil) {
        self.name = name
        self.plan = plan
        self.locations = locations
        self.vitals = vitals
        self.attention = attention
        self.updateStep = updateStep
        self.endedAt = endedAt
        self.unit = unit
        self.display = display
    }

    /// Run time of the last input, 0 when empty.
    public var duration: TimeInterval {
        max(locations.last?.t ?? 0, vitals.last?.timestamp ?? 0, attention.last?.t ?? 0)
    }

    public var isEmpty: Bool { locations.isEmpty && vitals.isEmpty && attention.isEmpty }

    /// Every input merged in time order. Ties go location, vitals, attention.
    public var events: [RunEvent] {
        var out: [RunEvent] = []
        out.reserveCapacity(locations.count + vitals.count + attention.count)
        var cursor = RunRecording.Cursor()
        cursor.drain(self, through: .infinity) { out.append($0) }
        return out
    }

    // MARK: JSON

    /// Sorted keys, so the same recording always encodes to the same bytes.
    public func jsonData(prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        return try encoder.encode(self)
    }

    public init(jsonData: Data) throws {
        self = try JSONDecoder().decode(RunRecording.self, from: jsonData)
    }

    // MARK: Merging

    /// Read position in each of the three lists; walks them in time order.
    struct Cursor {
        var location = 0, vitals = 0, attention = 0

        /// Emits every input with t <= `time` not emitted yet.
        mutating func drain(_ r: RunRecording, through time: TimeInterval, _ emit: (RunEvent) -> Void) {
            while true {
                let lt = location < r.locations.count ? r.locations[location].t : .infinity
                let vt = vitals < r.vitals.count ? r.vitals[vitals].timestamp : .infinity
                let at = attention < r.attention.count ? r.attention[attention].t : .infinity
                let next = min(lt, vt, at)
                guard next <= time, next < .infinity else { return }
                if lt == next {
                    emit(.location(r.locations[location])); location += 1
                } else if vt == next {
                    emit(.vitals(r.vitals[vitals])); vitals += 1
                } else {
                    emit(.attention(r.attention[attention])); attention += 1
                }
            }
        }
    }
}
