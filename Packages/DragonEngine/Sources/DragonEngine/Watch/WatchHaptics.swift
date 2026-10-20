//  WatchHaptics.swift
//  The Watch-tap heads-up, both ends, minus the devices:
//
//      phone   a heads-up began (RunEngine.Step.headsUpBegan) with the Watch
//              tap on: WatchHaptic.forHeadsUp picks the strength from the
//              coming cue's priority and its command (tapLight / tapStrong)
//              goes to the Watch as a WatchMessage.
//      Watch   WatchTapHandler takes each command that arrived (after
//              WatchMessageFilter's de-duplication), drops a tap that took
//              too long to get there (a heads-up for a cue already on the
//              glasses is noise) and plays the rest on a WatchHapticPlaying,
//              which the Watch app implements with WKInterfaceDevice.
//
//  Times are the message's sentAt and the Watch's own clock (seconds since
//  1970), passed in; nothing here reads a clock.

import Foundation

/// How hard the Watch taps the wrist.
public enum WatchHaptic: String, Sendable, Codable, CaseIterable {
    /// A click: an advisory or info cue is coming.
    case light
    /// A notification buzz: a critical or safety cue is coming.
    case strong

    /// The tap for a heads-up of a cue with this priority.
    public static func forHeadsUp(_ priority: Priority) -> WatchHaptic {
        priority >= .critical ? .strong : .light
    }

    /// The command that plays it on the Watch.
    public var command: WatchCommand {
        switch self {
        case .light: return .tapLight
        case .strong: return .tapStrong
        }
    }
}

/// Plays a haptic on the Watch (WKInterfaceDevice in the app; a recorder in tests).
public protocol WatchHapticPlaying: AnyObject {
    func play(_ haptic: WatchHaptic)
}

/// The Watch's side: turns tap commands into haptics.
public final class WatchTapHandler {
    public struct Config: Sendable, Equatable {
        /// Seconds; a tap that arrives later than this after it was sent is
        /// dropped (2 s: past the 1.5 s heads-up lead, the cue is already up).
        public var maxDelay: TimeInterval = 2
        /// Seconds a tap may seem to come from the future (the clocks differ) and still play (5 s).
        public var maxAhead: TimeInterval = 5

        public init(maxDelay: TimeInterval = 2, maxAhead: TimeInterval = 5) {
            self.maxDelay = maxDelay
            self.maxAhead = maxAhead
        }
    }

    public let config: Config
    public let player: WatchHapticPlaying
    /// Taps played and taps dropped as late, for the Watch's status line and tests.
    public private(set) var played = 0
    public private(set) var droppedLate = 0

    public init(player: WatchHapticPlaying, config: Config = Config()) {
        self.player = player
        self.config = config
    }

    /// A command from the phone, sent at `sentAt`, arriving at `now` (both
    /// seconds since 1970). Returns the haptic played; nil for a workout
    /// command (not a tap) or a tap that came too late.
    @discardableResult
    public func handle(_ command: WatchCommand, sentAt: Double, now: Double) -> WatchHaptic? {
        guard let haptic = command.haptic else { return nil }
        let delay = now - sentAt
        guard delay <= config.maxDelay, delay >= -config.maxAhead else {
            droppedLate += 1
            return nil
        }
        played += 1
        player.play(haptic)
        return haptic
    }
}
