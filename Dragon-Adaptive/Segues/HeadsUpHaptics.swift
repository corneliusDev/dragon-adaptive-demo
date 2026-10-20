//  HeadsUpHaptics.swift
//  The Watch-tap heads-up: when a heads-up starts and the Watch tap is on
//  (the plan's heads-ups for a main-flow run, SegueSettingsStore for the
//  developer race, the PREVIEW being played), the run calls headsUp(_:) here.
//
//  WatchHeadsUpHaptics sends it to the Watch through the Watch link (the
//  mirrored workout when it is up, else WatchConnectivity) as a tap command:
//  tapLight for an advisory or info cue, tapStrong for a critical or safety
//  one (WatchHaptic.forHeadsUp). The Watch plays it (WatchTapHandler).
//  NoHeadsUpHaptics stands in where there is no Watch (tests, previews).

import Foundation
import DragonEngine

protocol HeadsUpHaptics: AnyObject {
    /// A predictable cue is coming: tap the runner's wrist now.
    func headsUp(_ signal: RunEngine.HeadsUpSignal)
}

/// Sends commands to the Watch (WatchLink; a fake in tests).
protocol WatchCommandSending: AnyObject {
    /// Returns false when nothing could be sent (no route up).
    @discardableResult
    func send(_ command: WatchCommand) -> Bool
}

/// Taps the wrist through the Watch link.
final class WatchHeadsUpHaptics: HeadsUpHaptics {
    private let link: WatchCommandSending
    /// Taps sent (and how many couldn't be), for the Developer menu and tests.
    private(set) var sent = 0
    private(set) var unsent = 0

    init(link: WatchCommandSending) {
        self.link = link
    }

    func headsUp(_ signal: RunEngine.HeadsUpSignal) {
        let command = WatchHaptic.forHeadsUp(signal.priority).command
        if link.send(command) { sent += 1 } else { unsent += 1 }
    }
}

/// Does nothing; counts calls for tests.
final class NoHeadsUpHaptics: HeadsUpHaptics {
    private(set) var count = 0

    func headsUp(_ signal: RunEngine.HeadsUpSignal) {
        count += 1
    }
}
