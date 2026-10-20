//  WatchConnectivityTransport.swift
//  The WatchConnectivity route on the phone: WCSession message data while
//  the Watch app is reachable. Messages that can't be sent now are not
//  queued (a heart rate a minute late is worse than none: it would be
//  dropped as stale anyway); an end command also goes by transferUserInfo,
//  which is delivered whenever the Watch app next runs.

import Foundation
import WatchConnectivity
import DragonEngine

final class WatchConnectivityTransport: NSObject, WatchTransport, WCSessionDelegate {
    var onReceive: ((Data, WatchRoute) -> Void)?
    /// Reachability or pairing changed (main queue).
    var onChange: (() -> Void)?
    /// Key of a message's bytes in a userInfo / message dictionary.
    static let key = "m"

    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    var isReachable: Bool {
        guard let session, session.activationState == .activated else { return false }
        return session.isReachable
    }

    /// A Watch is paired and has the Dragon app (it can be opened for a run).
    var isPairedWithApp: Bool {
        guard let session, session.activationState == .activated else { return false }
        return session.isPaired && session.isWatchAppInstalled
    }

    @discardableResult
    func send(_ data: Data) -> Bool {
        guard let session, session.activationState == .activated else { return false }
        if let m = try? WatchMessage.decode(data), case .command(.endWorkout) = m.body, session.isWatchAppInstalled {
            session.transferUserInfo([Self.key: data])
        }
        guard session.isReachable else { return false }
        session.sendMessageData(data, replyHandler: nil) { error in
            NSLog("[WatchLink] WatchConnectivity send failed: %@", error.localizedDescription)
        }
        return true
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if let error { NSLog("[WatchLink] WatchConnectivity activation failed: %@", error.localizedDescription) }
        DispatchQueue.main.async { self.onChange?() }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.onChange?() }
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.onChange?() }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // A different Watch was paired: activate for it.
        session.activate()
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        DispatchQueue.main.async { self.onReceive?(messageData, .connectivity) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let data = message[Self.key] as? Data else { return }
        DispatchQueue.main.async { self.onReceive?(data, .connectivity) }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let data = userInfo[Self.key] as? Data else { return }
        DispatchQueue.main.async { self.onReceive?(data, .connectivity) }
    }
}
