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
//  - Font limits (largest font, characters per font, advance) come from
//    DragonEngine's HUDFont, the same source the Renderer fits text to.
//
//  Smoother swaps (chunk 14):
//  - Every frame is drawn inside holdFlush(.HOLD) … holdFlush(.FLUSH), so it
//    appears at once instead of op by op.
//  - The SDK doesn't hold clear(), so a frame's .clear is drawn as a black
//    filled rectangle over the whole display instead.
//  - Only what changed is redrawn when FrameDiff can patch the last frame
//    into the next; otherwise the whole frame.
//  - .led ops (heads-up) map to led(state:), sent only when the state changes.
//  - The commands go through GlassesCommands, which the SDK's Glasses
//    implements and tests fake.
//

import Foundation
import ActiveLookSDK
import DragonEngine

/// The ActiveLook calls the backend makes: the SDK's Glasses, or a test recorder.
protocol GlassesCommands: AnyObject {
    func clear()
    func luma(level: UInt8)
    func color(level: UInt8)
    func line(x0: Int16, x1: Int16, y0: Int16, y1: Int16)
    func rect(x0: Int16, x1: Int16, y0: Int16, y1: Int16)
    func rectf(x0: Int16, x1: Int16, y0: Int16, y1: Int16)
    func circ(x: Int16, y: Int16, radius: UInt8)
    func circf(x: Int16, y: Int16, radius: UInt8)
    func txt(x: Int16, y: Int16, rotation: TextRotation, font: UInt8, color: UInt8, string: String)
    func holdFlush(holdFlush: HoldFlushAction)
    func led(state: LedState)
    func power(on: Bool)
}

extension Glasses: GlassesCommands {}

final class GlassesBackend {
    private weak var glasses: GlassesCommands?
    private var lastSignature = ""
    /// The frame on the glasses, for redrawing only what changed; nil = unknown (redraw whole).
    private var lastFrame: HUDFrame?
    /// The LED state last sent.
    private var ledState = HUDLed.off
    /// Redraw only what changed (FrameDiff); off sends every frame whole.
    var partialRedraw = true

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

    /// For tests: any GlassesCommands (kept weakly, like the glasses).
    init(commands: GlassesCommands) {
        self.glasses = commands
    }

    func invalidate() {
        lastSignature = ""
        lastFrame = nil
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
        // Only what changed, when that is safe; else the whole frame.
        let ops = (partialRedraw ? lastFrame.flatMap { FrameDiff.patch(from: $0, to: frame) } : nil) ?? frame.ops
        lastFrame = frame

        g.holdFlush(holdFlush: .HOLD)
        for op in ops {
            switch op {
            case .clear:
                // clear() isn't held: black out the whole display instead.
                g.color(level: 0)
                g.rectf(x0: 0, x1: Int16(Display.w - 1), y0: 0, y1: Int16(Display.h - 1))

            case .luma(let level):
                g.luma(level: level)

            case .led:
                break

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
        g.holdFlush(holdFlush: .FLUSH)

        // The LED: the frame's state (off without an .led op), sent when it changes.
        let led = FrameDiff.led(frame)
        if led != ledState {
            ledState = led
            g.led(state: led == .blink ? .blink : led == .on ? .on : .off)
        }
    }

    // MARK: - Calibration / diagnostics

    func sendCalibrationPattern() {
        guard let g = glasses else {
            print("[GlassesBackend] calibration skipped: glasses nil")
            return
        }

        print("[GlassesBackend] sending calibration pattern")

        invalidate()

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

        invalidate()

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
        glasses g: GlassesCommands,
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
        _ g: GlassesCommands,
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
            font: min(font, HUDFont.largestOnGlasses.rawValue),
            color: color,
            string: string
        )
    }

    private func safeFont(_ font: HUDFont) -> UInt8 {
        // Avoid font 4 for now. Real glasses often make this too large.
        font.onGlasses.rawValue
    }

    private func estimatedAdvance(for font: HUDFont) -> Int {
        font.advance
    }

    /// A safety net: the Renderer already fits text to these limits.
    private func trimForGlasses(_ string: String, font: HUDFont) -> String {
        guard string.count > font.maxChars else {
            return string
        }

        return String(string.prefix(font.maxChars))
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
