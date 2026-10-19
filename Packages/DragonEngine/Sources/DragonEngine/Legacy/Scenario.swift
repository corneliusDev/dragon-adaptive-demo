//  Scenario.swift
//  Context model — same data the HTML bench uses.
//  Legacy: today's hand-authored demo scenarios, kept until the plan-driven pipeline replaces them.

import Foundation

public enum Reveal: Sendable { case glance, auto, dwell }   // auto = engine forces (safety-critical)
public enum Glyph: Sendable { case arrow, warn, drop, clock, none }

public struct ContextCard {
    public let id: String
    public let reveal: Reveal
    public let window: ClosedRange<Double>        // scenario seconds when relevant
    public let line1: String
    public let line2: String
    public let tag: String                        // NAV / ZONE / THRT ...
    public let glyph: Glyph

    public init(id: String, reveal: Reveal, window: ClosedRange<Double>, line1: String, line2: String, tag: String, glyph: Glyph) {
        self.id = id
        self.reveal = reveal
        self.window = window
        self.line1 = line1
        self.line2 = line2
        self.tag = tag
        self.glyph = glyph
    }
}

public struct Scenario {
    public typealias Ambient = (MotionBand, Double, Int) -> (big: String, unit: String, sub: String)

    public let key: String
    public let name: String
    public let cards: [ContextCard]
    public let dashboard: [String]
    /// (band, speed-ish, hr) -> ambient base layer
    public let ambient: Ambient

    public init(key: String, name: String, cards: [ContextCard], dashboard: [String], ambient: @escaping Ambient) {
        self.key = key
        self.name = name
        self.cards = cards
        self.dashboard = dashboard
        self.ambient = ambient
    }
}

public enum Scenarios {
    public static let cyclingTri = Scenario(
        key: "tri", name: "CYCLING / TRI",
        cards: [
            ContextCard(id: "turn", reveal: .glance, window: 5...12,  line1: "TURN 200m", line2: "BEAR RIGHT", tag: "NAV",  glyph: .arrow),
            ContextCard(id: "hr",   reveal: .auto,   window: 13...20, line1: "HR  Z4",    line2: "EASE OFF",   tag: "ZONE", glyph: .warn),
            ContextCard(id: "gel",  reveal: .glance, window: 21...28, line1: "FUEL 0:45", line2: "GEL NOW",    tag: "NUTR", glyph: .drop),
            ContextCard(id: "gap",  reveal: .dwell,  window: 29...38, line1: "CHASER",    line2: "+0:12 GAP",  tag: "TAC",  glyph: .none),
        ],
        dashboard: ["PACE  17.4 MPH", "HR    148  Z3", "DIST  24.6 MI", "NEXT  TURN 200m", "FUEL  GEL @ 0:45"],
        ambient: { _, spd, hr in (big: String(format: "%.1f", spd * 0.34), unit: "MPH", sub: "HR \(hr)") }
    )

    public static let operatorSOF = Scenario(
        key: "sof", name: "OPERATOR / SOF",
        cards: [
            ContextCard(id: "wp",    reveal: .glance, window: 5...12,  line1: "WP2 140m",  line2: "AZ 047",     tag: "NAV",  glyph: .arrow),
            ContextCard(id: "con",   reveal: .auto,   window: 13...20, line1: "CONTACT",   line2: "2 O'CLOCK",  tag: "THRT", glyph: .warn),
            ContextCard(id: "exfil", reveal: .glance, window: 21...28, line1: "EXFIL 6:30", line2: "PHASE LINE", tag: "TIME", glyph: .clock),
            ContextCard(id: "stat",  reveal: .dwell,  window: 29...38, line1: "AMMO 40%",  line2: "COMMS OK",   tag: "STAT", glyph: .none),
        ],
        dashboard: ["HDG   047  AZ", "WP2   140 M", "EXFIL 0:06:30", "AMMO  40%", "COMMS ● MESH OK"],
        ambient: { _, spd, _ in (big: String(format: "%03d", Int(40 + spd * 0.2)), unit: "AZ", sub: "WP2 \(max(20, Int(180 - spd)))m") }
    )

    public static let all = [cyclingTri, operatorSOF]
}
