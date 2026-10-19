//  CueRenderer.swift
//  Minimal render of the chosen cue (until chunk 7's renderer): a centred
//  column inside the safe zone — heading, the value, up to two lines under
//  it, and the tag if there's room. With no cue, the quiet screen: a dim
//  dot that says the engine is running and nothing needs attention.
//  This is where seconds and metres become "8:14" and "7:53 / MI".

import Foundation

public enum CueFormat {
    public static func string(_ text: CueText) -> String {
        switch text {
        case .label(let s):
            return s
        case .marker(let n, let unit):
            return "\(unit == .miles ? "MILE" : "KM") \(n)"
        case .duration(let seconds):
            return clock(seconds)
        case .gap(let seconds):
            let total = Int(seconds.rounded())
            return String(format: "%@%d:%02d", total < 0 ? "-" : "+", abs(total) / 60, abs(total) % 60)
        case .pace(let secondsPerMeter, let unit):
            guard secondsPerMeter.isFinite, secondsPerMeter > 0 else { return "--" }
            let total = Int((secondsPerMeter * unit.meters).rounded())
            return String(format: "%d:%02d / %@", total / 60, total % 60, unit == .miles ? "MI" : "KM")
        case .phrase(let parts):
            return parts.map(string).joined(separator: " ")
        }
    }

    /// 1:45:48, or 8:14 under an hour.
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

public enum CueRenderer {
    /// The frame for a cue (or the quiet screen), brighter as effort rises.
    public static func frame(for cue: Cue?, effort: MotionBand = .moderate) -> HUDFrame {
        var f = HUDFrame()
        f.add(.clear)
        f.add(.luma([8, 11, 13, 15][effort.rawValue]))
        guard let cue else {
            f.add(.circf(x: Display.cx, y: Display.safeMaxY - 16, r: 3, color: 5))
            return f
        }

        let c = cue.content, cx = Display.cx
        if let heading = c.heading {
            f.add(.text(x: cx, y: 62, font: .small, color: 10, align: .center, CueFormat.string(heading)))
        }
        f.add(.text(x: cx, y: 118, font: .large, color: 15, align: .center, CueFormat.string(c.main)))
        for (i, line) in c.subtitle.prefix(2).enumerated() {
            f.add(.text(x: cx, y: 156 + i * 32, font: .medium, color: i == 0 ? 13 : 11, align: .center,
                        CueFormat.string(line)))
        }
        if let tag = c.tag, c.subtitle.count <= 1 {
            f.add(.rect(x0: cx - 36, y0: 186, x1: cx + 36, y1: 214, color: 8))
            f.add(.text(x: cx, y: 206, font: .small, color: 11, align: .center, tag))
        }
        return f
    }
}
