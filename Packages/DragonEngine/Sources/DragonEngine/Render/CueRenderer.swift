//  CueRenderer.swift
//  CueFormat: where seconds and metres become "8:14", "7:53 / MI" and
//  "0.20 MI". CueRenderer is chunk 4's entry point, kept for its callers: it
//  now draws through Renderer with room for the full layout.

import Foundation

public enum CueFormat {
    /// The text for one piece of cue content, distances in miles.
    public static func string(_ text: CueText) -> String {
        string(text, unit: .miles)
    }

    /// The text for one piece of cue content. `unit` is for `.distance`;
    /// markers and paces carry their own.
    public static func string(_ text: CueText, unit: DistanceUnit) -> String {
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
        case .distance(let meters):
            let n = max(0, meters) / unit.meters
            return String(format: n < 10 ? "%.2f %@" : "%.1f %@", n, unit == .miles ? "MI" : "KM")
        case .phrase(let parts):
            return parts.map { string($0, unit: unit) }.joined(separator: " ")
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
    /// The frame for a cue (or the quiet screen) in its full layout, brighter as effort rises.
    public static func frame(for cue: Cue?, effort: MotionBand = .moderate) -> HUDFrame {
        Renderer.frame(for: cue, budget: .relaxed, state: RunState(elapsed: 0, distance: 0, effort: effort),
                       unit: .miles)
    }
}
