//  TriggerSupportTests.swift
//  Chunk 9's supporting pieces: the arbiter taking a cue down for its
//  trigger, budgets that answer requests (and old logs without the field),
//  live cue text, the phase at the gun, and the synthetic pedometer.

import XCTest
@testable import DragonEngine

final class TriggerSupportTests: XCTestCase {
    private func cue(_ key: CueKey, _ priority: Priority, show: TimeInterval = 100) -> Cue {
        Cue(key: key, priority: priority, content: CueContent(main: .label("X")),
            createdAt: 0, expiresAt: 1_000, minShow: show)
    }

    func testWithdrawTakesTheCueDownWithoutACooldown() {
        var arbiter = Arbiter()
        _ = arbiter.decide([cue(.kickClock, .safety)], budget: .safetyOnly, at: 0)
        XCTAssertEqual(arbiter.showing?.key, .kickClock)
        arbiter.withdraw(.kickClock, at: 5)
        XCTAssertNil(arbiter.showing)
        let next = arbiter.decide([cue(.finish, .info, show: 10)], budget: .relaxed, at: 6)
        XCTAssertEqual(next.decisions.first, Decision(t: 5, key: .kickClock, priority: .safety, reason: .withdrawn))
        XCTAssertEqual(next.decisions.first?.outcome, .expired)
        XCTAssertEqual(next.showing?.key, .finish)
        // A waiting cue goes too; other keys stay.
        var queue = Arbiter()
        _ = queue.decide([cue(.paceGap, .critical), cue(.split(mile: 3), .advisory)], budget: .relaxed, at: 0)
        queue.withdraw(.split(mile: 3), at: 1)
        XCTAssertTrue(queue.waiting.isEmpty)
        XCTAssertEqual(queue.showing?.key, .paceGap)
    }

    func testBudgetsFromOlderLogsDecodeWithoutAnsweringRequests() throws {
        let old = #"{"maxElements":2,"minPriority":1,"allowInterrupt":true,"unreliable":[],"finalStretch":false}"#
        let b = try JSONDecoder().decode(Budget.self, from: Data(old.utf8))
        XCTAssertEqual(b, .steady)
        XCTAssertFalse(b.answersRequests)
        var answering = Budget.steady
        answering.answersRequests = true
        XCTAssertEqual(try JSONDecoder().decode(Budget.self, from: JSONEncoder().encode(answering)), answering)
    }

    func testLiveTextReadsFromWhereTheRunnerIs() {
        let now = CueFormat.Now(elapsed: 6_202, distance: 20_840)
        XCTAssertEqual(CueFormat.string(.timeLeft(until: 6_300), unit: .miles, now: now), "1:38")
        XCTAssertEqual(CueFormat.string(.distanceLeft(to: 21_097.5), unit: .miles, now: now), "0.16 MI")
        XCTAssertEqual(CueFormat.string(.distanceLeft(to: 21_097.5), unit: .kilometers, now: now), "0.26 KM")
        XCTAssertEqual(CueFormat.string(.timeLeft(until: 6_300)), "--", "no state, no countdown")
        XCTAssertEqual(CueFormat.string(.perUnit(5, .kilometers)), "5 SEC/KM")
        // The renderer draws them from the state it is given.
        let clock = Cue(key: .kickClock, priority: .safety,
                        content: CueContent(heading: .label("TO BEAT"), main: .timeLeft(until: 6_300)),
                        createdAt: 0, expiresAt: 9_999, minShow: 9_999)
        let frame = Renderer.frame(for: clock, budget: .safetyOnly, state: RunState(elapsed: 6_250, distance: 21_000),
                                   unit: .miles)
        XCTAssertTrue(frame.ops.contains { if case .text(_, _, _, _, _, "0:50") = $0 { return true }; return false })
    }

    func testAtTheGunNothingSaysTheRunnerIsMoving() {
        let classifier = MovementPhaseClassifier()
        XCTAssertEqual(classifier.phase(at: 0, speeds: [MovementSample(t: 0, distance: 0, speed: nil)], efforts: [],
                                        grade: nil, distance: 0, total: 21_097.5), .stopped)
        // Once there is motion, it isn't.
        let moving = (1...10).map { EffortSample(t: Double($0) / 10, value: 80) }
        XCTAssertEqual(classifier.phase(at: 1, speeds: [MovementSample(t: 0, distance: 0, speed: nil)], efforts: moving,
                                        grade: nil, distance: 3, total: 21_097.5), .steady)
    }

    func testSyntheticRunSendsPedometerCadenceOnceASecondThatFadesWithForm() {
        let mile = DistanceUnit.metersPerMile
        let recording = SyntheticRun.record(.slowFade(from: 9 * mile), seed: 42)
        let cadence = recording.vitals.filter { $0.cadence != nil }
        XCTAssertTrue(cadence.allSatisfy { $0.source == .phone && $0.heartRate == nil && $0.motion == nil })
        XCTAssertEqual(Double(cadence.count), recording.duration, accuracy: 2)
        let early = cadence.filter { $0.timestamp > 600 && $0.timestamp < 3_000 }.compactMap(\.cadence)
        let late = cadence.filter { $0.timestamp > 5_500 }.compactMap(\.cadence)
        let mean = { (xs: [Double]) in xs.reduce(0, +) / Double(xs.count) }
        XCTAssertEqual(mean(early), 172, accuracy: 1)
        XCTAssertLessThan(mean(late), mean(early) * 0.93)
        // On plan, it holds.
        let steady = SyntheticRun.record(.onPlan, seed: 42).vitals.compactMap(\.cadence)
        XCTAssertEqual(mean(steady), 172, accuracy: 1)
    }

    func testWalkthroughSendsItsGlancesAndHeldLook() {
        let recording = SyntheticRun.record(.designWalkthrough, seed: 42)
        XCTAssertEqual(recording.attention.map(\.event), [.glance, .glance, .dwell])
        XCTAssertEqual(recording.attention.first?.t, 0)
    }
}
