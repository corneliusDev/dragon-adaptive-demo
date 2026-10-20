//  PhoneLink.swift
//  The Watch's side of the link to the phone. Sends each encoded
//  WatchMessage by the best route up:
//
//      mirroring     the running workout, mirrored to the phone
//                    (sendToRemoteWorkoutSession); keeps flowing with the
//                    Watch screen off.
//      connectivity  WatchConnectivity sendMessageData while the phone is
//                    reachable (the fallback, and the only route for the
//                    debug synthetic heart rate, which has no workout).
//      queued        session states only (start / end matter later too):
//                    transferUserInfo, delivered when the phone app next runs.
//
//  Readings that can't go now are dropped: by the time they arrived the
//  phone would call them stale. Commands from the phone arrive by either
//  route and go to `onCommand` (after de-duplication by WatchMessageFilter
//  in WorkoutManager).

import Foundation
import HealthKit
import WatchConnectivity
import DragonEngine

final class PhoneLink: NSObject, WCSessionDelegate {
    enum Route: String {
        case mirroring, connectivity, queued, none
    }

    static let key = "m"

    /// Bytes of each message from the phone (main queue).
    var onReceive: ((Data) -> Void)?
    /// Reachability changed (main queue).
    var onChange: (() -> Void)?
    /// The mirrored workout to send through, while it runs.
    weak var mirrored: HKWorkoutSession?
    /// Mirroring to the phone was confirmed for `mirrored`.
    var isMirroring = false

    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    var isPhoneReachable: Bool {
        guard let session, session.activationState == .activated else { return false }
        return session.isReachable
    }

    var statusText: String {
        if isMirroring, mirrored != nil { return "Mirrored to iPhone" }
        if isPhoneReachable { return "iPhone reachable" }
        return "iPhone not reachable"
    }

    /// Sends `data`; `queueIfUnreachable` for messages that still matter later.
    @discardableResult
    func send(_ data: Data, queueIfUnreachable: Bool = false) -> Route {
        if isMirroring, let mirrored, mirrored.state == .running || mirrored.state == .paused {
            mirrored.sendToRemoteWorkoutSession(data: data) { ok, error in
                if !ok { NSLog("[PhoneLink] mirrored send failed: %@", error?.localizedDescription ?? "unknown") }
            }
            return .mirroring
        }
        guard let session, session.activationState == .activated else { return .none }
        if session.isReachable {
            session.sendMessageData(data, replyHandler: nil) { error in
                NSLog("[PhoneLink] send failed: %@", error.localizedDescription)
            }
            return .connectivity
        }
        if queueIfUnreachable {
            session.transferUserInfo([Self.key: data])
            return .queued
        }
        return .none
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if let error { NSLog("[PhoneLink] activation failed: %@", error.localizedDescription) }
        DispatchQueue.main.async { self.onChange?() }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.onChange?() }
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        DispatchQueue.main.async { self.onReceive?(messageData) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let data = message[Self.key] as? Data else { return }
        DispatchQueue.main.async { self.onReceive?(data) }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let data = userInfo[Self.key] as? Data else { return }
        DispatchQueue.main.async { self.onReceive?(data) }
    }
}
