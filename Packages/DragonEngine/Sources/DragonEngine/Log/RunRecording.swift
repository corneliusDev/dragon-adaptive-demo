//  RunRecording.swift
//  A recorded run: the plan plus every timestamped input the engine saw
//  (GPS, vitals, attention). Codable JSON, so recordings can be saved from the
//  app, generated from synthetic profiles, and checked in as test fixtures.
//  The cue log joins this in a later chunk.

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

    public init(name: String = "",
                plan: RunPlan? = nil,
                locations: [LocationSample] = [],
                vitals: [VitalsSample] = [],
                attention: [AttentionSample] = []) {
        self.name = name
        self.plan = plan
        self.locations = locations
        self.vitals = vitals
        self.attention = attention
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
