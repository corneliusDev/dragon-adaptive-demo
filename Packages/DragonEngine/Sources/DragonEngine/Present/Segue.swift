//  Segue.swift
//  How cues come onto and leave the glasses (the Segue setting), what warns
//  the runner that one is coming (the HeadsUp setting), and the numbers both
//  are tuned with (SegueConfig). A Transition is one change of what is on
//  screen, as the Presenter plays it: an optional out phase for what was up,
//  then an optional in phase for what comes next; with neither it is a cut.
//
//  Whatever the setting: safety and critical cues, and the answers to a
//  glance or a held look, cut in (one frame); cues always appear in the same
//  place (a slide only moves them on the way in and out).

import Foundation

/// How a cue eases on and off the glasses.
public enum Segue: String, Sendable, Codable, CaseIterable {
    /// One frame: today's behaviour.
    case instant
    /// Fades in over ~300 ms in 4 brightness steps (every op's colour level
    /// scaled) and out to the status dot over ~500 ms.
    case fade
    /// Rises a few pixels into place while fading in; sinks while fading out.
    case slide
    /// The whole display's brightness (luma) ramps up from dark, and down on exit.
    case glow

    public static let `default` = Segue.fade
}

/// One way of warning that a predictable cue is about to appear. The setting
/// is a set of these; empty is Off.
public enum HeadsUpKind: String, Sendable, Codable, CaseIterable, Hashable {
    /// The status dot brightens before the cue.
    case dotPulse
    /// A small mark at the bottom edge of the display fills over the last second.
    case edgeTick
    /// The glasses' green LED blinks.
    case ledBlink
    /// A tap on the wrist (delivered by the app through the Watch; chunk 12).
    case watchTap

    /// The setting's default: the dot.
    public static let defaultSetting: Set<HeadsUpKind> = [.dotPulse]
}

/// Timings and sizes for segues and heads-ups. Every default is documented;
/// the developer screen's sliders tune them on real glasses.
public struct SegueConfig: Sendable, Equatable, Codable {
    /// Seconds a fade (or slide) takes to bring a cue to full brightness (~300 ms).
    public var fadeIn: TimeInterval = 0.3
    /// Frames the fade-in is drawn in, the last at full brightness (4).
    public var fadeInSteps = 4
    /// Seconds a fade (or slide) takes to take a cue off, ending on the status dot (~500 ms).
    public var fadeOut: TimeInterval = 0.5
    /// Frames of the fade-out, the last being what comes next (4: three dimmer
    /// frames, then the dot).
    public var fadeOutSteps = 4
    /// Pixels a slide rises into place (8), less where the safe zone has no room.
    public var slideDistance = 8
    /// Seconds and frames the glow ramps the display's luma up from dark, and down.
    public var glowIn: TimeInterval = 0.3
    public var glowInSteps = 4
    public var glowOut: TimeInterval = 0.5
    public var glowOutSteps = 4
    /// Seconds before a predictable cue that its heads-up starts (1.5 s).
    public var headsUpLead: TimeInterval = 1.5
    /// Metres ahead a distance-based cue (a split's marker, a hill's window,
    /// the last 400 m) is announced from (30 m: ~8 s at race pace, so the
    /// heads-up can start on time).
    public var announceWithin = 30.0
    /// A heads-up that ran this much past its lead without its cue appearing
    /// lapses; the cue gets a fresh one when it can show (0.2 s).
    public var headsUpTolerance: TimeInterval = 0.2
    /// The edge tick fills over the last this-many seconds of the heads-up (1 s)...
    public var edgeTick: TimeInterval = 1
    /// ...in this many frames (4).
    public var edgeTickSteps = 4
    /// Colour level of the status dot during a heads-up (15; at rest it is 7).
    public var headsUpDotColor: UInt8 = 15
    /// Seconds of nothing between two cues in a row (1.5 s): after one leaves,
    /// the next waits this long, unless it is safety or critical, or an answer.
    public var quietGap: TimeInterval = 1.5

    public init() {}
}

/// One change of what is on screen, as the Presenter plays it.
public struct Transition: Sendable, Equatable {
    public enum Style: Sendable, Equatable {
        /// Colour levels scaled.
        case fade
        /// Colour levels scaled and the ops moved up (in) or down (out) by up to `distance` px.
        case slide(distance: Int)
        /// The display's luma scaled.
        case glow
    }

    /// One half of a change: frames over a duration.
    public struct Phase: Sendable, Equatable {
        public var style: Style
        public var duration: TimeInterval
        /// Frames drawn; the last lands at `duration` and is what the phase ends on.
        public var steps: Int

        public init(_ style: Style, duration: TimeInterval, steps: Int) {
            self.style = style
            self.duration = max(0, duration)
            self.steps = max(1, steps)
        }

        /// Offsets of the phase's frames from its start: evenly spaced, the
        /// first at 0 and the last at `duration` (one frame: at 0).
        public var times: [TimeInterval] {
            guard steps > 1 else { return [0] }
            return (0..<steps).map { duration * Double($0) / Double(steps - 1) }
        }
    }

    /// What was up leaves (nil: it is gone at once).
    public var out: Phase?
    /// What comes next arrives (nil: it is there at once).
    public var `in`: Phase?

    public init(out: Phase? = nil, in phase: Phase? = nil) {
        self.out = out
        self.in = phase
    }

    /// One frame, no easing.
    public static let cut = Transition()

    public var isCut: Bool { out == nil && self.in == nil }

    /// Seconds from the start of the change to its last frame.
    public var duration: TimeInterval { (out?.duration ?? 0) + (self.in?.duration ?? 0) }

    /// The in phase for `segue` (nil for instant).
    public static func inPhase(_ segue: Segue, config: SegueConfig) -> Phase? {
        switch segue {
        case .instant: return nil
        case .fade: return Phase(.fade, duration: config.fadeIn, steps: config.fadeInSteps)
        case .slide: return Phase(.slide(distance: config.slideDistance), duration: config.fadeIn, steps: config.fadeInSteps)
        case .glow: return Phase(.glow, duration: config.glowIn, steps: config.glowInSteps)
        }
    }

    /// The out phase for `segue` (nil for instant).
    public static func outPhase(_ segue: Segue, config: SegueConfig) -> Phase? {
        switch segue {
        case .instant: return nil
        case .fade: return Phase(.fade, duration: config.fadeOut, steps: config.fadeOutSteps)
        case .slide: return Phase(.slide(distance: config.slideDistance), duration: config.fadeOut, steps: config.fadeOutSteps)
        case .glow: return Phase(.glow, duration: config.glowOut, steps: config.glowOutSteps)
        }
    }

    /// The change from what was up (`from`, nil = the quiet screen) to what
    /// comes next (`to`, nil = quiet), under `segue`. A cue that must cut in
    /// (`urgent`: safety, critical, or an answer the runner asked for) makes
    /// the whole change a cut, so it is on screen in the first frame.
    public static func between(_ from: Cue?, _ to: Cue?, segue: Segue, config: SegueConfig = SegueConfig()) -> Transition {
        if let to, isUrgent(to) { return .cut }
        return Transition(out: from == nil ? nil : outPhase(segue, config: config),
                          in: to == nil ? nil : inPhase(segue, config: config))
    }

    /// Safety and critical cues, and answers to a glance or held look, cut in.
    public static func isUrgent(_ cue: Cue) -> Bool {
        cue.priority >= .critical || cue.requested
    }
}
