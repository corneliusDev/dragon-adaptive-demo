//  Renderer.swift
//  Stage 5 of the pipeline (Estimate → Trigger → Capacity → Arbiter → Render):
//  (cue, budget, run state, units) → HUDFrame. One layout per cue kind, after
//  the design's screens, each with a reduced form for a budget of one element
//  (or none: a safety cue still shows): just the value and its caption, bigger
//  and sparser as effort rises. With no cue, the quiet screen: a dim status
//  dot for a race (nothing at all once it's over), the dashboard or ambient
//  read-out for the scripted demos. Live pieces of a cue (the kick clock's
//  countdown, the distance to a hill) are drawn from the state given.
//
//  Everything drawn stays inside Display's safe zone, and every string is
//  fitted to what the glasses accept (HUDText.fit: font 3 at most, and the
//  font's character limit), so GlassesBackend never has to cut text off.
//  The design draws its biggest numbers in font 4; on the glasses that is
//  clamped to 3, so they are drawn in font 3 here.

import Foundation

public struct RenderConfig: Sendable, Equatable {
    /// Elements the budget must allow for a cue's full layout; with fewer, the
    /// reduced one (value and caption only).
    public var fullFormElements = 2
    /// Display brightness by effort band (stationary, light, moderate, hard).
    public var luma: [UInt8] = [8, 11, 13, 15]
    /// Rows of the held look's split table.
    public var tableRows = 3

    public init() {}
}

/// What the display shows when no cue is up.
public enum QuietScreen: Sendable, Equatable {
    /// A race: darkness and a dim dot that says the engine is running.
    case statusDot
    /// Nothing: the race is over and the glasses go dark.
    case dark
    /// A scripted demo, standing still: the scenario's name and first rows.
    case dashboard(title: String, rows: [String])
    /// A scripted demo on the move: one big number, laid out by effort band.
    case ambient(big: String, unit: String, sub: String)
}

public enum Renderer {
    /// Full layout, or the reduced one for a budget of one element or none.
    public enum Form: String, Sendable, CaseIterable {
        case full, reduced
    }

    public static func form(for budget: Budget, config: RenderConfig = RenderConfig()) -> Form {
        budget.maxElements >= config.fullFormElements ? .full : .reduced
    }

    /// The frame for `cue` under `budget` (or the quiet screen when nil).
    /// `state` sets the brightness (moderate without one) and the live text;
    /// `unit` is for distances.
    public static func frame(for cue: Cue?, budget: Budget, state: RunState?, unit: DistanceUnit,
                             quiet: QuietScreen = .statusDot, config: RenderConfig = RenderConfig()) -> HUDFrame {
        frame(for: cue, form: form(for: budget, config: config), effort: state?.effort ?? .moderate,
              unit: unit, quiet: quiet, config: config, now: state.map(CueFormat.Now.init))
    }

    /// The same with the form chosen directly (the screen gallery shows both).
    public static func frame(for cue: Cue?, form: Form, effort: MotionBand, unit: DistanceUnit,
                             quiet: QuietScreen = .statusDot, config: RenderConfig = RenderConfig(),
                             now: CueFormat.Now? = nil) -> HUDFrame {
        var p = Painter(unit: unit, now: now)
        p.frame.add(.clear)
        p.frame.add(.luma(config.luma[min(effort.rawValue, config.luma.count - 1)]))
        guard let cue else {
            p.quiet(quiet, band: effort)
            return p.frame
        }
        let c = cue.content
        switch (cue.key.kind, form) {
        case (.split, .full), (.status, .full): p.valueCard(c)
        case (.paceGap, .full): p.paceGap(c)
        case (.target, .full): p.target(c)
        case (.detail, .full): p.splitTable(c, rows: config.tableRows)
        case (.detail, .reduced): p.reduced(caption: c.rows.last.map { .phrase([$0.label, $0.value]) }, main: c.main)
        case (.kickClock, .full): p.kickClock(c)
        case (.heartCeiling, .full), (.terrain, .full), (.fuel, .full), (.formFade, .full), (.finish, .full):
            p.glyphCard(c)
        case (.heartCeiling, .reduced), (.terrain, .reduced), (.fuel, .reduced), (.formFade, .reduced),
             (.finish, .reduced), (.scripted, .reduced):
            p.reducedGlyphCard(c)
        case (.scripted, .full): p.scenarioCard(c)
        case (.split, .reduced), (.status, .reduced), (.paceGap, .reduced), (.target, .reduced),
             (.kickClock, .reduced):
            p.reduced(caption: c.heading, main: c.main)
        }
        return p.frame
    }
}

/// Draws into a frame, fitting every string to the glasses.
private struct Painter {
    let unit: DistanceUnit
    let now: CueFormat.Now?
    var frame = HUDFrame()
    let cx = Display.cx

    init(unit: DistanceUnit, now: CueFormat.Now?) {
        self.unit = unit
        self.now = now
    }

    // MARK: Text

    mutating func text(_ s: String, x: Int, y: Int, font: HUDFont, color: UInt8, align: HUDAlign = .center) {
        let room = align == .center
            ? 2 * min(x - Display.safeMinX, Display.safeMaxX - x)
            : Display.safeMaxX - x
        let fitted = HUDText.fit(s, font: font, width: room)
        frame.add(.text(x: x, y: y, font: fitted.font, color: color, align: align, fitted.string))
    }

    mutating func text(_ t: CueText?, x: Int? = nil, y: Int, font: HUDFont, color: UInt8, align: HUDAlign = .center) {
        guard let t else { return }
        text(CueFormat.string(t, unit: unit, now: now), x: x ?? cx, y: y, font: font, color: color, align: align)
    }

    /// The boxed category label under a card.
    mutating func tag(_ label: String?, top: Int, bottom: Int, textY: Int) {
        guard let label else { return }
        frame.add(.rect(x0: cx - 36, y0: top, x1: cx + 36, y1: bottom, color: 8))
        text(label, x: cx, y: textY, font: .small, color: 11)
    }

    // MARK: Layouts

    /// Mile split and glance status: caption, the value, one line, the tag
    /// (a second line takes the tag's place).
    mutating func valueCard(_ c: CueContent) {
        text(c.heading, y: 62, font: .small, color: 10)
        text(c.main, y: 120, font: .large, color: 15)
        text(c.subtitle.first, y: 160, font: .medium, color: 13)
        if c.subtitle.count > 1 {
            text(c.subtitle[1], y: 190, font: .medium, color: 11)
        } else {
            tag(c.tag, top: 188, bottom: 214, textY: 202)
        }
    }

    /// Behind / ahead of plan: the gap, the projected finish and the pace that fixes it.
    mutating func paceGap(_ c: CueContent) {
        text(c.heading, y: 58, font: .small, color: 10)
        text(c.main, y: 114, font: .large, color: 15)
        text(c.subtitle.first, y: 152, font: .medium, color: 13)
        text(c.subtitle.dropFirst().first, y: 190, font: .medium, color: 11)
    }

    /// Before the gun: the target, the plan, and a hint.
    mutating func target(_ c: CueContent) {
        text(c.heading, y: 62, font: .small, color: 9)
        text(c.main, y: 122, font: .large, color: 15)
        text(c.subtitle.first, y: 162, font: .medium, color: 11)
        text(c.footer, y: 204, font: .small, color: 5)
    }

    /// The held look: the last splits as a table, the pace still needed, the projection.
    mutating func splitTable(_ c: CueContent, rows: Int) {
        text(c.heading, y: 48, font: .small, color: 9)
        for (i, row) in c.rows.suffix(rows).enumerated() {
            let y = 80 + i * 24
            text(row.label, x: 84, y: y, font: .medium, color: 13, align: .left)
            text(row.value, x: 220, y: y, font: .medium, color: 13)
        }
        frame.add(.line(x0: 60, y0: 146, x1: 244, y1: 146, color: 5))
        text(c.main, y: 172, font: .large, color: 15)
        text(c.footer, y: 204, font: .small, color: 8)
    }

    /// The last stretch: time left to beat the target, and nothing else.
    mutating func kickClock(_ c: CueContent) {
        text(c.heading, y: 66, font: .small, color: 9)
        text(c.main, y: 128, font: .large, color: 15)
        text(c.subtitle.first, y: 170, font: .medium, color: 11)
    }

    /// Heart rate, terrain, fuel, form and finish: a glyph, the value, one line, the tag.
    mutating func glyphCard(_ c: CueContent) {
        glyph(c.icon, x: cx, y: 64)
        text(c.main, y: 120, font: .large, color: 15)
        text(c.subtitle.first, y: 156, font: .medium, color: 13)
        tag(c.tag, top: 188, bottom: 214, textY: 202)
    }

    /// A Scenario card, laid out as the demos always have been.
    mutating func scenarioCard(_ c: CueContent) {
        glyph(c.icon, x: cx, y: 70)
        text(c.main, y: 128, font: .large, color: 15)
        text(c.subtitle.first, y: 162, font: .medium, color: 14)
        tag(c.tag, top: 186, bottom: 214, textY: 206)
    }

    /// One element: the value with its caption above it.
    mutating func reduced(caption: CueText?, main: CueText) {
        text(caption, y: 92, font: .small, color: 10)
        text(main, y: 128, font: .large, color: 15)
    }

    /// One element for a glyph card: the glyph says what it is, the value says the rest.
    mutating func reducedGlyphCard(_ c: CueContent) {
        glyph(c.icon, x: cx, y: 80)
        text(c.main, y: 132, font: .large, color: 15)
    }

    // MARK: Quiet

    mutating func quiet(_ q: QuietScreen, band: MotionBand) {
        switch q {
        case .statusDot:
            frame.add(.circf(x: 270, y: 44, r: 3, color: 7))

        case .dark:
            break

        case .dashboard(let title, let rows):
            text(title, x: 24, y: 48, font: .small, color: 8, align: .left)
            frame.add(.line(x0: 24, y0: 58, x1: 280, y1: 58, color: 5))
            for (i, row) in rows.prefix(4).enumerated() {
                text(row, x: 28, y: 88 + i * 30, font: .small, color: 13, align: .left)
            }
            text("LOOK FOR CONTEXT", x: cx, y: 214, font: .small, color: 6)

        case .ambient(let big, let unitLabel, let sub):
            switch band {
            case .stationary:
                text(sub, x: cx, y: 86, font: .small, color: 11)
                text(big, x: cx, y: 132, font: .large, color: 15)
                text(unitLabel, x: cx, y: 162, font: .small, color: 9)
                text("LOOK", x: cx, y: 206, font: .small, color: 5)
            case .light:
                text(sub, x: cx, y: 82, font: .small, color: 11)
                text(big, x: cx, y: 130, font: .large, color: 15)
                text(unitLabel, x: cx, y: 162, font: .small, color: 9)
                text("LOOK", x: cx, y: 206, font: .small, color: 5)
            case .moderate:
                text(sub, x: cx, y: 86, font: .small, color: 9)
                text(big, x: cx, y: 132, font: .large, color: 15)
                text(unitLabel, x: cx, y: 164, font: .small, color: 9)
            case .hard:
                text(big, x: cx, y: 136, font: .large, color: 15)
                text(unitLabel, x: cx, y: 168, font: .small, color: 9)
            }
        }
    }

    // MARK: Glyphs

    /// `glyph` centred on (x, y).
    mutating func glyph(_ glyph: Glyph, x: Int, y: Int) {
        func line(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ color: UInt8 = 15) {
            frame.add(.line(x0: x + x0, y0: y + y0, x1: x + x1, y1: y + y1, color: color))
        }
        switch glyph {
        case .arrow:
            line(-24, 0, 22, 0)
            line(22, 0, 6, -14)
            line(22, 0, 6, 14)
        case .warn:
            line(-18, 14, 18, 14)
            line(-18, 14, 0, -16)
            line(18, 14, 0, -16)
            text("!", x: x, y: y + 9, font: .small, color: 15)
        case .drop:
            frame.add(.circf(x: x, y: y, r: 10, color: 13))
        case .clock:
            frame.add(.circ(x: x, y: y, r: 15, color: 15))
            line(0, 0, 0, -12)
            line(0, 0, 8, 0)
        case .hill:
            line(-28, 12, -10, 12)
            line(-10, 12, 10, -10)
            line(10, -10, 28, -10)
            line(2, -12, 11, -11)
            line(11, -11, 10, -2)
        case .flag:
            line(-10, 16, -10, -16)
            line(-10, -16, 16, -9)
            line(16, -9, -10, -2)
        case .gauge:
            // A half dial (six chords of a radius-18 arc over (0, 8)) and its needle.
            let points = (0...6).map { i -> (Int, Int) in
                let a = Double.pi * Double(6 - i) / 6
                return (Int((18 * cos(a)).rounded()), 8 - Int((18 * sin(a)).rounded()))
            }
            for (a, b) in zip(points, points.dropFirst()) { line(a.0, a.1, b.0, b.1) }
            line(0, 8, 10, -6)
        case .none:
            break
        }
    }
}
