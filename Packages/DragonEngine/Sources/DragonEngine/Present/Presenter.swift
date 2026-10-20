//  Presenter.swift
//  The in-between frames of a change of screen, and the heads-up drawn over
//  them. Pure: given the frame that was up, the target frame, the Transition
//  and how long ago the change began, it gives the frame to show now; it
//  never reads the clock.
//
//  A change plays its out phase on the old frame (dimmer and dimmer, or
//  sinking, or the display's luma ramping down), then its in phase on the
//  target (brighter, rising into place, or luma ramping up), then holds the
//  target. Frame k of a phase of n steps sits at k / (n - 1) of its duration:
//      in:  level (k + 1) / n, so the last frame is the target itself
//      out: level (n - 1 - k) / n, so the last frame (level 0) is what comes
//           next: the in phase's first frame, or the target.
//  A slide starts `distance` px low and rises to its place at the last frame
//  in (out: sinks from its place), cut to the room the safe zone leaves, so every frame stays inside it. Text is never
//  changed, only its colour and position, so every frame keeps the font
//  limits the target keeps.

import Foundation

public enum Presenter {
    /// Every frame of the change with its offset from the start; the last is `to`.
    public static func steps(from: HUDFrame, to: HUDFrame, transition: Transition) -> [(at: TimeInterval, frame: HUDFrame)] {
        var out: [(TimeInterval, HUDFrame)] = []
        let outDuration = transition.out?.duration ?? 0
        if let phase = transition.out {
            // The phase's last frame (level 0) is what comes next, drawn by the in phase or the target.
            for (k, at) in phase.times.enumerated().dropLast() {
                out.append((at, apply(phase, step: k, to: from, entering: false)))
            }
        }
        if let phase = transition.in {
            for (k, at) in phase.times.enumerated() {
                out.append((outDuration + at, apply(phase, step: k, to: to, entering: true)))
            }
        } else {
            out.append((outDuration, to))
        }
        return out
    }

    /// The frame to show `elapsed` seconds after the change began: the latest
    /// step at or before it (the target once the change is over).
    public static func frame(from: HUDFrame, to: HUDFrame, transition: Transition, elapsed: TimeInterval) -> HUDFrame {
        if transition.isCut || elapsed >= transition.duration { return to }
        let all = steps(from: from, to: to, transition: transition)
        return all.last { $0.at <= elapsed + 1e-9 }?.frame ?? all[0].frame
    }

    /// Frame `k` of `phase` on `frame`: entering, at level (k + 1) / n; leaving,
    /// at level (n - 1 - k) / n. A slide is `distance` low at the first frame
    /// in and rises to 0 at the last; on the way out it sinks from 0.
    static func apply(_ phase: Transition.Phase, step k: Int, to frame: HUDFrame, entering: Bool) -> HUDFrame {
        let n = phase.steps
        let level = entering ? k + 1 : n - 1 - k
        guard level < n else { return frame }
        let fraction = Double(level) / Double(n)
        switch phase.style {
        case .fade:
            return scaled(frame, by: fraction)
        case .slide(let distance):
            let travelled = n > 1 ? Double(k) / Double(n - 1) : 1
            let down = Double(distance) * (entering ? 1 - travelled : travelled)
            return shifted(scaled(frame, by: fraction), down: Int(down.rounded()))
        case .glow:
            return glowing(frame, by: fraction)
        }
    }

    /// Every op's colour level times `fraction` (a lit op stays at least 1; black stays black).
    public static func scaled(_ frame: HUDFrame, by fraction: Double) -> HUDFrame {
        func s(_ c: UInt8) -> UInt8 {
            guard c > 0 else { return 0 }
            return UInt8(max(1, min(Double(c), (Double(c) * fraction).rounded())))
        }
        var f = HUDFrame()
        for op in frame.ops {
            switch op {
            case .clear, .luma, .led: f.add(op)
            case .text(let x, let y, let font, let c, let a, let str): f.add(.text(x: x, y: y, font: font, color: s(c), align: a, str))
            case .line(let a, let b, let c, let d, let col): f.add(.line(x0: a, y0: b, x1: c, y1: d, color: s(col)))
            case .rect(let a, let b, let c, let d, let col): f.add(.rect(x0: a, y0: b, x1: c, y1: d, color: s(col)))
            case .rectf(let a, let b, let c, let d, let col): f.add(.rectf(x0: a, y0: b, x1: c, y1: d, color: s(col)))
            case .circ(let x, let y, let r, let col): f.add(.circ(x: x, y: y, r: r, color: s(col)))
            case .circf(let x, let y, let r, let col): f.add(.circf(x: x, y: y, r: r, color: s(col)))
            }
        }
        return f
    }

    /// The frame's luma times `fraction` (at least 1, so the display is on), colours as they are.
    public static func glowing(_ frame: HUDFrame, by fraction: Double) -> HUDFrame {
        var f = HUDFrame()
        f.ops = frame.ops.map { op in
            guard case .luma(let l) = op else { return op }
            return .luma(UInt8(max(1, (Double(l) * fraction).rounded())))
        }
        return f
    }

    /// Every drawing op moved down by `down` px, or as far as the safe zone allows.
    public static func shifted(_ frame: HUDFrame, down: Int) -> HUDFrame {
        let lowest = frame.ops.compactMap { $0.bounds?.maxY }.max() ?? Display.safeMaxY
        let dy = max(0, min(down, Display.safeMaxY - lowest))
        guard dy > 0 else { return frame }
        var f = HUDFrame()
        for op in frame.ops {
            switch op {
            case .clear, .luma, .led: f.add(op)
            case .text(let x, let y, let font, let c, let a, let str): f.add(.text(x: x, y: y + dy, font: font, color: c, align: a, str))
            case .line(let a, let b, let c, let d, let col): f.add(.line(x0: a, y0: b + dy, x1: c, y1: d + dy, color: col))
            case .rect(let a, let b, let c, let d, let col): f.add(.rect(x0: a, y0: b + dy, x1: c, y1: d + dy, color: col))
            case .rectf(let a, let b, let c, let d, let col): f.add(.rectf(x0: a, y0: b + dy, x1: c, y1: d + dy, color: col))
            case .circ(let x, let y, let r, let col): f.add(.circ(x: x, y: y + dy, r: r, color: col))
            case .circf(let x, let y, let r, let col): f.add(.circf(x: x, y: y + dy, r: r, color: col))
            }
        }
        return f
    }

    // MARK: Heads-up

    /// Where the status dot sits (the Renderer's quiet screen draws it here).
    public static let statusDot = (x: 270, y: 44, r: 3)
    /// The edge tick: a small box at the bottom edge, filled left to right.
    public static let edgeTickBox = (x0: 132, y0: 216, x1: 172, y1: 220)

    /// `frame` with the heads-up drawn over it, `elapsed` seconds into a
    /// heads-up `lead` seconds long. dotPulse: the status dot at full
    /// brightness (drawn where it always is, cue or not); edgeTick: the box at
    /// the bottom edge, filling over the last `config.edgeTick` seconds in
    /// `config.edgeTickSteps` frames; ledBlink: the LED blinking. watchTap
    /// draws nothing (the app delivers it).
    public static func headsUp(_ frame: HUDFrame, kinds: Set<HeadsUpKind>, elapsed: TimeInterval,
                               config: SegueConfig = SegueConfig()) -> HUDFrame {
        var f = frame
        if kinds.contains(.dotPulse) {
            let d = statusDot
            f.ops.removeAll { if case .circf(d.x, d.y, _, _) = $0 { return true } else { return false } }
            f.add(.circf(x: d.x, y: d.y, r: d.r, color: config.headsUpDotColor))
        }
        if kinds.contains(.edgeTick) {
            let b = edgeTickBox
            f.add(.rect(x0: b.x0, y0: b.y0, x1: b.x1, y1: b.y1, color: 8))
            let fill = edgeTickFill(elapsed: elapsed, config: config)
            if fill > 0 {
                let x1 = b.x0 + Int((Double(b.x1 - b.x0) * fill).rounded())
                f.add(.rectf(x0: b.x0, y0: b.y0, x1: x1, y1: b.y1, color: 15))
            }
        }
        if kinds.contains(.ledBlink) {
            f.add(.led(.blink))
        }
        return f
    }

    /// How full the edge tick is (0...1, in steps), `elapsed` into the heads-up.
    public static func edgeTickFill(elapsed: TimeInterval, config: SegueConfig = SegueConfig()) -> Double {
        let start = config.headsUpLead - config.edgeTick
        guard elapsed >= start, config.edgeTick > 0 else { return 0 }
        let steps = max(1, config.edgeTickSteps)
        let done = min(1, (elapsed - start) / config.edgeTick)
        return Double(min(steps, Int(done * Double(steps)) + 1)) / Double(steps)
    }
}
