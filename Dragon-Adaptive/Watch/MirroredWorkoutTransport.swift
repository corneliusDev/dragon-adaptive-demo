//  MirroredWorkoutTransport.swift
//  The workout-mirroring route on the phone (iOS 17+): the Watch starts its
//  running workout and mirrors it to the phone (startMirroringToCompanionDevice);
//  HealthKit hands the phone the mirrored HKWorkoutSession through
//  workoutSessionMirroringStartHandler, launching the app in the background
//  if needed. Data the Watch sends with sendToRemoteWorkoutSession arrives in
//  the session delegate; the phone sends back the same way. This route keeps
//  going with the Watch screen off and the phone locked, which is why it's
//  the first choice.

import Foundation
import HealthKit

final class MirroredWorkoutTransport: NSObject, MirroredTransport, HKWorkoutSessionDelegate {
    var onReceive: ((Data, WatchRoute) -> Void)?
    var onChange: (() -> Void)?

    let store: HKHealthStore
    private(set) var session: HKWorkoutSession?

    init(store: HKHealthStore) {
        self.store = store
    }

    func activate() {
        store.workoutSessionMirroringStartHandler = { [weak self] session in
            DispatchQueue.main.async { self?.attach(session) }
        }
    }

    private func attach(_ session: HKWorkoutSession) {
        NSLog("[WatchLink] mirrored workout started")
        session.delegate = self
        self.session = session
        onChange?()
    }

    var isReachable: Bool {
        guard let session else { return false }
        return session.state == .running || session.state == .paused || session.state == .prepared
    }

    @discardableResult
    func send(_ data: Data) -> Bool {
        guard let session, isReachable else { return false }
        session.sendToRemoteWorkoutSession(data: data) { ok, error in
            if !ok { NSLog("[WatchLink] mirrored send failed: %@", error?.localizedDescription ?? "unknown") }
        }
        return true
    }

    // MARK: HKWorkoutSessionDelegate

    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState, date: Date) {
        DispatchQueue.main.async {
            if toState == .ended || toState == .stopped, self.session === workoutSession { self.session = nil }
            self.onChange?()
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        NSLog("[WatchLink] mirrored workout failed: %@", error.localizedDescription)
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        DispatchQueue.main.async {
            for d in data { self.onReceive?(d, .mirroring) }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?) {
        NSLog("[WatchLink] mirrored workout disconnected: %@", error?.localizedDescription ?? "no error")
        DispatchQueue.main.async {
            if self.session === workoutSession { self.session = nil }
            self.onChange?()
        }
    }
}
