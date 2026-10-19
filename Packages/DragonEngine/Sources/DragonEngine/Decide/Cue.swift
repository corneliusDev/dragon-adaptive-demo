//  Cue.swift
//  Stage 2 of the pipeline (Estimate → Trigger → Capacity → Arbiter → Render):
//  what a trigger proposes. A cue says what to show, how important it is, how
//  it is revealed, and how long it is worth anything. Its content is values
//  (seconds, metres, s/m), not strings: Render turns them into "8:14" or
//  "7:53 / MI", so units stay out of the engine until the last step.

import Foundation

/// How much a cue matters. Comparable: safety > critical > advisory > info.
public enum Priority: Int, Sendable, Codable, Comparable, CaseIterable {
    case info, advisory, critical, safety

    public static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
}

/// Stable identity of a cue, for de-duplication now and cooldowns later.
public enum CueKey: Sendable, Hashable, Codable {
    /// The `marker`th mile or kilometre marker.
    case split(marker: Int, unit: DistanceUnit)
    /// Behind or ahead of target; one key either way, so the cooldown is shared.
    case paceGap
    /// A glance's answer: projected finish against the target.
    case status
    /// A held look's answer: recent splits and the pace still needed.
    case detail
    /// Before the start: the target and the plan.
    case target
    /// Heart rate over its ceiling (chunk 9's trigger).
    case heartCeiling
    /// A hill or sharp turn ahead, by where it starts (whole metres along the course).
    case terrain(at: Int)
    /// The `n`th fuel stop of the plan (1-based).
    case fuel(Int)
    /// Cadence fading with heart rate drifting up.
    case formFade
    /// The last stretch: time left to beat the target.
    case kickClock
    /// Across the line.
    case finish
    /// A hand-authored Scenario card (the cycling and SOF demos), by card id.
    case scripted(String)

    public static func split(mile: Int) -> CueKey { .split(marker: mile, unit: .miles) }
    public static func split(kilometer: Int) -> CueKey { .split(marker: kilometer, unit: .kilometers) }

    /// Words for logs and debug text ("mile 3 split", "pace gap"). Not display text.
    public var name: String {
        switch self {
        case .split(let n, let unit): return "\(unit == .miles ? "mile" : "km") \(n) split"
        case .paceGap: return "pace gap"
        case .status: return "status"
        case .detail: return "split table"
        case .target: return "target"
        case .heartCeiling: return "heart rate"
        case .terrain(let m): return "terrain at \(m) m"
        case .fuel(let n): return "fuel \(n)"
        case .formFade: return "form fade"
        case .kickClock: return "kick clock"
        case .finish: return "finish"
        case .scripted(let id): return "\(id) card"
        }
    }

    /// Which layout the renderer draws it with.
    public var kind: CueKind {
        switch self {
        case .split: return .split
        case .paceGap: return .paceGap
        case .status: return .status
        case .detail: return .detail
        case .target: return .target
        case .heartCeiling: return .heartCeiling
        case .terrain: return .terrain
        case .fuel: return .fuel
        case .formFade: return .formFade
        case .kickClock: return .kickClock
        case .finish: return .finish
        case .scripted: return .scripted
        }
    }
}

/// The kinds of cue, one renderer layout each (the design's screens).
public enum CueKind: String, Sendable, Codable, CaseIterable {
    case split, paceGap, status, detail, target, heartCeiling, terrain, fuel, formFade, kickClock, finish
    /// A Scenario card from the cycling / SOF demos.
    case scripted
}

/// A reading a cue depends on. When the budget says it is unreliable the cue
/// is held back.
public enum CueInput: String, Sendable, Hashable, Codable, CaseIterable {
    case gps, heartRate
}

/// A condition a cue waits for before it may show (chunk 9 holds a split
/// until the top of a hill). A deferred cue still expires at its expiresAt.
public enum Deferral: Sendable, Equatable, Codable {
    /// Until this run time.
    case time(TimeInterval)
    /// Until the runner has covered this many metres (e.g. the crest of a climb).
    case distance(Double)
    /// Until the arbiter is told `release(key)`; for conditions only a trigger can see.
    case released
}

/// One piece of cue text, as a value. Render formats it.
public indirect enum CueText: Sendable, Equatable, Codable {
    /// Words shown as they are ("VS PLAN").
    case label(String)
    /// "MILE 3" / "KM 3".
    case marker(Int, DistanceUnit)
    /// A clock: 8:14, 1:45:48.
    case duration(TimeInterval)
    /// Signed seconds: +0:13 behind, -0:31 ahead.
    case gap(TimeInterval)
    /// Seconds per metre, shown per mile or kilometre: 7:53 / MI.
    case pace(Double, DistanceUnit)
    /// Metres, shown in the renderer's unit: 0.20 MI / 0.32 KM.
    case distance(Double)
    /// Several pieces on one line, separated by spaces.
    case phrase([CueText])
}

/// One row of a table (the held look's recent splits): a label and its value.
public struct CueRow: Sendable, Equatable, Codable {
    public var label: CueText
    public var value: CueText

    public init(_ label: CueText, _ value: CueText) {
        self.label = label
        self.value = value
    }
}

/// What a cue shows, top to bottom.
public struct CueContent: Sendable, Equatable, Codable {
    /// Small line above the value ("MILE 1", "BEHIND PLAN").
    public var heading: CueText?
    /// The one value that matters.
    public var main: CueText
    /// Lines under it, most important first.
    public var subtitle: [CueText]
    /// Small boxed category label ("SPLIT"); dropped when the subtitle needs the room.
    public var tag: String?
    public var icon: Glyph
    /// Rows of a table above the value (the held look's splits); empty for most cues.
    public var rows: [CueRow]
    /// Small dim line at the bottom ("GLANCE FOR STATUS").
    public var footer: CueText?

    public init(heading: CueText? = nil, main: CueText, subtitle: [CueText] = [], tag: String? = nil,
                icon: Glyph = .none, rows: [CueRow] = [], footer: CueText? = nil) {
        self.heading = heading
        self.main = main
        self.subtitle = subtitle
        self.tag = tag
        self.icon = icon
        self.rows = rows
        self.footer = footer
    }
}

public struct Cue: Sendable, Equatable {
    public var key: CueKey
    public var priority: Priority
    public var reveal: Reveal
    public var content: CueContent
    /// Run time the trigger proposed it.
    public var createdAt: TimeInterval
    /// Run time after which it is stale: not shown at all rather than shown late.
    public var expiresAt: TimeInterval
    /// Seconds it stays up once shown, unless something more important arrives.
    public var minShow: TimeInterval
    /// Seconds off plan this cue is about (+ behind, − ahead), if it is about the
    /// plan at all. Breaks priority ties in the arbiter: the bigger gap wins.
    public var planGap: TimeInterval?
    /// Wait for this before showing; nil shows as soon as the arbiter allows.
    public var deferUntil: Deferral?
    /// Readings this cue is only as good as; held back while any is unreliable.
    public var needs: Set<CueInput>

    public init(key: CueKey, priority: Priority, reveal: Reveal = .auto, content: CueContent,
                createdAt: TimeInterval, expiresAt: TimeInterval, minShow: TimeInterval,
                planGap: TimeInterval? = nil, deferUntil: Deferral? = nil, needs: Set<CueInput> = []) {
        self.key = key
        self.priority = priority
        self.reveal = reveal
        self.content = content
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.minShow = minShow
        self.planGap = planGap
        self.deferUntil = deferUntil
        self.needs = needs
    }
}
