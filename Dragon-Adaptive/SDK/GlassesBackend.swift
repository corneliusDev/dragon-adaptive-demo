//
//  GlassesBackend.swift
//  Translates HUDOps into real ActiveLook commands.
//  Calibrated/debug version for real glasses.
//
//  Current calibration:
//  - HUD is shifted LEFT because the optical display appeared too far right.
//  - Live HUD content stays in conservative safe zone.
//  - Text uses baseline compensation.
//  - Font 4 is clamped down to 3 until the real display is calibrated.
//

import Foundation
import ActiveLookSDK

final class GlassesBackend {
    private weak var glasses: Glasses?
    private var lastSignature = ""

    // ActiveLook physical display is 304 × 256.
    // Keep live HUD content away from the edges.
    private let safeMinX = Display.safeMinX
    private let safeMaxX = Display.safeMaxX
    private let safeMinY = Display.safeMinY
    private let safeMaxY = Display.safeMaxY

    // Text on the glasses behaves like baseline-positioned text, not Canvas text.
    // Increase if text appears too high. Decrease if text appears too low.
    private let textBaselineOffset = 14

    // Optical calibration.
    // Negative shifts everything left. Positive shifts everything right.
    // You said the display is too far right, so start at -45.
    private let xOffset = -45
    private let yOffset = 0

    init(glasses: Glasses) {
        self.glasses = glasses
        print("[GlassesBackend] init with glasses: \(glasses.name)")
    }

    func invalidate() {
        lastSignature = ""
    }

    func apply(_ frame: HUDFrame) {
        guard let g = glasses else {
            print("[GlassesBackend] apply skipped: glasses nil")
            return
        }

        guard frame.signature != lastSignature else {
            return
        }

        lastSignature = frame.signature
        print("[GlassesBackend] sending frame with \(frame.ops.count) ops")

        for op in frame.ops {
            switch op {
            case .clear:
                g.clear()

            case .luma(let level):
                g.luma(level: level)

            case .line(let x0, let y0, let x1, let y1, let color):
                g.color(level: color)
                g.line(
                    x0: i16(clampX(x0)),
                    x1: i16(clampX(x1)),
                    y0: glassY(clampY(y0)),
                    y1: glassY(clampY(y1))
                )

            case .rect(let x0, let y0, let x1, let y1, let color):
                g.color(level: color)
                g.rect(
                    x0: i16(clampX(x0)),
                    x1: i16(clampX(x1)),
                    y0: glassY(clampY(y1)),
                    y1: glassY(clampY(y0))
                )

            case .rectf(let x0, let y0, let x1, let y1, let color):
                g.color(level: color)
                g.rectf(
                    x0: i16(clampX(x0)),
                    x1: i16(clampX(x1)),
                    y0: glassY(clampY(y1)),
                    y1: glassY(clampY(y0))
                )

            case .circ(let x, let y, let radius, let color):
                g.color(level: color)
                g.circ(
                    x: i16(clampX(x)),
                    y: glassY(clampY(y)),
                    radius: u8(radius)
                )

            case .circf(let x, let y, let radius, let color):
                g.color(level: color)
                g.circf(
                    x: i16(clampX(x)),
                    y: glassY(clampY(y)),
                    radius: u8(radius)
                )

            case .text(let x, let y, let font, let color, let align, let string):
                drawText(
                    glasses: g,
                    x: x,
                    y: y,
                    font: font,
                    color: color,
                    align: align,
                    string: string
                )
            }
        }
    }

    // MARK: - Calibration / diagnostics

    func sendCalibrationPattern() {
        guard let g = glasses else {
            print("[GlassesBackend] calibration skipped: glasses nil")
            return
        }

        print("[GlassesBackend] sending calibration pattern")

        lastSignature = ""

        g.power(on: true)
        g.clear()
        g.luma(level: 15)
        g.color(level: 15)

        // Outer physical boundary.
        g.rect(
            x0: i16(adjustedX(4)),
            x1: i16(adjustedX(300)),
            y0: i16(4),
            y1: i16(252)
        )

        // Conservative safe zone.
        g.rect(
            x0: i16(adjustedX(safeMinX)),
            x1: i16(adjustedX(safeMaxX)),
            y0: glassY(safeMaxY),
            y1: glassY(safeMinY)
        )

        // Center cross.
        g.line(
            x0: i16(adjustedX(Display.cx)),
            x1: i16(adjustedX(Display.cx)),
            y0: glassY(safeMaxY),
            y1: glassY(safeMinY)
        )

        g.line(
            x0: i16(adjustedX(safeMinX)),
            x1: i16(adjustedX(safeMaxX)),
            y0: glassY(Display.cy),
            y1: glassY(Display.cy)
        )

        drawRawText(g, x: 24, y: 52, font: 1, color: 15, string: "TOP")
        drawRawText(g, x: 90, y: 132, font: 2, color: 15, string: "CENTER")
        drawRawText(g, x: 24, y: 204, font: 1, color: 15, string: "BOTTOM")
    }

    func sendTestPattern() {
        guard let g = glasses else {
            print("[GlassesBackend] test pattern skipped: glasses nil")
            return
        }

        print("[GlassesBackend] sending test pattern")

        lastSignature = ""

        g.power(on: true)
        g.clear()
        g.luma(level: 15)
        g.color(level: 15)

        drawRawText(g, x: 30, y: 82, font: 2, color: 15, string: "DRAGON")
        drawRawText(g, x: 30, y: 116, font: 1, color: 10, string: "BLE OK")

        g.rect(
            x0: i16(adjustedX(24)),
            x1: i16(adjustedX(280)),
            y0: glassY(145),
            y1: glassY(58)
        )
    }

    // MARK: - Text

    private func drawText(
        glasses g: Glasses,
        x: Int,
        y: Int,
        font: HUDFont,
        color: UInt8,
        align: HUDAlign,
        string: String
    ) {
        let safeString = trimForGlasses(string, font: font)
        let fontId = safeFont(font)
        let advance = estimatedAdvance(for: font)

        let rawStartX: Int
        switch align {
        case .center:
            rawStartX = x - (safeString.count * advance) / 2
        case .left:
            rawStartX = x
        }

        let tx = clampTextX(rawStartX)
        let ty = clampTextY(y)

        g.txt(
            x: i16(tx),
            y: glassTextY(ty),
            rotation: .topLR,
            font: fontId,
            color: color,
            string: safeString
        )
    }

    private func drawRawText(
        _ g: Glasses,
        x: Int,
        y: Int,
        font: UInt8,
        color: UInt8,
        string: String
    ) {
        g.txt(
            x: i16(clampTextX(x)),
            y: glassTextY(clampTextY(y)),
            rotation: .topLR,
            font: min(font, 3),
            color: color,
            string: string
        )
    }

    private func safeFont(_ font: HUDFont) -> UInt8 {
        // Avoid font 4 for now. Real glasses often make this too large.
        min(font.rawValue, 3)
    }

    private func estimatedAdvance(for font: HUDFont) -> Int {
        switch font {
        case .small: return 7
        case .medium: return 10
        case .large: return 15
        case .huge: return 18
        }
    }

    private func trimForGlasses(_ string: String, font: HUDFont) -> String {
        let maxChars: Int

        switch font {
        case .small:
            maxChars = 28
        case .medium:
            maxChars = 20
        case .large:
            maxChars = 14
        case .huge:
            maxChars = 10
        }

        guard string.count > maxChars else {
            return string
        }

        return String(string.prefix(maxChars))
    }

    // MARK: - Coordinates

    private func adjustedX(_ x: Int) -> Int {
        x + xOffset
    }

    private func adjustedY(_ y: Int) -> Int {
        y + yOffset
    }

    private func clampX(_ x: Int) -> Int {
        max(0, min(Display.w - 1, adjustedX(x)))
    }

    private func clampY(_ y: Int) -> Int {
        max(0, min(Display.h - 1, adjustedY(y)))
    }

    private func clampTextX(_ x: Int) -> Int {
        // Use wider bounds because we are already applying optical xOffset.
        max(0, min(275, adjustedX(x)))
    }

    private func clampTextY(_ y: Int) -> Int {
        max(Display.safeMinY, min(Display.safeMaxY, adjustedY(y)))
    }

    private func glassY(_ y: Int) -> Int16 {
        let flipped = Display.h - y
        return Int16(max(0, min(255, flipped)))
    }

    private func glassTextY(_ y: Int) -> Int16 {
        let flipped = Display.h - y - textBaselineOffset
        return Int16(max(0, min(255, flipped)))
    }

    private func i16(_ value: Int) -> Int16 {
        Int16(max(-32000, min(32000, value)))
    }

    private func u8(_ value: Int) -> UInt8 {
        UInt8(max(0, min(255, value)))
    }
}
