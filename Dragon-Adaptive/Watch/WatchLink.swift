//  WatchLink.swift
//  The phone's one connection to the Dragon Watch app, made at launch: the
//  workout-mirroring route and the WatchConnectivity route merged into one
//  WatchTransport (what WatchVitalsSource listens to), plus starting and
//  ending the Watch workout (WatchWorkoutControlling).
//
//      receive  both routes; every message is logged (NSLog "[WatchLink]")
//               and kept in `receipts` for the Developer menu, then handed
//               on. Duplicates across routes are WatchMessageFilter's job.
//      send     mirroring when the mirrored workout is up, else
//               WatchConnectivity when the Watch app is reachable.
//      start    HKHealthStore.startWatchApp(with:) (asks Health first);
//               if that fails, a startWorkout command over WatchConnectivity.
//      end      an endWorkout command by every route that's up.

import Foundation
import Observation
import DragonEngine

@Observable
final class WatchLink: WatchTransport, WatchWorkoutControlling {
    /// One message as it arrived, for the Developer menu.
    struct Receipt: Identifiable, Equatable {
        let id: Int
        let at: Date
        let route: WatchRoute
        /// "hr 152 · seq 41" or "rejected: unsupportedVersion(2)".
        let text: String
    }

    static let shared = WatchLink(connectivity: WatchConnectivityTransport(),
                                  mirroring: MirroredWorkoutTransport(store: SystemHealthStore.shared.store),
                                  health: SystemHealthStore.shared)

    @ObservationIgnored var onReceive: ((Data, WatchRoute) -> Void)?
    /// Newest first; at most `maxReceipts`.
    private(set) var receipts: [Receipt] = []
    private(set) var received = 0
    /// Last thing the link did, in words ("Start sent to the Watch").
    private(set) var lastEvent: String?

    @ObservationIgnored let connectivity: WatchTransport
    @ObservationIgnored let mirroring: MirroredTransport
    @ObservationIgnored let health: HealthStoreProviding
    @ObservationIgnored private var sequencer = WatchMessageSequencer(session: "phone-" + UUID().uuidString.prefix(8))
    @ObservationIgnored private let maxReceipts = 30
    /// Pinged when either route's reachability may have changed (redraws the menu).
    private(set) var tick = 0

    init(connectivity: WatchTransport, mirroring: MirroredTransport, health: HealthStoreProviding) {
        self.connectivity = connectivity
        self.mirroring = mirroring
        self.health = health
        connectivity.onReceive = { [weak self] data, route in self?.arrived(data, route: route) }
        mirroring.onReceive = { [weak self] data, route in self?.arrived(data, route: route) }
        mirroring.onChange = { [weak self] in self?.tick += 1 }
    }

    /// Sets up both routes. Called once at launch: the mirroring handler has
    /// to be in place before the Watch starts mirroring.
    func activate() {
        (connectivity as? WatchConnectivityTransport)?.activate()
        (connectivity as? WatchConnectivityTransport)?.onChange = { [weak self] in self?.tick += 1 }
        mirroring.activate()
    }

    var isReachable: Bool { mirroring.isReachable || connectivity.isReachable }
    var isMirroring: Bool { mirroring.isReachable }
    var isConnectivityReachable: Bool { connectivity.isReachable }

    /// "Mirrored workout" / "Watch app reachable" / "Watch not reachable".
    var statusText: String {
        _ = tick
        if mirroring.isReachable { return "Mirrored workout" }
        if connectivity.isReachable { return "Watch app reachable" }
        return "Watch not reachable"
    }

    @discardableResult
    func send(_ data: Data) -> Bool {
        if mirroring.isReachable, mirroring.send(data) { return true }
        return connectivity.send(data)
    }

    func send(_ command: WatchCommand) -> Bool {
        let data = sequencer.message(.command(command), sentAt: Date().timeIntervalSince1970).encoded()
        return send(data)
    }

    func startWorkout(completion: @escaping (Bool) -> Void) {
        health.requestAuthorization { [weak self] _ in
            guard let self else { return completion(false) }
            self.health.startWatchApp { ok in
                if ok {
                    self.lastEvent = "Watch workout requested through Health"
                    return completion(true)
                }
                let sent = self.send(.startWorkout)
                self.lastEvent = sent ? "Start sent to the Watch app" : "Couldn't reach the Watch"
                completion(sent)
            }
        }
    }

    func endWorkout() {
        let data = sequencer.message(.command(.endWorkout), sentAt: Date().timeIntervalSince1970).encoded()
        // Both routes: the end must get there; the Watch drops the second copy.
        let mirrored = mirroring.isReachable && mirroring.send(data)
        let direct = connectivity.send(data)
        lastEvent = mirrored || direct ? "End sent to the Watch" : "Couldn't reach the Watch to end its workout"
    }

    private func arrived(_ data: Data, route: WatchRoute) {
        received += 1
        let text: String
        do {
            text = WatchLink.describe(try WatchMessage.decode(data))
        } catch {
            text = "rejected: \(error)"
        }
        NSLog("[WatchLink] received %@ via %@", text, route.rawValue)
        receipts.insert(Receipt(id: received, at: Date(), route: route, text: text), at: 0)
        if receipts.count > maxReceipts { receipts.removeLast(receipts.count - maxReceipts) }
        onReceive?(data, route)
    }

    static func describe(_ m: WatchMessage) -> String {
        let body: String
        switch m.body {
        case .heartRate(let bpm, _): body = "hr \(Int(bpm.rounded()))"
        case .effort(let score, _): body = "effort \(Int(score.rounded()))"
        case .state(let s, _): body = "state \(s.rawValue)"
        case .command(let c): body = "command \(c.rawValue)"
        }
        return "\(body) · seq \(m.sequence)"
    }
}
