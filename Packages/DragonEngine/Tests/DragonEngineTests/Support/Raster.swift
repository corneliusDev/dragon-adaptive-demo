//  Raster.swift
//  Test support: a model of the glasses' display, 304 × 256 colour levels,
//  for checking that drawing a patch over one frame looks the same as
//  drawing the next frame whole. Ops paint over each other in order, no
//  blending, like the glasses. Text is modelled as a pattern of pixels inside
//  its estimated bounds that depends on the string, font and colour (what the
//  glasses really draw is inside those bounds, give or take the margin
//  FrameDiff allows for).

import DragonEngine

struct Raster: Equatable {
    var pixels = [UInt8](repeating: 0, count: Display.w * Display.h)
    var luma: UInt8 = 0
    var led = HUDLed.off

    mutating func set(_ x: Int, _ y: Int, _ c: UInt8) {
        guard x >= 0, x < Display.w, y >= 0, y < Display.h else { return }
        pixels[y * Display.w + x] = c
    }

    mutating func draw(_ ops: [HUDOp]) {
        for op in ops { draw(op) }
    }

    mutating func draw(_ op: HUDOp) {
        switch op {
        case .clear:
            pixels = [UInt8](repeating: 0, count: pixels.count)
        case .luma(let l):
            luma = l
        case .led(let state):
            led = state
        case .line(let x0, let y0, let x1, let y1, let c):
            let n = max(abs(x1 - x0), abs(y1 - y0), 1)
            for i in 0...n {
                set(x0 + (x1 - x0) * i / n, y0 + (y1 - y0) * i / n, c)
            }
        case .rect(let x0, let y0, let x1, let y1, let c):
            for x in min(x0, x1)...max(x0, x1) { set(x, y0, c); set(x, y1, c) }
            for y in min(y0, y1)...max(y0, y1) { set(x0, y, c); set(x1, y, c) }
        case .rectf(let x0, let y0, let x1, let y1, let c):
            for y in min(y0, y1)...max(y0, y1) { for x in min(x0, x1)...max(x0, x1) { set(x, y, c) } }
        case .circ(let cx, let cy, let r, let c):
            for y in (cy - r)...(cy + r) { for x in (cx - r)...(cx + r) {
                let d = (x - cx) * (x - cx) + (y - cy) * (y - cy)
                if d <= r * r && d >= (r - 1) * (r - 1) { set(x, y, c) }
            } }
        case .circf(let cx, let cy, let r, let c):
            for y in (cy - r)...(cy + r) { for x in (cx - r)...(cx + r)
                where (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r { set(x, y, c) } }
        case .text(_, _, let font, let c, _, let s):
            guard let b = op.bounds else { return }
            var h = UInt64(5381)
            for u in s.unicodeScalars { h = h &* 33 &+ UInt64(u.value) }
            h = h &* 31 &+ UInt64(font.rawValue)
            for y in b.minY...b.maxY { for x in b.minX...b.maxX {
                let bit = (h >> UInt64((x &* 7 &+ y &* 13) % 61)) & 1
                if bit == 1 { set(x, y, c) }
            } }
        }
    }

    static func of(_ frame: HUDFrame) -> Raster {
        var r = Raster()
        r.draw(frame.ops)
        return r
    }
}
