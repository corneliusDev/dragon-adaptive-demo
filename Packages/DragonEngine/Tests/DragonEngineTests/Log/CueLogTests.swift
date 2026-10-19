//  CueLogTests.swift
//  Chunk 8 acceptance: the cue log. Every arbiter decision is in it (held
//  back and expired too), attention is matched to the cue on screen, the
//  pace-gap cue's outcome is read a minute later, a log saves and loads with
//  no loss, and a two-hour run's log stays small.

import XCTest
import DragonEngine

/// A synthetic race through RunEngine with its cue log, keeping every decision
/// the arbiter made and the cue it was about.
private struct LoggedRace {
    var engine: RunEngine
    var run: SyntheticRun
    var decisions: [(decision: Decision, cue: Cue)] = []
    /// Run time each cue first went on screen, by key (first time only).
    var firstShown: [CueKey: TimeInterval] = [:]
}

private func logRace(_ profile: SyntheticProfile, seed: UInt64 = 42, plan: RunPlan? = nil,
                     updatesPerSecond: Double = 1, until limit: TimeInterval = .infinity,
                     attention: [AttentionSample] = [], dismissAt: [TimeInterval] = []) -> LoggedRace {
    var run = SyntheticRun(profile: profile, seed: seed, plan: plan)
    var config = RunEngine.Config()
    config.name = "\(profile.name) seed \(seed)"
    var race = LoggedRace(engine: RunEngine(plan: run.plan, config: config), run: run)
    var attention = attention.sorted { $0.t < $1.t }
    var dismissAt = dismissAt.sorted()
    let dt = 1 / updatesPerSecond
    while !run.isFinished && run.time < limit {
        for event in run.advance(by: dt) { race.engine.ingest(event) }
        while let a = attention.first, a.t <= run.time {
            race.engine.ingest(.attention(a))
            attention.removeFirst()
        }
        while let d = dismissAt.first, d <= run.time {
            race.engine.dismiss(at: d)
            dismissAt.removeFirst()
        }
        let step = race.engine.update(at: run.time)
        race.decisions += zip(step.decisions, race.engine.arbiter.decided).map { ($0, $1) }
        if let c = step.current, race.firstShown[c.key] == nil { race.firstShown[c.key] = run.time }
    }
    if let finish = run.finishTime { race.engine.finish(at: finish) }
    race.run = run
    return race
}

final class CueLogTests: XCTestCase {
    private let mile = DistanceUnit.metersPerMile

    // MARK: Every decision

    /// Groups decisions by the cue they were about and their reason: count, first and last run time.
    private func grouped(_ items: [(key: CueKey, createdAt: TimeInterval, reason: Decision.Reason,
                                    priority: Priority, t: TimeInterval, through: TimeInterval, count: Int)])
        -> [String: (count: Int, first: TimeInterval, last: TimeInterval)] {
        var out: [String: (count: Int, first: TimeInterval, last: TimeInterval)] = [:]
        for i in items {
            let k = "\(i.key) @\(i.createdAt) \(i.priority) \(i.reason)"
            let g = out[k] ?? (0, .infinity, -.infinity)
            out[k] = (g.count + i.count, min(g.first, i.t), max(g.last, i.through))
        }
        return out
    }

    private func assertEveryDecisionLogged(_ race: LoggedRace, file: StaticString = #filePath, line: UInt = #line) {
        let log = race.engine.log
        XCTAssertEqual(log.decisionCount, race.decisions.count, file: file, line: line)
        let made = grouped(race.decisions.map {
            ($0.decision.key, $0.cue.createdAt, $0.decision.reason, $0.decision.priority, $0.decision.t, $0.decision.t, 1)
        })
        let logged = grouped(log.events.map {
            ($0.cue.key, $0.cue.createdAt, $0.reason, $0.cue.priority, $0.t, $0.through, $0.count)
        })
        XCTAssertEqual(Set(made.keys), Set(logged.keys), file: file, line: line)
        for (k, m) in made {
            guard let l = logged[k] else { continue }
            XCTAssertEqual(l.count, m.count, k, file: file, line: line)
            XCTAssertEqual(l.first, m.first, k, file: file, line: line)
            XCTAssertEqual(l.last, m.last, k, file: file, line: line)
        }
        // Each event's outcome is its reason's, and its cue's kind is its key's.
        for e in log.events {
            XCTAssertEqual(e.decision, e.reason.outcome, file: file, line: line)
            XCTAssertEqual(e.cue.kind, e.cue.key.kind, file: file, line: line)
        }
    }

    func testEveryArbiterDecisionOfAFullRaceIsInTheLogIncludingHeldBackAndExpired() {
        // Hilly: splits deferred to the crest (held back), the final stretch drops cues (expired).
        let race = logRace(.hilly)
        assertEveryDecisionLogged(race)
        let outcomes = Set(race.decisions.map(\.decision.outcome))
        XCTAssertEqual(outcomes, [.shown, .heldBack, .expired])
        let log = race.engine.log
        XCTAssertTrue(log.events.contains { if case .deferred = $0.reason { return true } else { return false } })
        XCTAssertTrue(log.events.contains { $0.decision == .expired && $0.reason != .finished })
        // One appearance per cue that went on screen.
        let shownKeys = Set(race.decisions.filter { $0.decision.outcome == .shown }.map { "\($0.cue.key)@\($0.cue.createdAt)" })
        XCTAssertEqual(log.appearances.count, shownKeys.count)
    }

    func testEveryDecisionIsLoggedWithAPaceGapCueAndADismissal() {
        // slowFade: the pace gap shows over splits; the runner dismisses it a second in.
        let probe = logRace(.slowFade(from: 9 * mile))
        guard let shown = probe.firstShown[.paceGap] else { return XCTFail("no pace gap shown") }
        let race = logRace(.slowFade(from: 9 * mile), dismissAt: [shown + 1])
        assertEveryDecisionLogged(race)
        XCTAssertTrue(race.decisions.contains { $0.decision.reason == .dismissed })
        let gap = race.engine.log.appearances.first { $0.cue.key == .paceGap }
        XCTAssertEqual(gap?.response, .dismissed)
        XCTAssertTrue(race.engine.log.events.contains { $0.cue.key == .paceGap && $0.reason == .dismissed })
    }

    func testRepeatedDecisionsAreOneEventSoTheLogDoesNotGrowWithTheUpdateRate() {
        // The app updates 20 times a second; the log should look the same as at 1 Hz.
        let slow = logRace(.onPlan, until: 1_200)
        let fast = logRace(.onPlan, updatesPerSecond: 20, until: 1_200)
        assertEveryDecisionLogged(fast)
        XCTAssertGreaterThan(fast.decisions.count, 10 * slow.decisions.count)
        XCTAssertEqual(fast.engine.log.appearances.map(\.cue.key), slow.engine.log.appearances.map(\.cue.key))
        XCTAssertLessThanOrEqual(fast.engine.log.events.count, slow.engine.log.events.count + 4)
    }

    // MARK: Outcomes

    func testSlowFadePaceGapOutcomeShowsTheGapGrowing() {
        let race = logRace(.slowFade(from: 9 * mile))
        let gaps = race.engine.log.appearances.filter { $0.cue.kind == .paceGap }
        XCTAssertEqual(gaps.count, 1)
        guard let o = gaps.first?.outcome, let before = o.atShow, let after = o.after, let delta = o.delta else {
            return XCTFail("no outcome read for the pace-gap cue")
        }
        XCTAssertEqual(o.measure, .gap)
        XCTAssertEqual(o.shownAt, gaps[0].t)
        XCTAssertEqual(o.at - o.shownAt, 60, accuracy: 1)
        XCTAssertGreaterThan(before, 15)
        XCTAssertGreaterThan(after, before)
        XCTAssertEqual(delta, after - before, accuracy: 1e-9)
        XCTAssertEqual(o.improved, false)
        // Splits have no outcome.
        XCTAssertTrue(race.engine.log.appearances.filter { $0.cue.kind == .split }.allSatisfy { $0.outcome == nil })
    }

    func testSlowFadeRecoveryPaceGapOutcomeShowsTheGapShrinking() {
        // The recovery starts at mile 9.4, as the pace-gap cue goes up (about mile 9.42),
        // the earliest it can start with the cue still firing.
        // KNOWN FAILING (chunk 8, awaiting a decision): here the projected-finish
        // gap 60 s after the cue is larger than at show (≈18 s → ≈29 s). The
        // estimator's projection follows a 5-minute pace trend, so it only turns
        // down ~90–120 s after the runner speeds up. When the recovery starts at
        // or after the cue appears (the realistic case, incl. recoverAt = 10 mi)
        // the gap always grows over 60 s. It shrinks only in narrow windows where
        // the recovery starts shortly before the cue, on particular seeds (e.g.
        // from 9 mi, recoverAt 9.27–9.28 mi, seed 7; from 8 mi, 8.26–8.28 mi,
        // seed 7; from 6 mi, 6.31–6.32 mi, seed 42; from 8 mi, 8.35 mi, seed 42).
        // Moving recoverAt by ~0.01–0.02 mi or changing the seed undoes it.
        // Picking such a window would tune the scenario to the estimator's lag,
        // so the scenario is left realistic. The options (tuned scenario, a
        // faster-reacting measure, a longer delay, a faster projection) each
        // change a spec value or committed behaviour and are left to a human.
        let race = logRace(.slowFadeRecovery(from: 9 * mile, recoverAt: 9.4 * mile))
        let gaps = race.engine.log.appearances.filter { $0.cue.kind == .paceGap }
        XCTAssertEqual(gaps.count, 1)
        guard let o = gaps.first?.outcome, let before = o.atShow, let after = o.after else {
            return XCTFail("no outcome read for the pace-gap cue")
        }
        XCTAssertEqual(o.at - o.shownAt, 60, accuracy: 1)
        XCTAssertLessThan(after, before, "gap at show \(before), 60 s later \(after)")
        XCTAssertEqual(o.improved, true)
    }

    func testOutcomeArithmetic() {
        let gap = CueOutcome(measure: .gap, shownAt: 10, at: 70, atShow: 20, after: 12)
        XCTAssertEqual(gap.delta, -8)
        XCTAssertEqual(gap.improved, true)
        // Ahead of target: closer to zero is better, so going further ahead isn't.
        XCTAssertEqual(CueOutcome(measure: .gap, shownAt: 0, at: 60, atShow: -20, after: -30).improved, false)
        XCTAssertEqual(CueOutcome(measure: .heartRate, shownAt: 0, at: 60, atShow: 176, after: 171).improved, true)
        XCTAssertEqual(CueOutcome(measure: .heartRate, shownAt: 0, at: 60, atShow: 170, after: 174).delta, 4)
        XCTAssertNil(CueOutcome(measure: .gap, shownAt: 0, at: 60, atShow: 5, after: nil).improved)
    }

    // MARK: Responses

    func testAGlanceTwoSecondsAfterACueAppearsIsItsResponseAndFiveSecondsAfterIsNot() {
        let probe = logRace(.onPlan, until: 600)
        guard let t0 = probe.firstShown[.split(mile: 1)] else { return XCTFail("no mile 1 split") }

        let glanced = logRace(.onPlan, until: 600, attention: [AttentionSample(t: t0 + 2, event: .glance)])
        let split = glanced.engine.log.appearances.first { $0.cue.key == .split(mile: 1) }
        XCTAssertEqual(split?.t, t0)
        XCTAssertEqual(split?.response, .glanced)

        let late = logRace(.onPlan, until: 600, attention: [AttentionSample(t: t0 + 5, event: .glance)])
        let lateSplit = late.engine.log.appearances.first { $0.cue.key == .split(mile: 1) }
        XCTAssertEqual(lateSplit?.t, t0)
        XCTAssertEqual(lateSplit?.response, .ignored)
    }

    func testAGlanceStillOnScreenButOutsideTheWindowIsNotAResponse() {
        // The pace-gap cue stays up 5 s; a glance 4 s in is after the 3 s window.
        let probe = logRace(.slowFade(from: 9 * mile))
        guard let t0 = probe.firstShown[.paceGap] else { return XCTFail("no pace gap shown") }
        let race = logRace(.slowFade(from: 9 * mile), until: t0 + 30,
                           attention: [AttentionSample(t: t0 + 4, event: .glance)])
        XCTAssertEqual(race.engine.log.appearances.first { $0.cue.key == .paceGap }?.response, .ignored)

        let held = logRace(.slowFade(from: 9 * mile), until: t0 + 30,
                           attention: [AttentionSample(t: t0 + 1, event: .glance), AttentionSample(t: t0 + 2.5, event: .dwell)])
        XCTAssertEqual(held.engine.log.appearances.first { $0.cue.key == .paceGap }?.response, .heldLook)
    }

    func testLoggerMatchesAttentionAndMergesRepeatsOnHandMadeDecisions() {
        var logger = CueLogger(header: CueLog.Header(targetTime: 600, distance: 2_000))
        let split = Cue(key: .split(mile: 1), priority: .advisory, content: CueContent(main: .duration(480)),
                        createdAt: 0, expiresAt: 20, minShow: 3)
        let gap = Cue(key: .paceGap, priority: .critical, content: CueContent(main: .gap(18)),
                      createdAt: 0, expiresAt: 30, minShow: 5)
        let state = RunState(elapsed: 0, distance: 100, gapToTarget: 18, heartRate: 160.4)
        func step(_ t: TimeInterval, _ items: [(Cue, Decision.Reason)], gap g: Double = 18) {
            var s = state
            s.elapsed = t
            s.gapToTarget = g
            logger.record(items.map { Decision(t: t, key: $0.0.key, priority: $0.0.priority, reason: $0.1) },
                          cues: items.map(\.0), state: s, budget: .steady, situation: .raceEffort, at: t)
        }
        step(0, [(gap, .won), (split, .outranked(by: .paceGap))])
        logger.note(AttentionSample(t: 0.5, event: .glance))
        step(1, [(gap, .onScreen(until: 5)), (split, .screenBusy(by: .paceGap))])
        step(2, [(gap, .onScreen(until: 5)), (split, .screenBusy(by: .paceGap))])
        step(5, [(gap, .finished), (split, .won)])
        step(8, [(split, .finished)])
        step(60, [], gap: 11)

        let log = logger.log
        XCTAssertEqual(log.decisionCount, 9)
        XCTAssertEqual(log.events.map(\.count), [1, 1, 2, 2, 1, 1, 1])
        XCTAssertEqual(log.events[2].t, 1)
        XCTAssertEqual(log.events[2].through, 2)
        XCTAssertEqual(log.appearances.map(\.cue.key), [.paceGap, .split(mile: 1)])
        XCTAssertEqual(log.appearances.map(\.response), [.glanced, .ignored])
        XCTAssertEqual(log.events[0].state.heartRate, 160)
        XCTAssertEqual(log.events[0].state.situation, .raceEffort)
        let o = log.appearances[0].outcome
        XCTAssertEqual(o?.atShow, 18)
        XCTAssertEqual(o?.after, 11)
        XCTAssertEqual(o?.improved, true)
        XCTAssertNil(log.appearances[1].outcome)
        XCTAssertEqual(Set(log.events.map(\.cue.id)).count, 2)
    }

    // MARK: Summary

    func testSummaryCountsCuesByKindAndTheFinishAgainstTarget() {
        let race = logRace(.hilly)
        var log = race.engine.log
        let s = log.summary
        let splits = s.counts(.split)
        // 13 mile splits proposed: each one shown, or expired without showing.
        XCTAssertEqual(splits.shown + splits.expired, 13)
        XCTAssertGreaterThanOrEqual(splits.heldBack, 3, "the three splits on climbs wait for the crest")
        XCTAssertEqual(s.total.shown, log.appearances.count)
        XCTAssertEqual(s.decisions.values.reduce(0, +), race.decisions.count)
        XCTAssertEqual(s.responses.values.reduce(0, +) + s.pendingResponses, log.appearances.count)
        XCTAssertEqual(s.finishTime, race.run.finishTime)
        XCTAssertEqual(s.finishVsTarget!, race.run.finishTime! - race.run.plan.targetTime, accuracy: 1e-9)

        // Ratings after the race land on the cue's appearance.
        let id = log.appearances[0].cue.id
        XCTAssertTrue(log.rate(cue: id, .justRight))
        XCTAssertEqual(log.appearances[0].rating, .justRight)
        XCTAssertFalse(log.rate(cue: 10_000, .tooMuch))
    }

    // MARK: Storage

    func testSavedAndLoadedLogIsIdentical() throws {
        let probe = logRace(.slowFade(from: 9 * mile))
        let t0 = probe.firstShown[.paceGap] ?? 0
        var log = logRace(.slowFade(from: 9 * mile), attention: [AttentionSample(t: t0 + 1, event: .dwell)]).engine.log
        log.rate(cue: log.appearances[0].cue.id, .tooMuch)
        log.rate(cue: log.appearances.last!.cue.id, .tooLittle)

        let data = try log.jsonLines()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cues-\(UUID()).jsonl")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try CueLog(jsonLines: Data(contentsOf: url))
        XCTAssertEqual(loaded, log)
        XCTAssertEqual(try loaded.jsonLines(), data)
        XCTAssertEqual(loaded.summary, log.summary)
        // One header line, then one line per event.
        XCTAssertEqual(data.split(separator: 0x0A).count, log.events.count + 1)
        XCTAssertNotNil(loaded.appearances.first { $0.cue.key == .paceGap }?.outcome)
    }

    func testEveryReasonAndCueTextRoundTrips() throws {
        let content = CueContent(heading: .marker(3, .kilometers), main: .phrase([.gap(-31), .pace(0.3, .miles)]),
                                 subtitle: [.duration(6_300), .distance(321.9), .label("VS PLAN")], tag: "SPLIT",
                                 icon: .hill, rows: [CueRow(.marker(1, .miles), .duration(481))], footer: .label("GLANCE"))
        let cue = Cue(key: .terrain(at: 12_000), priority: .safety, content: content, createdAt: 1, expiresAt: 9, minShow: 3)
        let reasons: [Decision.Reason] = [
            .won, .interrupted(.fuel(2)), .onScreen(until: 4), .budgetEmpty, .belowBudget(.critical),
            .unreliable(.heartRate), .coolingDown(until: 90), .deferred(.time(5)), .deferred(.distance(400)),
            .deferred(.released), .outranked(by: .split(kilometer: 4)), .screenBusy(by: .scripted("gel")), .stale,
            .replaced, .finished, .cutShort(by: .kickClock), .dismissed, .budgetClosed, .finalStretch,
        ]
        var budget = Budget.strained
        budget.unreliable = [.gps]
        let state = CueStateSnapshot(RunState(elapsed: 3, distance: 12.345, pace30s: 0.29876, gapToTarget: -3.21,
                                              heartRate: 171.6, heartZone: 4, effort: .hard, effortScore: 81.23,
                                              phase: .climbing),
                                     budget: budget, situation: .climbing)
        XCTAssertEqual(state.distance, 12.3, accuracy: 1e-9)
        XCTAssertEqual(state.heartRate, 172)
        let events = reasons.enumerated().map { i, r in
            CueEvent(cue: LoggedCue(id: i, cue: cue), reason: r, t: Double(i), count: i + 1, state: state,
                     response: CueResponse.allCases[i % 4],
                     outcome: CueOutcome(measure: .heartRate, shownAt: 1, at: 61, atShow: 170, after: 168),
                     rating: CueRating.allCases[i % 3])
        }
        let log = CueLog(header: CueLog.Header(name: "all reasons", targetTime: 6_300, distance: 21_097.5,
                                               display: .coach, finishTime: 6_270.5),
                         events: events)
        XCTAssertEqual(try CueLog(jsonLines: log.jsonLines()), log)
    }

    func testATwoHourRunsLogStaysUnderTwoMegabytes() throws {
        // A 2:00 half (9:09/mi) that fades from mile 6: splits, a pace-gap cue and
        // the final stretch, over two hours.
        let plan = RunPlan(distanceMeters: SyntheticProfile.halfMarathon, targetTime: 7_200,
                           heartRateZones: HeartRateZones(resting: 55, threshold: 172, max: 190))
        let race = logRace(.slowFade(from: 6 * mile), plan: plan)
        XCTAssertGreaterThanOrEqual(race.run.finishTime ?? 0, 7_200)
        assertEveryDecisionLogged(race)
        let bytes = try race.engine.log.jsonLines().count
        XCTAssertLessThan(bytes, 2_000_000, "\(bytes) bytes")
        // And at the app's 20 updates a second, the first half hour logs about the same.
        let fast = logRace(.slowFade(from: 6 * mile), plan: plan, updatesPerSecond: 20, until: 1_800)
        XCTAssertLessThan(try fast.engine.log.jsonLines().count, 2_000_000 / 4)
    }
}
