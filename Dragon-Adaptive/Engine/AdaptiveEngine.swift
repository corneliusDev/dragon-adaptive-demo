//  AdaptiveEngine.swift
//  Safe-zone adaptive HUD layout for real ActiveLook glasses.
//  UI- and device-agnostic: emits HUDOps and consumes AttentionEvents.

import Foundation

enum MotionBand: Int {
    case stationary, light, moderate, hard

    var label: String {
        ["STATIONARY", "LIGHT", "MODERATE", "HARD"][rawValue]
    }
}

final class AdaptiveEngine {
    private(set) var scenario: Scenario
    var motion: Double = 0
    var heartRate: Int { Int(96 + motion * 0.92) }

    private(set) var attention: AttentionEvent = .idle
    private var attnUntil = Date.distantPast

    private(set) var active: ContextCard?
    private var activeUntil = Date.distantPast
    private var seen = Set<String>()

    var running = false
    private(set) var clock: Double = 0
    private(set) var flywheel = 0
    var onFlywheel: ((Int) -> Void)?

    init(scenario: Scenario) {
        self.scenario = scenario
    }

    var band: MotionBand {
        switch motion {
        case ..<6:
            return .stationary
        case ..<38:
            return .light
        case ..<72:
            return .moderate
        default:
            return .hard
        }
    }

    func setScenario(_ s: Scenario) {
        reset()
        scenario = s
    }

    func reset() {
        attention = .idle
        attnUntil = .distantPast

        active = nil
        activeUntil = .distantPast
        seen = []

        flywheel = 0
        running = false
        clock = 0
    }

    // MARK: - Attention

    func handle(_ e: AttentionEvent) {
        attention = e

        guard e == .glance || e == .dwell else {
            return
        }

        attnUntil = Date().addingTimeInterval(e == .dwell ? 2.6 : 1.5)

        let want: [Reveal] = e == .dwell ? [.dwell, .glance] : [.glance]

        if let cue = scenario.cards.first(where: { want.contains($0.reveal) && $0.window.contains(clock) })
            ?? scenario.cards.first(where: { want.contains($0.reveal) && !seen.contains($0.id) }) {
            surface(cue, drilled: e == .dwell)
        }
    }

    private func surface(_ c: ContextCard, drilled: Bool) {
        active = c
        activeUntil = Date().addingTimeInterval(drilled ? 8 : 5)
        seen.insert(c.id)
    }

    private func autoScan() {
        for c in scenario.cards where c.reveal == .auto && c.window.contains(clock) {
            if active?.id != c.id {
                surface(c, drilled: false)
                attention = .idle
            }
        }
    }

    // MARK: - Tick

    func tick(dt: Double) -> HUDFrame {
        if running {
            clock += dt

            if clock > 40 {
                clock = 0
                seen = []
            }
        }

        if attnUntil != .distantPast, Date() > attnUntil {
            attention = .idle
            attnUntil = .distantPast
        }

        if active != nil, Date() > activeUntil {
            flywheel += 1
            onFlywheel?(flywheel)
            active = nil
        }

        if running {
            autoScan()
        }

        return render()
    }

    // MARK: - Render

    func render() -> HUDFrame {
        var f = HUDFrame()
        f.add(.clear)
        f.add(.luma([8, 11, 13, 15][band.rawValue]))

        if band == .stationary, active == nil {
            drawDashboard(into: &f)
            return f
        }

        if let c = active {
            drawCard(c, into: &f)
            return f
        }

        drawAmbient(into: &f)
        return f
    }

    private func drawDashboard(into f: inout HUDFrame) {
        f.add(.text(x: 24, y: 48, font: .small, color: 8, align: .left, scenario.name))
        f.add(.line(x0: 24, y0: 58, x1: 280, y1: 58, color: 5))

        let rows = Array(scenario.dashboard.prefix(4))

        for (i, row) in rows.enumerated() {
            f.add(.text(
                x: 28,
                y: 88 + i * 30,
                font: .small,
                color: 13,
                align: .left,
                row
            ))
        }

        f.add(.text(x: Display.cx, y: 214, font: .small, color: 6, align: .center, "LOOK FOR CONTEXT"))
    }

    private func drawAmbient(into f: inout HUDFrame) {
        let a = scenario.ambient(band, motion, heartRate)

        switch band {
        case .stationary:
            f.add(.text(x: Display.cx, y: 86, font: .small, color: 11, align: .center, a.sub))
            f.add(.text(x: Display.cx, y: 132, font: .large, color: 15, align: .center, a.big))
            f.add(.text(x: Display.cx, y: 162, font: .small, color: 9, align: .center, a.unit))
            f.add(.text(x: Display.cx, y: 206, font: .small, color: 5, align: .center, "LOOK"))

        case .light:
            f.add(.text(x: Display.cx, y: 82, font: .small, color: 11, align: .center, a.sub))
            f.add(.text(x: Display.cx, y: 130, font: .large, color: 15, align: .center, a.big))
            f.add(.text(x: Display.cx, y: 162, font: .small, color: 9, align: .center, a.unit))
            f.add(.text(x: Display.cx, y: 206, font: .small, color: 5, align: .center, "LOOK"))

        case .moderate:
            f.add(.text(x: Display.cx, y: 86, font: .small, color: 9, align: .center, a.sub))
            f.add(.text(x: Display.cx, y: 132, font: .large, color: 15, align: .center, a.big))
            f.add(.text(x: Display.cx, y: 164, font: .small, color: 9, align: .center, a.unit))

        case .hard:
            f.add(.text(x: Display.cx, y: 136, font: .large, color: 15, align: .center, a.big))
            f.add(.text(x: Display.cx, y: 168, font: .small, color: 9, align: .center, a.unit))
        }
    }

    private func drawCard(_ c: ContextCard, into f: inout HUDFrame) {
        let cx = Display.cx

        switch c.glyph {
        case .arrow:
            f.add(.line(x0: cx - 24, y0: 70, x1: cx + 22, y1: 70, color: 15))
            f.add(.line(x0: cx + 22, y0: 70, x1: cx + 6, y1: 56, color: 15))
            f.add(.line(x0: cx + 22, y0: 70, x1: cx + 6, y1: 84, color: 15))

        case .warn:
            f.add(.line(x0: cx - 18, y0: 84, x1: cx + 18, y1: 84, color: 15))
            f.add(.line(x0: cx - 18, y0: 84, x1: cx, y1: 54, color: 15))
            f.add(.line(x0: cx + 18, y0: 84, x1: cx, y1: 54, color: 15))
            f.add(.text(x: cx, y: 79, font: .small, color: 15, align: .center, "!"))

        case .drop:
            f.add(.circf(x: cx, y: 70, r: 10, color: 13))

        case .clock:
            f.add(.circ(x: cx, y: 70, r: 15, color: 15))
            f.add(.line(x0: cx, y0: 70, x1: cx, y1: 58, color: 15))
            f.add(.line(x0: cx, y0: 70, x1: cx + 8, y1: 70, color: 15))

        case .none:
            break
        }

        f.add(.text(x: cx, y: 128, font: .large, color: 15, align: .center, c.line1))
        f.add(.text(x: cx, y: 162, font: .medium, color: 14, align: .center, c.line2))

        f.add(.rect(x0: cx - 36, y0: 186, x1: cx + 36, y1: 214, color: 8))
        f.add(.text(x: cx, y: 206, font: .small, color: 11, align: .center, c.tag))
    }
}
