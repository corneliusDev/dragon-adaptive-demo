//  ScreenGallery.swift
//  One sample of every screen the renderer draws, with the design's example
//  half marathon numbers (1:45:00 target, even 8:01 / mi): each cue kind,
//  the quiet dot, and the scripted demos' cards, dashboard and ambient
//  read-out. The app's screen gallery shows them on the phone mirror and
//  the glasses; the snapshot tests pin their frames.

import Foundation

public struct ScreenSample: Sendable {
    /// Stable name, for the gallery and the golden fixtures ("split", "scripted.tri.turn").
    public var name: String
    /// What the design calls it.
    public var title: String
    /// The cue; nil for a quiet screen.
    public var cue: Cue?
    public var quiet: QuietScreen
    /// Effort the screen is drawn at (brightness, and the ambient layout).
    public var effort: MotionBand

    public init(name: String, title: String, cue: Cue?, quiet: QuietScreen = .statusDot, effort: MotionBand = .moderate) {
        self.name = name
        self.title = title
        self.cue = cue
        self.quiet = quiet
        self.effort = effort
    }

    /// The sample drawn in `form`, distances in `unit`.
    public func frame(_ form: Renderer.Form, unit: DistanceUnit, config: RenderConfig = RenderConfig()) -> HUDFrame {
        Renderer.frame(for: cue, form: form, effort: effort, unit: unit, quiet: quiet, config: config)
    }
}

public enum ScreenGallery {
    /// The example race: 13.1 mi in 1:45:00, even pacing.
    static let raceMeters = 21_097.5
    static let target: TimeInterval = 6_300
    static var planPace: Double { target / raceMeters }

    /// Every screen, in the design's gallery order, then the demos'.
    public static func samples(unit: DistanceUnit) -> [ScreenSample] {
        race(unit: unit) + scripted()
    }

    /// The pace engine's screens.
    public static func race(unit: DistanceUnit) -> [ScreenSample] {
        let u = unit.meters
        /// The design's per-mile seconds as the same pace per `unit`.
        func per(_ secondsPerMile: TimeInterval) -> TimeInterval {
            (secondsPerMile / DistanceUnit.metersPerMile * u).rounded()
        }
        func pace(_ secondsPerMile: TimeInterval) -> CueText {
            .pace(secondsPerMile / DistanceUnit.metersPerMile, unit)
        }
        func cue(_ key: CueKey, _ priority: Priority, _ content: CueContent, reveal: Reveal = .auto,
                 show: TimeInterval) -> Cue {
            Cue(key: key, priority: priority, reveal: reveal, content: content,
                createdAt: 0, expiresAt: 20, minShow: show)
        }
        let unitWord = unit == .miles ? "MI" : "KM"

        return [
            ScreenSample(name: "split", title: "Mile split", cue: cue(.split(marker: 1, unit: unit), .advisory,
                CueContent(heading: .marker(1, unit), main: .duration(per(494)),
                           subtitle: [.phrase([.gap(per(494) - per(481)), .label("VS PLAN")])], tag: "SPLIT"),
                show: 3)),
            ScreenSample(name: "paceGap", title: "Behind plan", cue: cue(.paceGap, .critical,
                CueContent(heading: .label("BEHIND PLAN"), main: .gap(48),
                           subtitle: [.phrase([.label("FINISH"), .duration(6_348)]),
                                      .phrase([.label("NEED"), pace(473)])],
                           icon: .warn),
                show: 5)),
            ScreenSample(name: "heartCeiling", title: "Heart rate high", cue: cue(.heartCeiling, .critical,
                CueContent(main: .label("HR 178 Z5"), subtitle: [.label("EASE 5 SEC/\(unitWord)")], tag: "HEART",
                           icon: .warn),
                show: 5), effort: .hard),
            ScreenSample(name: "terrain", title: "Hill ahead", cue: cue(.terrain(at: 12_150), .advisory,
                CueContent(main: .phrase([.label("HILL"), .distance(322)]), subtitle: [.label("HOLD EFFORT")],
                           tag: "TERRAIN", icon: .hill),
                show: 4)),
            ScreenSample(name: "fuel", title: "Fuel", cue: cue(.fuel(1), .critical,
                CueContent(main: .label("GEL NOW"), subtitle: [.label("FUEL 1 OF 2")], tag: "FUEL", icon: .drop),
                show: 6)),
            ScreenSample(name: "formFade", title: "Form fade", cue: cue(.formFade, .info,
                CueContent(main: .label("CADENCE -6%"), subtitle: [.label("SHORTEN STRIDE")], tag: "FORM",
                           icon: .gauge),
                reveal: .glance, show: 3)),
            ScreenSample(name: "status", title: "Status", cue: cue(.status, .info,
                CueContent(heading: .label("PROJECTED FINISH"), main: .duration(6_301),
                           subtitle: [.phrase([.gap(1), .label("ON PLAN")])], tag: "STATUS"),
                reveal: .glance, show: 1.5), effort: .light),
            ScreenSample(name: "detail", title: "Detail", cue: cue(.detail, .info,
                CueContent(heading: .label("LAST 3 SPLITS"), main: .phrase([.label("NEED"), pace(469)]),
                           rows: [CueRow(.marker(9, unit), .duration(per(464))),
                                  CueRow(.marker(10, unit), .duration(per(478))),
                                  CueRow(.marker(11, unit), .duration(per(494)))],
                           footer: .phrase([.label("PROJ"), .duration(6_322), .gap(22)])),
                reveal: .dwell, show: 2.6)),
            ScreenSample(name: "kickClock", title: "Kick clock", cue: cue(.kickClock, .safety,
                CueContent(heading: .phrase([.label("TO BEAT"), .duration(target)]), main: .duration(98),
                           subtitle: [.phrase([.label("LEFT"), .distance(257)])]),
                show: 98), effort: .hard),
            ScreenSample(name: "target", title: "Target", cue: cue(.target, .info,
                CueContent(heading: .label("TARGET"), main: .duration(target),
                           subtitle: [.phrase([.pace(planPace, unit), .label("EVEN")])],
                           footer: .label("GLANCE FOR STATUS")),
                reveal: .glance, show: 4), effort: .stationary),
            ScreenSample(name: "finish", title: "Finish", cue: cue(.finish, .info,
                CueContent(main: .duration(6_269), subtitle: [.phrase([.label("TARGET MET"), .gap(-31)])],
                           tag: "FINISH", icon: .flag),
                show: 10), effort: .stationary),
            ScreenSample(name: "quiet", title: "Quiet", cue: nil),
        ]
    }

    /// The cycling and SOF demos: every card, and their quiet screens.
    public static func scripted() -> [ScreenSample] {
        Scenarios.all.flatMap { scenario -> [ScreenSample] in
            let trigger = ScriptedTrigger(scenario: scenario)
            let cards = scenario.cards.map { card in
                ScreenSample(name: "scripted.\(scenario.key).\(card.id)", title: "\(scenario.name) · \(card.tag)",
                             cue: trigger.cue(for: card, priority: card.reveal == .auto ? .critical : .info,
                                              show: 5, at: 0))
            }
            return cards + [
                ScreenSample(name: "scripted.\(scenario.key).dashboard", title: "\(scenario.name) · dashboard",
                             cue: nil, quiet: trigger.quietScreen(band: .stationary, motion: 0, heartRate: 96),
                             effort: .stationary),
                ScreenSample(name: "scripted.\(scenario.key).ambient", title: "\(scenario.name) · ambient",
                             cue: nil, quiet: trigger.quietScreen(band: .moderate, motion: 50, heartRate: 142)),
            ]
        }
    }
}
