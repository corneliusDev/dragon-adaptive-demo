//  HUDOp.swift
//  Device-independent draw ops.
//  Coordinates are 304 × 256, origin top-left, y down.
//  GlassesBackend converts these into ActiveLook's real coordinate system.

import Foundation

public enum HUDFont: UInt8, Sendable, CaseIterable {
    case small = 1
    case medium = 2
    case large = 3
    case huge = 4

    public var advance: Int {
        switch self {
        case .small: return 7
        case .medium: return 10
        case .large: return 15
        case .huge: return 18
        }
    }

    /// Characters a line in this font may hold: GlassesBackend cuts anything
    /// longer off, so the renderer fits text to this first.
    public var maxChars: Int {
        switch self {
        case .small: return 28
        case .medium: return 20
        case .large: return 14
        case .huge: return 10
        }
    }

    /// Height of a line, for layout and safe-zone checks (text is drawn centred on its y).
    public var height: Int {
        switch self {
        case .small: return 12
        case .medium: return 16
        case .large: return 22
        case .huge: return 26
        }
    }

    /// The largest font the glasses draw: font 4 is clamped to 3 until the real
    /// display is calibrated, so the renderer never asks for it.
    public static let largestOnGlasses = HUDFont.large

    /// The font the glasses actually use for this one.
    public var onGlasses: HUDFont {
        rawValue > HUDFont.largestOnGlasses.rawValue ? HUDFont.largestOnGlasses : self
    }

    /// The next size down, nil for the smallest.
    public var smaller: HUDFont? { HUDFont(rawValue: rawValue - 1) }
}

/// Text fitting that matches what the glasses accept.
public enum HUDText {
    /// The font and string to draw `string` in, starting at `font` (capped at
    /// what the glasses draw) and stepping down a size while it is over the
    /// font's character limit or wider than `width` points. Cut short only
    /// when even the smallest font can't hold it.
    public static func fit(_ string: String, font: HUDFont, width: Int? = nil) -> (font: HUDFont, string: String) {
        var f = font.onGlasses
        func fits(_ f: HUDFont) -> Bool {
            string.count <= f.maxChars && width.map { string.count * f.advance <= $0 } != false
        }
        while !fits(f), let next = f.smaller { f = next }
        guard !fits(f) else { return (f, string) }
        var limit = f.maxChars
        if let width { limit = min(limit, width / f.advance) }
        return (f, String(string.prefix(max(0, limit))))
    }
}

public enum HUDAlign: Sendable, Equatable {
    case left
    case center
}

/// The glasses' green LED.
public enum HUDLed: String, Sendable, Equatable, Codable {
    case off, on, blink
}

public enum HUDOp: Sendable, Equatable {
    case clear
    case luma(UInt8)
    /// The LED's state; like luma, a state op that draws nothing. A frame
    /// without one leaves the LED off.
    case led(HUDLed)
    case text(x: Int, y: Int, font: HUDFont, color: UInt8, align: HUDAlign, _ string: String)
    case line(x0: Int, y0: Int, x1: Int, y1: Int, color: UInt8)
    case rect(x0: Int, y0: Int, x1: Int, y1: Int, color: UInt8)
    case rectf(x0: Int, y0: Int, x1: Int, y1: Int, color: UInt8)
    case circ(x: Int, y: Int, r: Int, color: UInt8)
    case circf(x: Int, y: Int, r: Int, color: UInt8)
}

public enum Display {
    public static let w = 304
    public static let h = 256
    public static let cx = 152
    public static let cy = 128

    // Conservative visible area for real glasses.
    public static let safeMinX = 20
    public static let safeMaxX = 284
    public static let safeMinY = 30
    public static let safeMaxY = 220
}

extension HUDOp {
    /// What the op covers on the display (inclusive), nil for state ops (clear, luma, led).
    /// Text is estimated from the font's advance and line height.
    public var bounds: (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        switch self {
        case .clear, .luma, .led:
            return nil
        case .text(let x, let y, let font, _, let align, let s):
            let w = s.count * font.advance
            let left = align == .center ? x - w / 2 : x
            return (left, y - font.height / 2, left + w, y + font.height / 2)
        case .line(let x0, let y0, let x1, let y1, _), .rect(let x0, let y0, let x1, let y1, _),
             .rectf(let x0, let y0, let x1, let y1, _):
            return (min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1))
        case .circ(let x, let y, let r, _), .circf(let x, let y, let r, _):
            return (x - r, y - r, x + r, y + r)
        }
    }

    /// Whether the op lies inside the conservative visible area of the glasses.
    public var isInsideSafeZone: Bool {
        guard let b = bounds else { return true }
        return b.minX >= Display.safeMinX && b.maxX <= Display.safeMaxX
            && b.minY >= Display.safeMinY && b.maxY <= Display.safeMaxY
    }
}

public struct HUDFrame: Sendable, Equatable {
    public var ops: [HUDOp] = []

    public init() {}

    public mutating func add(_ op: HUDOp) {
        ops.append(op)
    }

    public var signature: String {
        ops.map { op in
            switch op {
            case .clear:
                return "c"
            case .luma(let l):
                return "l\(l)"
            case .led(let state):
                return "D\(state.rawValue)"
            case .text(let x, let y, let f, let col, _, let s):
                return "t\(x),\(y),\(f.rawValue),\(col),\(s)"
            case .line(let a, let b, let c, let d, let e):
                return "L\(a),\(b),\(c),\(d),\(e)"
            case .rect(let a, let b, let c, let d, let e):
                return "R\(a),\(b),\(c),\(d),\(e)"
            case .rectf(let a, let b, let c, let d, let e):
                return "F\(a),\(b),\(c),\(d),\(e)"
            case .circ(let a, let b, let c, let d):
                return "O\(a),\(b),\(c),\(d)"
            case .circf(let a, let b, let c, let d):
                return "Q\(a),\(b),\(c),\(d)"
            }
        }
        .joined(separator: "|")
    }
}
