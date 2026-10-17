//  GestureAttentionSource.swift
//  PRODUCTION-READY TODAY: ActiveLook onboard gesture sensor as a gaze
//  stand-in. One wave = glance; two within dwellWindow = dwell.
//  Real signatures (verified against ios-sdk v4.5.5):
//    glasses.gesture(enabled: Bool)
//    glasses.subscribeToSensorInterfaceNotifications(onSensorInterfaceTriggered: () -> Void)

import Foundation
import ActiveLookSDK

final class GestureAttentionSource: AttentionSource {
    var onEvent: ((AttentionEvent) -> Void)?
    private weak var glasses: Glasses?
    private var lastFire = Date.distantPast
    private let dwellWindow: TimeInterval = 0.6
    private var idleTimer: Timer?

    init(glasses: Glasses) { self.glasses = glasses }

    func start() {
        glasses?.gesture(enabled: true)
        glasses?.subscribeToSensorInterfaceNotifications { [weak self] in
            self?.handleFire()
        }
    }

    func stop() { glasses?.gesture(enabled: false); idleTimer?.invalidate() }

    private func handleFire() {
        let now = Date()
        onEvent?(now.timeIntervalSince(lastFire) < dwellWindow ? .dwell : .glance)
        lastFire = now
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.onEvent?(.idle)
        }
    }
}

/// FUTURE drop-in. Wiring it is a one-line change in HUDController.
/// final class GazeAttentionSource: AttentionSource { /* feed gaze dwell */ }
