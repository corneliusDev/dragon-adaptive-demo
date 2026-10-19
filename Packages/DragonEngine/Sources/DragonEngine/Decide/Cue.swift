//  Cue.swift
//  Stage 2 of the pipeline (Estimate → Trigger → Capacity → Arbiter → Render):
//  what a trigger proposes. A cue says what to show, how important it is, how
//  it is revealed, and how long it is worth anything. Its content is values
//  (seconds, metres, s/m), not strings: Render turns them into "8:14" or
//  "7:53 / MI", so units stay out of the engine until the last step.

import Foundation

/// How much a cue matters. Comparable: safety > critical > advisory > info.
public enum Priority: Int, Sendable, Comparable, CaseIterable {
    case info, advisory, critical, safety

    public static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
}

/// Stable identity of a cue, for de-duplication now and cooldowns later.
public enum CueKey: Sendable, Hashable {
    /// The `marker`th mile or kilometre marker.
    case split(marker: Int, unit: DistanceUnit)
    /// Behind or ahead of target; one key either way, so the cooldown is shared.
    case paceGap

    public static func split(mile: Int) -> CueKey { .split(marker: mile, unit: .miles) }
    public static func split(kilometer: Int) -> CueKey { .split(marker: kilometer, unit: .kilometers) }
}

/// One piece of cue text, as a value. Render formats it.
public indirect enum CueText: Sendable, Equatable {
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
    /// Several pieces on one line, separated by spaces.
    case phrase([CueText])
}

/// What a cue shows, top to bottom.
public struct CueContent: Sendable, Equatable {
    /// Small line above the value ("MILE 1", "BEHIND PLAN").
    public var heading: CueText?
    /// The one value that matters.
    public var main: CueText
    /// Lines under it, most important first.
    public var subtitle: [CueText]
    /// Small boxed category label ("SPLIT"); dropped when the subtitle needs the room.
    public var tag: String?
    public var icon: Glyph

    public init(heading: CueText? = nil, main: CueText, subtitle: [CueText] = [], tag: String? = nil, icon: Glyph = .none) {
        self.heading = heading
        self.main = main
        self.subtitle = subtitle
        self.tag = tag
        self.icon = icon
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

    public init(key: CueKey, priority: Priority, reveal: Reveal = .auto, content: CueContent,
                createdAt: TimeInterval, expiresAt: TimeInterval, minShow: TimeInterval) {
        self.key = key
        self.priority = priority
        self.reveal = reveal
        self.content = content
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.minShow = minShow
    }
}
