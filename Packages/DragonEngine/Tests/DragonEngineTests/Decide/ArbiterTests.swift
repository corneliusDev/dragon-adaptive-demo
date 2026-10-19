//  ArbiterTests.swift
//  Chunk 5 acceptance: the six arbiter rules, deferral, dismissal, and that
//  every cue in play gets a recorded decision — on hand-made cues and on
//  whole synthetic races through RunEngine.

import XCTest
import DragonEngine

final class ArbiterTests: XCTestCase {
    private func cue(_ key: CueKey, _ priority: Priority, at t: TimeInterval, show: TimeInterval = 3,
                     expires: TimeInterval = 20, gap: TimeInterval? = nil, deferUntil: Deferral? = nil) -> Cue {
        Cue(key: key, priority: priority, content: CueContent(main: .label("X")),
            createdAt: t, expiresAt: t + expires, minShow: show, planGap: gap, deferUntil: deferUntil)
    }

    private func decision(_ key: CueKey, in decisions: [Decision]) -> Decision? {
        let matching = decisions.filter { $0.key == key }
        XCTAssertLessThanOrEqual(matching.count, 1, "\(key.name) decided twice in one call")
        return matching.first
    }

    // MARK: Rule 2: highest priority wins, ties to the biggest gap

    func testHigherPriorityShowsAndTheOtherIsHeldBackWithTheReason() {
        var arbiter = Arbiter()
        let split = cue(.split(mile: 3), .advisory, at: 0, gap: 4)
        let gap = cue(.paceGap, .critical, at: 0, show: 5, gap: 20)
        let (showing, decisions) = arbiter.decide([split, gap], budget: .steady, at: 0)
        XCTAssertEqual(showing?.key, .paceGap)
        XCTAssertEqual(decisions.count, 2)
        XCTAssertEqual(decision(.paceGap, in: decisions)?.outcome, .shown)
        XCTAssertEqual(decision(.paceGap, in: decisions)?.reason, .won)
        let held = decision(.split(mile: 3), in: decisions)
        XCTAssertEqual(held?.outcome, .heldBack)
        XCTAssertEqual(held?.reason, .outranked(by: .paceGap))
        XCTAssertEqual(held?.text, "outranked by the pace gap")

        // Next call the split waits for the screen, and says so.
        let next = arbiter.decide([], budget: .steady, at: 1).decisions
        XCTAssertEqual(decision(.split(mile: 3), in: next)?.reason, .screenBusy(by: .paceGap))
        XCTAssertEqual(decision(.paceGap, in: next)?.reason, .onScreen(until: 5))
        // And shows once the pace gap has had its 5 s.
        let (after, end) = arbiter.decide([], budget: .steady, at: 5)
        XCTAssertEqual(after?.key, .split(mile: 3))
        XCTAssertEqual(decision(.paceGap, in: end)?.reason, .finished)
        XCTAssertEqual(decision(.split(mile: 3), in: end)?.reason, .won)
    }

    func testEqualPriorityGoesToTheBiggestGapFromPlan() {
        var arbiter = Arbiter()
        let small = cue(.split(mile: 1), .advisory, at: 0, gap: 5)
        let big = cue(.split(mile: 2), .advisory, at: 0, gap: -13)
        XCTAssertEqual(arbiter.decide([small, big], budget: .steady, at: 0).showing?.key, .split(mile: 2))

        // No gap at all ties at zero: the one waiting longest goes first.
        var plain = Arbiter()
        let a = cue(.split(mile: 1), .advisory, at: 0), b = cue(.split(mile: 2), .advisory, at: 0)
        XCTAssertEqual(plain.decide([a, b], budget: .steady, at: 0).showing?.key, .split(mile: 1))
    }

    // MARK: Rule 1: the budget

    func testEmptyBudgetShowsNothingButSafety() {
        var arbiter = Arbiter()
        let gap = cue(.paceGap, .critical, at: 0, show: 5, expires: 30)
        let (showing, decisions) = arbiter.decide([gap], budget: .safetyOnly, at: 0)
        XCTAssertNil(showing)
        XCTAssertEqual(decision(.paceGap, in: decisions)?.reason, .budgetEmpty)

        let kick = cue(.split(mile: 13), .safety, at: 1)
        XCTAssertEqual(arbiter.decide([kick], budget: .safetyOnly, at: 1).showing?.key, .split(mile: 13))
    }

    func testCueUnderTheBudgetsMinimumPriorityIsHeldBack() {
        var arbiter = Arbiter()
        let info = cue(.split(mile: 1), .info, at: 0)
        let (showing, decisions) = arbiter.decide([info], budget: .steady, at: 0)
        XCTAssertNil(showing)
        XCTAssertEqual(decision(.split(mile: 1), in: decisions)?.reason, .belowBudget(.advisory))
        // The budget opens up (runner stops): it shows.
        XCTAssertEqual(arbiter.decide([], budget: .relaxed, at: 1).showing?.key, .split(mile: 1))
        // The budget closes while it shows: it comes down.
        let (after, closed) = arbiter.decide([], budget: .safetyOnly, at: 2)
        XCTAssertNil(after)
        XCTAssertEqual(decision(.split(mile: 1), in: closed)?.reason, .budgetClosed)
    }

    // MARK: Rule 3: cooldowns

    func testSecondPaceGapCueInsideNinetySecondsIsHeldBackAndOneAfterShows() {
        var arbiter = Arbiter()
        XCTAssertEqual(arbiter.decide([cue(.paceGap, .critical, at: 0, show: 5, expires: 30)],
                                      budget: .steady, at: 0).showing?.key, .paceGap)
        XCTAssertEqual(arbiter.cooldownUntil[.paceGap], 90)

        // A second one at 50 s: held back for its whole life, then expires unseen.
        var t: TimeInterval = 1
        var proposals: [TimeInterval: Cue] = [50: cue(.paceGap, .critical, at: 50, show: 5, expires: 30)]
        while t <= 85 {
            let (showing, decisions) = arbiter.decide(proposals.removeValue(forKey: t).map { [$0] } ?? [],
                                                      budget: .steady, at: t)
            if t >= 50 {
                XCTAssertNil(showing, "t=\(t)")
                let d = decision(.paceGap, in: decisions)
                if t <= 80 {
                    XCTAssertEqual(d?.reason, .coolingDown(until: 90), "t=\(t)")
                    XCTAssertEqual(d?.outcome, .heldBack)
                } else if t == 81 {
                    XCTAssertEqual(d?.reason, .stale)
                } else {
                    XCTAssertNil(d, "an expired cue leaves play")
                }
            }
            t += 1
        }

        // One proposed after the 90 s shows straight away.
        let late = arbiter.decide([cue(.paceGap, .critical, at: 95, show: 5, expires: 30)], budget: .steady, at: 95)
        XCTAssertEqual(late.showing?.key, .paceGap)
        XCTAssertEqual(late.decisions.first?.reason, .won)
        XCTAssertEqual(arbiter.cooldownUntil[.paceGap], 185)

        // A cue proposed late in the cooldown waits it out and shows the moment it ends.
        var waits = Arbiter()
        _ = waits.decide([cue(.paceGap, .critical, at: 0, show: 5)], budget: .steady, at: 0)
        _ = waits.decide([cue(.paceGap, .critical, at: 80, show: 5, expires: 30)], budget: .steady, at: 80)
        XCTAssertNil(waits.decide([], budget: .steady, at: 89.5).showing)
        XCTAssertEqual(waits.decide([], budget: .steady, at: 90).showing?.key, .paceGap)
    }

    func testDismissedCueCoolsDownLongerThanAnIgnoredOne() {
        let first = cue(.paceGap, .critical, at: 0, show: 5, expires: 30)
        let again = cue(.paceGap, .critical, at: 100, show: 5, expires: 200)

        // Ignored: it shows for its 5 s and comes down by itself.
        var ignored = Arbiter()
        _ = ignored.decide([first], budget: .steady, at: 0)
        _ = ignored.decide([], budget: .steady, at: 5)
        XCTAssertEqual(ignored.decide([again], budget: .steady, at: 100).showing?.key, .paceGap)

        // Dismissed two seconds in.
        var dismissed = Arbiter()
        _ = dismissed.decide([first], budget: .steady, at: 0)
        XCTAssertTrue(dismissed.dismiss(at: 2))
        XCTAssertNil(dismissed.showing)
        XCTAssertFalse(dismissed.dismiss(at: 2.5), "nothing left to dismiss")
        let (none, report) = dismissed.decide([], budget: .steady, at: 3)
        XCTAssertNil(none)
        XCTAssertEqual(report, [Decision(t: 2, key: .paceGap, priority: .critical, reason: .dismissed)])
        XCTAssertEqual(report.first?.outcome, .expired)

        let ignoredUntil = ignored.cooldownUntil[.paceGap] ?? 0, dismissedUntil = dismissed.cooldownUntil[.paceGap] ?? 0
        XCTAssertGreaterThan(dismissedUntil - 2, 90, "dismissed cooldown longer than the ignored 90 s")
        XCTAssertEqual(dismissedUntil, 2 + Arbiter.Config().dismissedCooldown)
        XCTAssertGreaterThan(Arbiter.Config().dismissedCooldown, Arbiter.Config().cooldown)
        XCTAssertLessThan(ignoredUntil - 100, dismissedUntil - 2)

        // The same re-proposal at 100 s that the ignored arbiter showed is held back...
        let (held, decisions) = dismissed.decide([again], budget: .steady, at: 100)
        XCTAssertNil(held)
        XCTAssertEqual(decision(.paceGap, in: decisions)?.reason, .coolingDown(until: dismissedUntil))
        XCTAssertEqual(decision(.paceGap, in: decisions)?.text, "in its cooldown for 82 s more")
        // ...until the longer cooldown ends.
        XCTAssertNil(dismissed.decide([], budget: .steady, at: dismissedUntil - 1).showing)
        XCTAssertEqual(dismissed.decide([], budget: .steady, at: dismissedUntil).showing?.key, .paceGap)
    }

    // MARK: Rule 4: let a cue finish

    func testShowingAdvisoryCueIsNotReplacedByInfoButIsByCritical() {
        var arbiter = Arbiter()
        let split = cue(.split(mile: 4), .advisory, at: 0, show: 3)
        XCTAssertEqual(arbiter.decide([split], budget: .relaxed, at: 0).showing?.key, .split(mile: 4))

        // An info cue (allowed by this budget) waits.
        let info = cue(.split(mile: 99), .info, at: 1, show: 2)
        let (stays, busy) = arbiter.decide([info], budget: .relaxed, at: 1)
        XCTAssertEqual(stays?.key, .split(mile: 4))
        XCTAssertEqual(decision(.split(mile: 99), in: busy)?.reason, .screenBusy(by: .split(mile: 4)))
        XCTAssertEqual(arbiter.decide([], budget: .relaxed, at: 2.9).showing?.key, .split(mile: 4))

        // A critical one cuts it short.
        let gap = cue(.paceGap, .critical, at: 2, show: 5, expires: 30)
        let (cut, decisions) = arbiter.decide([gap], budget: .relaxed, at: 2.95)
        XCTAssertEqual(cut?.key, .paceGap)
        XCTAssertEqual(decision(.split(mile: 4), in: decisions)?.reason, .cutShort(by: .paceGap))
        XCTAssertEqual(decision(.split(mile: 4), in: decisions)?.outcome, .expired)
        XCTAssertEqual(decision(.paceGap, in: decisions)?.reason, .interrupted(.split(mile: 4)))
        XCTAssertEqual(decision(.split(mile: 99), in: decisions)?.reason, .outranked(by: .paceGap))

        // The info cue gets its turn after the pace gap's 5 s (its expiry is 21 s).
        XCTAssertEqual(arbiter.decide([], budget: .relaxed, at: 7.95).showing?.key, .split(mile: 99))
    }

    func testEqualPriorityWaitsAndNoInterruptBudgetLetsOnlySafetyThrough() {
        var arbiter = Arbiter()
        _ = arbiter.decide([cue(.split(mile: 1), .advisory, at: 0)], budget: .steady, at: 0)
        let (same, _) = arbiter.decide([cue(.split(mile: 2), .advisory, at: 1, gap: 60)], budget: .steady, at: 1)
        XCTAssertEqual(same?.key, .split(mile: 1), "a bigger gap doesn't cut short an equal priority")

        let calm = Budget(maxElements: 2, minPriority: .advisory, allowInterrupt: false)
        let (stays, d) = arbiter.decide([cue(.paceGap, .critical, at: 2, show: 5, expires: 30)], budget: calm, at: 2)
        XCTAssertEqual(stays?.key, .split(mile: 1))
        XCTAssertEqual(decision(.paceGap, in: d)?.reason, .screenBusy(by: .split(mile: 1)))
        let (safety, _) = arbiter.decide([cue(.split(mile: 13), .safety, at: 2.5)], budget: calm, at: 2.5)
        XCTAssertEqual(safety?.key, .split(mile: 13))
    }

    // MARK: Rule 5: stale cues, and deferral

    func testSplitHeldMoreThanTwentySecondsIsDroppedAsExpired() {
        var arbiter = Arbiter()
        let expiry = SplitTrigger.Config().expiresAfter
        XCTAssertEqual(expiry, 20)
        // Something critical holds the screen for 30 s.
        _ = arbiter.decide([cue(.paceGap, .critical, at: 0, show: 30, expires: 30)], budget: .steady, at: 0)
        let split = cue(.split(mile: 5), .advisory, at: 1, expires: expiry)
        var t: TimeInterval = 1
        var outcomes: [Decision.Outcome] = []
        var reasons: [Decision.Reason] = []
        while t <= 40 {
            let (showing, decisions) = arbiter.decide(t == 1 ? [split] : [], budget: .steady, at: t)
            XCTAssertNotEqual(showing?.key, .split(mile: 5), "shown late at t=\(t)")
            if let d = decision(.split(mile: 5), in: decisions) {
                outcomes.append(d.outcome)
                reasons.append(d.reason)
            }
            t += 1
        }
        XCTAssertEqual(outcomes, Array(repeating: .heldBack, count: 21) + [.expired],
                       "held from 1 s to 21 s (its expiry), dropped at 22 s")
        XCTAssertEqual(reasons.last, .stale)
        XCTAssertEqual(Decision(t: 22, key: .split(mile: 5), priority: .advisory, reason: .stale).text,
                       "couldn't show in time; skipped, not shown late")
        XCTAssertTrue(arbiter.waiting.isEmpty)
    }

    func testDeferredSplitWaitsForItsConditionAndStillExpires() {
        // Held until the crest at 13 000 m; shows once there.
        var arbiter = Arbiter()
        let crest = 13_000.0
        let held = cue(.split(mile: 8), .advisory, at: 0, expires: 60, deferUntil: .distance(crest))
        let (none, first) = arbiter.decide([held], budget: .steady, at: 0, distance: 12_880)
        XCTAssertNil(none)
        XCTAssertEqual(first.first?.reason, .deferred(.distance(crest)))
        XCTAssertNil(arbiter.decide([], budget: .steady, at: 20, distance: 12_960).showing)
        XCTAssertNil(arbiter.decide([], budget: .steady, at: 25).showing, "unknown distance keeps it waiting")
        XCTAssertEqual(arbiter.decide([], budget: .steady, at: 30, distance: 13_001).showing?.key, .split(mile: 8))

        // Never reaches the crest in time: dropped, not shown late.
        var late = Arbiter()
        _ = late.decide([held], budget: .steady, at: 0, distance: 12_880)
        let (gone, d) = late.decide([], budget: .steady, at: 61, distance: 13_100)
        XCTAssertNil(gone)
        XCTAssertEqual(d.first?.reason, .stale)

        // Released explicitly, and deferred by time.
        var released = Arbiter()
        _ = released.decide([cue(.split(mile: 2), .advisory, at: 0, deferUntil: .released)], budget: .steady, at: 0)
        XCTAssertNil(released.decide([], budget: .steady, at: 5).showing)
        released.release(.split(mile: 2))
        XCTAssertEqual(released.decide([], budget: .steady, at: 6).showing?.key, .split(mile: 2))

        var timed = Arbiter()
        _ = timed.decide([cue(.split(mile: 3), .advisory, at: 0, deferUntil: .time(10))], budget: .steady, at: 0)
        XCTAssertNil(timed.decide([], budget: .steady, at: 9).showing)
        XCTAssertEqual(timed.decide([], budget: .steady, at: 10).showing?.key, .split(mile: 3))
    }

    func testNewerProposalWithTheSameKeyReplacesTheWaitingOne() {
        var arbiter = Arbiter()
        _ = arbiter.decide([cue(.paceGap, .critical, at: 0, show: 30, expires: 40)], budget: .steady, at: 0)
        _ = arbiter.decide([cue(.split(mile: 1), .advisory, at: 1)], budget: .steady, at: 1)
        let d = arbiter.decide([cue(.split(mile: 1), .advisory, at: 2)], budget: .steady, at: 2).decisions
        XCTAssertEqual(d.filter { $0.key == .split(mile: 1) }.map(\.reason),
                       [.replaced, .screenBusy(by: .paceGap)])
        XCTAssertEqual(arbiter.waiting.count, 1)
        XCTAssertEqual(arbiter.waiting.first?.createdAt, 2)
    }

    // MARK: Rule 6: everything is recorded

    func testEveryCueInPlayGetsADecisionOnEveryCall() {
        var arbiter = Arbiter()
        var rng = SplitMix(state: 7)
        var inPlay: [CueKey] = []
        let keys: [CueKey] = [.paceGap] + (1...6).map { .split(mile: $0) }
        let budgets: [Budget] = [.relaxed, .steady, .strained, .safetyOnly]
        var dismissals = 0, replaced = 0, cut = 0
        for step in 0..<2_000 {
            let t = TimeInterval(step) * 0.5
            var proposed: [Cue] = []
            for _ in 0..<Int(rng.next() % 3) where rng.next() % 4 == 0 {
                let key = keys[Int(rng.next() % UInt64(keys.count))]
                let p = Priority(rawValue: Int(rng.next() % 4))!
                proposed.append(cue(key, p, at: t, show: Double(rng.next() % 6 + 1), expires: Double(rng.next() % 30),
                                    gap: Double(rng.next() % 40) - 20))
            }
            let budget = budgets[(step / 40) % budgets.count]
            if rng.next() % 30 == 0, arbiter.dismiss(at: t) { dismissals += 1 }
            let (showing, decisions) = arbiter.decide(proposed, budget: budget, at: t)
            checkDecisions(decisions, before: inPlay, proposed: proposed, showing: showing, at: t)
            inPlay = stillInPlay(decisions)
            // What the decisions say is still in play is exactly what the arbiter holds.
            XCTAssertEqual(inPlay.map(\.name).sorted(),
                           (arbiter.waiting.map(\.key) + (arbiter.showing.map { [$0.key] } ?? [])).map(\.name).sorted(),
                           "t=\(t)")
            replaced += decisions.filter { $0.reason == .replaced }.count
            cut += decisions.filter { if case .cutShort = $0.reason { return true } else { return false } }.count
        }
        // The shuffle exercised the awkward paths.
        XCTAssertGreaterThan(dismissals, 0)
        XCTAssertGreaterThan(replaced, 0)
        XCTAssertGreaterThan(cut, 0)
    }

    func testEveryProposalInEveryRaceIsDecidedEachStepUntilItLeavesPlay() {
        for profile in SyntheticProfile.all + [.slowFadeRecovery(from: 9 * DistanceUnit.metersPerMile,
                                                                   recoverAt: 10 * DistanceUnit.metersPerMile)] {
            let race = cueRace(profile)
            var inPlay: [CueKey] = []
            var left: Set<CueKey> = []
            for row in race.rows {
                checkDecisions(row.decisions, before: inPlay, proposed: row.proposed, showing: row.current,
                               at: row.t, profile: profile.name)
                inPlay = stillInPlay(row.decisions)
                left.formUnion(row.decisions.filter { $0.outcome == .expired }.map(\.key))
            }
            // Every proposal was recorded leaving play, or is still in play at the finish.
            for p in race.proposed {
                XCTAssertTrue(left.contains(p.cue.key) || inPlay.contains(p.cue.key),
                              "\(profile.name): \(p.cue.key.name) vanished")
            }
            // Through the arbiter every split still made it to the screen.
            for p in race.splitProposals {
                XCTAssertTrue(race.rows.contains { $0.current?.key == p.cue.key }, "\(profile.name): \(p.cue.key.name)")
            }
        }
    }

    private func stillInPlay(_ decisions: [Decision]) -> [CueKey] {
        decisions.filter { $0.outcome != .expired }.map(\.key)
    }

    /// Exactly one decision per cue in play — those still in play after the
    /// last call (a dismissal made between calls counts as that cue's
    /// decision) plus this call's proposals — at most one shown, and it is
    /// what's on screen.
    private func checkDecisions(_ decisions: [Decision], before: [CueKey], proposed: [Cue], showing: Cue?,
                                at t: TimeInterval, profile: String = "", file: StaticString = #filePath,
                                line: UInt = #line) {
        let expected = (before + proposed.map(\.key)).map(\.name).sorted()
        XCTAssertEqual(decisions.map(\.key.name).sorted(), expected, "\(profile) t=\(t)", file: file, line: line)
        let shown = decisions.filter { $0.outcome == .shown }
        XCTAssertLessThanOrEqual(shown.count, 1, "\(profile) t=\(t)", file: file, line: line)
        XCTAssertEqual(shown.first?.key, showing?.key, "\(profile) t=\(t)", file: file, line: line)
        XCTAssertTrue(decisions.allSatisfy { !$0.text.isEmpty && $0.t <= t }, file: file, line: line)
    }
}

/// Small deterministic generator for the shuffled-proposals test.
private struct SplitMix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
