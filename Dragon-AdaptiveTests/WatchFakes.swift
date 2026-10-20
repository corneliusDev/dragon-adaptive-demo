//  WatchFakes.swift
//  Test stand-ins for the Watch link and Apple Health: a transport the test
//  delivers message bytes through (late, twice, out of order), a workout
//  control that records what it was asked, and a Health store with set answers.

import Foundation
import DragonEngine
@testable import Dragon_Adaptive

final class FakeWatchTransport: MirroredTransport {
    var onReceive: ((Data, WatchRoute) -> Void)?
    var onChange: (() -> Void)?
    var isReachable: Bool
    private(set) var sent: [Data] = []
    private(set) var activated = 0

    init(reachable: Bool = true) { isReachable = reachable }

    func activate() { activated += 1 }

    @discardableResult
    func send(_ data: Data) -> Bool {
        guard isReachable else { return false }
        sent.append(data)
        return true
    }

    /// Delivers bytes as if they'd just arrived from the Watch.
    func deliver(_ data: Data, route: WatchRoute = .connectivity) { onReceive?(data, route) }
    func deliver(_ m: WatchMessage, route: WatchRoute = .connectivity) { deliver(m.encoded(), route: route) }

    var sentMessages: [WatchMessage] { sent.compactMap { try? WatchMessage.decode($0) } }
}

final class FakeWatchControl: WatchWorkoutControlling {
    private(set) var starts = 0
    private(set) var ends = 0
    var answer = true

    func startWorkout(completion: @escaping (Bool) -> Void) {
        starts += 1
        completion(answer)
    }

    func endWorkout() { ends += 1 }
}

final class FakeHealthStore: HealthStoreProviding {
    var isAvailable = true
    var rates = HealthHeartRates()
    var watchAppStarts = true
    private(set) var authorizationRequests = 0
    private(set) var watchAppRequests = 0
    private(set) var lookBack: Int?

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        authorizationRequests += 1
        completion(true)
    }

    func heartRates(lookBackDays: Int, completion: @escaping (HealthHeartRates) -> Void) {
        lookBack = lookBackDays
        completion(rates)
    }

    func startWatchApp(completion: @escaping (Bool) -> Void) {
        watchAppRequests += 1
        completion(watchAppStarts)
    }
}

/// Builds Watch messages timed against a FakeClock's wall clock.
struct WatchMessageMaker {
    let clock: FakeClock
    var sequencer = WatchMessageSequencer(session: "watch-1")

    init(clock: FakeClock, session: String = "watch-1") {
        self.clock = clock
        sequencer = WatchMessageSequencer(session: session)
    }

    /// Wall-clock seconds since 1970 at a clock uptime.
    func wall(_ uptime: TimeInterval) -> Double { clock.date(uptime: uptime).timeIntervalSince1970 }

    mutating func hr(_ bpm: Double, uptime: TimeInterval) -> WatchMessage {
        sequencer.message(.heartRate(bpm: bpm, at: wall(uptime)), sentAt: wall(uptime))
    }

    mutating func effort(_ score: Double, uptime: TimeInterval) -> WatchMessage {
        sequencer.message(.effort(score: score, at: wall(uptime)), sentAt: wall(uptime))
    }

    mutating func state(_ s: WatchSessionState, uptime: TimeInterval) -> WatchMessage {
        sequencer.message(.state(s, at: wall(uptime)), sentAt: wall(uptime))
    }
}
