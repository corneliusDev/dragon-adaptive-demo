//  HUDOp.swift
//  Device-independent draw ops.
//  Coordinates are 304 × 256, origin top-left, y down.
//  GlassesBackend converts these into ActiveLook's real coordinate system.

import Foundation

enum HUDFont: UInt8 {
    case small = 1
    case medium = 2
    case large = 3
    case huge = 4

    var advance: Int {
        switch self {
        case .small: return 7
        case .medium: return 10
        case .large: return 15
        case .huge: return 18
        }
    }
}

enum HUDAlign {
    case left
    case center
}

enum HUDOp {
    case clear
    case luma(UInt8)
    case text(x: Int, y: Int, font: HUDFont, color: UInt8, align: HUDAlign, _ string: String)
    case line(x0: Int, y0: Int, x1: Int, y1: Int, color: UInt8)
    case rect(x0: Int, y0: Int, x1: Int, y1: Int, color: UInt8)
    case rectf(x0: Int, y0: Int, x1: Int, y1: Int, color: UInt8)
    case circ(x: Int, y: Int, r: Int, color: UInt8)
    case circf(x: Int, y: Int, r: Int, color: UInt8)
}

enum Display {
    static let w = 304
    static let h = 256
    static let cx = 152
    static let cy = 128

    // Conservative visible area for real glasses.
    static let safeMinX = 20
    static let safeMaxX = 284
    static let safeMinY = 30
    static let safeMaxY = 220
}

struct HUDFrame {
    var ops: [HUDOp] = []

    mutating func add(_ op: HUDOp) {
        ops.append(op)
    }

    var signature: String {
        ops.map { op in
            switch op {
            case .clear:
                return "c"
            case .luma(let l):
                return "l\(l)"
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
