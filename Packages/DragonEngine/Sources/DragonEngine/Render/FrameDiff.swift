//  FrameDiff.swift
//  Redraw only what changed. Given the frame on the glasses and the next one,
//  `patch` gives the ops that turn the first into the second without clearing
//  the display: black boxes over what went away or changed, then the ops of
//  the new frame that must be drawn (what is new, what a black box cut into,
//  and anything the new frame draws over those). Luma and the LED are sent
//  only when they change.
//
//  It stays correct by being cautious, falling back to a full redraw (nil)
//  whenever it isn't sure: either frame doesn't start by clearing the
//  display, or the patch would be about as much work as redrawing.
//  Blacked-out boxes are the ops' bounds grown by a margin, more for text,
//  whose size on the glasses is only estimated.

import Foundation

public enum FrameDiff {
    public struct Config: Sendable, Equatable {
        /// Pixels added on every side of a removed op's bounds before blacking it out.
        public var margin = 2
        /// Extra pixels for text, whose drawn size is an estimate (font metrics, baseline).
        public var textMargin = 4
        /// A patch with more ops than this fraction of a full redraw's isn't worth it: redraw.
        public var maxFraction = 0.8

        public init() {}
    }

    public typealias Box = (minX: Int, minY: Int, maxX: Int, maxY: Int)

    /// The ops that take the display from `old` to `new`, or nil when a full
    /// redraw (`new` as it is) is the safe way.
    public static func patch(from old: HUDFrame, to new: HUDFrame, config: Config = Config()) -> [HUDOp]? {
        guard case .clear? = old.ops.first, case .clear? = new.ops.first else { return nil }
        let a = drawing(old), b = drawing(new)

        // What stays: ops in both, matched one for one, in the same order (a
        // reordering changes what is on top: redraw).
        var used = [Bool](repeating: false, count: a.count)
        var keptInNew = [Bool](repeating: false, count: b.count)
        var lastMatched = -1
        for (j, op) in b.enumerated() {
            if let i = a.indices.first(where: { !used[$0] && a[$0] == op }) {
                guard i > lastMatched else { return nil }
                lastMatched = i
                used[i] = true
                keptInNew[j] = true
            }
        }

        // Black out what went away.
        let boxes = a.indices.filter { !used[$0] }.compactMap { box(a[$0], config: config) }

        // Draw what is new, what a black box touches, and (in the new frame's
        // order) anything drawn after and over something being redrawn.
        var redraw = [Bool](repeating: false, count: b.count)
        for (j, op) in b.enumerated() {
            guard keptInNew[j] else { redraw[j] = true; continue }
            if let ob = box(op, config: config), boxes.contains(where: { overlaps($0, ob) }) { redraw[j] = true }
        }
        var changed = true
        while changed {
            changed = false
            for j in b.indices where !redraw[j] {
                guard let bj = box(b[j], config: config) else { continue }
                if (0..<j).contains(where: { redraw[$0] && box(b[$0], config: config).map { overlaps($0, bj) } == true }) {
                    redraw[j] = true
                    changed = true
                }
            }
        }

        var ops: [HUDOp] = []
        if luma(old) != luma(new), let l = luma(new) { ops.append(.luma(l)) }
        if led(old) != led(new) { ops.append(.led(led(new))) }
        for bx in boxes {
            ops.append(.rectf(x0: bx.minX, y0: bx.minY, x1: bx.maxX, y1: bx.maxY, color: 0))
        }
        ops += b.indices.filter { redraw[$0] }.map { b[$0] }

        // A full redraw is a black screen and every op.
        let drawn = ops.filter { $0.bounds != nil }.count
        guard Double(drawn) <= config.maxFraction * Double(1 + b.count) else { return nil }
        return ops
    }

    /// The ops that draw something (not clear, luma or the LED).
    static func drawing(_ f: HUDFrame) -> [HUDOp] { f.ops.filter { $0.bounds != nil } }

    /// The frame's last luma, if it sets one.
    public static func luma(_ f: HUDFrame) -> UInt8? {
        f.ops.reduce(nil as UInt8?) { l, op in if case .luma(let v) = op { return v } else { return l } }
    }

    /// The frame's LED state: its last LED op, else off.
    public static func led(_ f: HUDFrame) -> HUDLed {
        f.ops.reduce(HUDLed.off) { s, op in if case .led(let v) = op { return v } else { return s } }
    }

    /// The op's bounds grown by the margin, kept on the display.
    static func box(_ op: HUDOp, config: Config) -> Box? {
        guard let b = op.bounds else { return nil }
        var m = config.margin
        if case .text = op { m += config.textMargin }
        return (max(0, b.minX - m), max(0, b.minY - m), min(Display.w - 1, b.maxX + m), min(Display.h - 1, b.maxY + m))
    }

    static func overlaps(_ a: Box, _ b: Box) -> Bool {
        a.minX <= b.maxX && b.minX <= a.maxX && a.minY <= b.maxY && b.minY <= a.maxY
    }
}
