//  WatchMessageFilterTests.swift
//  What the phone does with Watch messages that arrive twice, late, out of
//  order or stale, and how a gap in the Watch link reaches the engine: as
//  missing heart rate, never filled in by a late burst.

import XCTest
@testable import DragonEngine

final class WatchMessageFilterTests: XCTestCase {
    /// Wall clock of run time 0 in these tests.
    private let start = 1_760_870_000.0
    private var sequencer = WatchMessageSequencer(session: "W1")

    private func hr(_ bpm: Double, at t: TimeInterval) -> WatchMessage {
        sequencer.message(.heartRate(bpm: bpm, at: start + t), sentAt: start + t)
    }

    private func effort(_ score: Double, at t: TimeInterval) -> WatchMessage {
        sequencer.message(.effort(score: score, at: start + t), sentAt: start + t)
    }

    /// Delivers `m` at phone run time `now`.
    private func deliver(_ m: WatchMessage, to f: inout WatchMessageFilter, now: TimeInterval) -> WatchMessageFilter.Outcome {
        f.accept(m, sampleTime: m.at - start, now: now)
    }

    func testFreshReadingsBecomeWatchSamplesAtTheirRunTime() {
        var f = WatchMessageFilter()
        XCTAssertEqual(deliver(hr(150, at: 10), to: &f, now: 10.4),
                       .sample(VitalsSample(timestamp: 10, heartRate: 150, motion: nil, source: .watch)))
        XCTAssertEqual(deliver(effort(44, at: 10), to: &f, now: 10.4),
                       .sample(VitalsSample(timestamp: 10, heartRate: nil, motion: 44, source: .watch)))
        XCTAssertEqual(f.counts.applied, 2)
    }

    func testDuplicatesAreDroppedBySequence() {
        var f = WatchMessageFilter()
        let m = hr(150, at: 10)
        guard case .sample = deliver(m, to: &f, now: 10.5) else { return XCTFail() }
        // The same message again (e.g. by the other route) a moment later.
        XCTAssertEqual(deliver(m, to: &f, now: 10.7), .dropped(.duplicate))
        XCTAssertEqual(f.counts.dropped(.duplicate), 1)
        // Same sequence number from a different Watch session is a different message.
        let other = WatchMessage(session: "W2", sequence: m.sequence, sentAt: start + 11, body: .heartRate(bpm: 151, at: start + 11))
        guard case .sample = deliver(other, to: &f, now: 11.2) else { return XCTFail("new session") }
    }

    func testOlderThanLastAppliedIsDroppedPerStream() {
        var f = WatchMessageFilter()
        let early = hr(148, at: 10)
        let late = hr(150, at: 11)
        guard case .sample = deliver(late, to: &f, now: 11.3) else { return XCTFail() }
        XCTAssertEqual(deliver(early, to: &f, now: 11.4), .dropped(.outOfOrder))
        // Each stream keeps its own order: an effort reading from t=10 still applies.
        guard case .sample = deliver(effort(40, at: 10), to: &f, now: 11.5) else { return XCTFail("effort stream") }
        XCTAssertEqual(f.lastApplied[.heartRate], 11)
        XCTAssertEqual(f.lastApplied[.effort], 10)
        // Same time as the last applied is not newer.
        XCTAssertEqual(deliver(hr(150, at: 11), to: &f, now: 11.6), .dropped(.outOfOrder))
    }

    func testDelayedButFreshIsAppliedAndStaleIsDropped() {
        var f = WatchMessageFilter()
        // 3 s late: still inside the 5 s heart-rate allowance.
        guard case .sample(let s) = deliver(hr(150, at: 20), to: &f, now: 23) else { return XCTFail() }
        XCTAssertEqual(s.timestamp, 20)
        // 8 s late: the engine would call it missing; dropped.
        XCTAssertEqual(deliver(hr(152, at: 22), to: &f, now: 30), .dropped(.stale))
        XCTAssertEqual(f.counts.dropped(.stale), 1)
        XCTAssertEqual(f.config.maxAge, SourceSelection.heartRateStaleAfter)
    }

    func testBeforeTheRunAndFarFutureAreDropped() {
        var f = WatchMessageFilter()
        XCTAssertEqual(deliver(hr(120, at: -2), to: &f, now: 0.5), .dropped(.beforeRun))
        XCTAssertEqual(deliver(hr(120, at: 40), to: &f, now: 5), .dropped(.future))
        // A little ahead (clocks a second apart) is fine.
        guard case .sample = deliver(hr(121, at: 6), to: &f, now: 5) else { return XCTFail() }
    }

    func testStateAndCommandsPassThrough() {
        var f = WatchMessageFilter()
        let state = sequencer.message(.state(.running, at: start + 1), sentAt: start + 1)
        XCTAssertEqual(deliver(state, to: &f, now: 1.2), .state(.running, t: 1))
        let end = sequencer.message(.command(.endWorkout), sentAt: start + 2)
        XCTAssertEqual(f.accept(end, sampleTime: 2, now: 2.1), .command(.endWorkout))
        XCTAssertEqual(f.accept(end, sampleTime: 2, now: 2.2), .dropped(.duplicate))
    }

    func testShuffledDuplicatedDelayedStreamAppliesEachReadingOnceInOrder() {
        // 60 s of 1 Hz heart rate, each sent twice (both routes), delivered
        // with random delays of up to 4 s, so out of order.
        var rng = SeededRNG(seed: 5)
        var arrivals: [(arrive: Double, m: WatchMessage)] = []
        for i in 0..<60 {
            let m = hr(140 + Double(i % 7), at: Double(i))
            arrivals.append((Double(i) + rng.uniform(0.1...4), m))
            arrivals.append((Double(i) + rng.uniform(0.1...4), m))
        }
        arrivals.sort { $0.arrive < $1.arrive }
        var f = WatchMessageFilter()
        var applied: [TimeInterval] = []
        for a in arrivals {
            if case .sample(let s) = deliver(a.m, to: &f, now: a.arrive) { applied.append(s.timestamp) }
        }
        XCTAssertEqual(applied, applied.sorted(), "applied in time order")
        XCTAssertEqual(Set(applied).count, applied.count, "no reading twice")
        XCTAssertEqual(f.counts.dropped(.duplicate) + f.counts.dropped(.outOfOrder) + applied.count, 120)
        XCTAssertGreaterThan(f.counts.dropped(.duplicate), 0)
        XCTAssertGreaterThan(applied.count, 30, "most readings make it")
    }

    func testABluetoothGapIsMissingHeartRateAndALateBurstDoesNotFillIt() {
        // HR every second; the Watch goes out of range from 30 s to 60 s and,
        // back in range, delivers the queued readings in a burst at 61 s.
        let plan = RunPlan(distanceMeters: 5_000, targetTime: 1_500)
        var estimator = StateEstimator(plan: plan)
        var f = WatchMessageFilter()
        var missingAt: [Int] = []
        var queued: [WatchMessage] = []
        for second in 0...90 {
            let t = Double(second)
            let m = hr(150, at: t)
            if (30..<60).contains(second) {
                queued.append(m)
            } else {
                if second == 61 {
                    for q in queued {
                        if case .sample(let s) = deliver(q, to: &f, now: t) { estimator.ingest(.vitals(s)) }
                    }
                }
                if case .sample(let s) = deliver(m, to: &f, now: t + 0.5) { estimator.ingest(.vitals(s)) }
            }
            let state = estimator.state(at: t + 0.5)
            if state.heartRate == nil { missingAt.append(second) }
        }
        // The last reading before the gap is at 29 s; state is read half a
        // second into each second, so it's missing from 34.5 s (5.5 s old)
        // until the first fresh reading back at 60 s.
        XCTAssertEqual(missingAt.first, 34)
        XCTAssertEqual(missingAt.last, 59)
        XCTAssertEqual(missingAt.count, 26)
        XCTAssertGreaterThan(f.counts.dropped(.stale) + f.counts.dropped(.outOfOrder), 20)
    }
}
