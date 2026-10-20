//  DeviceHaptics.swift
//  The heads-up's Watch tap on the wrist: WatchTapHandler (DragonEngine,
//  unit-tested with a fake player) decides what to play; this plays it with
//  WKInterfaceDevice: a click for an advisory or info cue, the notification
//  buzz for a critical or safety one.

import WatchKit
import DragonEngine

final class DeviceHaptics: WatchHapticPlaying {
    func play(_ haptic: WatchHaptic) {
        WKInterfaceDevice.current().play(Self.type(for: haptic))
    }

    static func type(for haptic: WatchHaptic) -> WKHapticType {
        switch haptic {
        case .light: return .click
        case .strong: return .notification
        }
    }
}
