//  Presentation.swift
//  What RunEngine keeps between updates to play its changes of screen: the
//  cue on screen, the change playing and when it began. Each update hands it
//  the renderer's frame for the arbiter's cue (the target) and the heads-up
//  running, and gets back the frame to show now. A new cue (or the quiet
//  screen after one) starts a change, with the Transition the segue setting
//  gives (Transition.between); the same cue redrawn (a countdown ticking)
//  just replaces the target, with no easing. The heads-up is drawn over
//  whatever is up. A value; it never reads the clock.

import Foundation

public struct Presentation: Sendable {
    /// A cue on screen, told apart from a newer one with the same key.
    struct Identity: Sendable, Equatable {
        let key: CueKey
        let createdAt: TimeInterval
    }

    public var segue: Segue
    public var headsUp: Set<HeadsUpKind>
    public var config: SegueConfig
    /// The change playing (or played last).
    public private(set) var transition = Transition.cut
    /// Run time the change began.
    public private(set) var changedAt: TimeInterval = -.infinity
    /// The cue the target is for (nil: the quiet screen).
    public private(set) var cue: Cue?
    /// The frame the change started from.
    private var from = HUDFrame()
    /// The latest target.
    private var target: HUDFrame?

    public init(segue: Segue = .default, headsUp: Set<HeadsUpKind> = HeadsUpKind.defaultSetting,
                config: SegueConfig = SegueConfig()) {
        self.segue = segue
        self.headsUp = headsUp
        self.config = config
    }

    /// The frame to show at `t` for `target`, the frame of `cue` (nil: the
    /// quiet screen), with the heads-up that began at `headsUpSince` drawn over it.
    public mutating func frame(target new: HUDFrame, cue next: Cue?, headsUpSince: TimeInterval?,
                               at t: TimeInterval) -> HUDFrame {
        let id = next.map { Identity(key: $0.key, createdAt: $0.createdAt) }
        let was = cue.map { Identity(key: $0.key, createdAt: $0.createdAt) }
        if let old = target, id != was {
            from = old
            transition = Transition.between(cue, next, segue: segue, config: config)
            changedAt = t
        }
        cue = next
        target = new
        var f = Presenter.frame(from: from, to: new, transition: transition, elapsed: t - changedAt)
        if let since = headsUpSince {
            f = Presenter.headsUp(f, kinds: headsUp, elapsed: t - since, config: config)
        }
        return f
    }
}
