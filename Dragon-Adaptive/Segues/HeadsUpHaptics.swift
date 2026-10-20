//  HeadsUpHaptics.swift
//  The Watch-tap heads-up: when a heads-up starts and the HeadsUp setting
//  includes .watchTap, HUDController (and the segue preview) call
//  headsUp(_:) here. Delivery to the Watch arrives with chunk 12 (part B
//  wires a WatchConnectivity implementation in); until then the no-op one
//  stands in.

import Foundation
import DragonEngine

protocol HeadsUpHaptics: AnyObject {
    /// A predictable cue is coming: tap the runner's wrist now.
    func headsUp(_ signal: RunEngine.HeadsUpSignal)
}

/// Does nothing until the Watch link exists; counts calls for tests.
final class NoHeadsUpHaptics: HeadsUpHaptics {
    private(set) var count = 0

    func headsUp(_ signal: RunEngine.HeadsUpSignal) {
        count += 1
    }
}
