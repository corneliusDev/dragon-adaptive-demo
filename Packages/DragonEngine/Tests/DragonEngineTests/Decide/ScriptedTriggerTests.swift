//  ScriptedTriggerTests.swift
//  The demo cards as an ordinary trigger, and the arbiter's scripted rule
//  (newest card wins) that keeps them behaving as they always have.

import XCTest
import DragonEngine

final class ScriptedTriggerTests: XCTestCase {
    private let state = RunState(elapsed: 0, distance: 0)

    private func trigger(clock: Double, _ scenario: Scenario = Scenarios.cyclingTri) -> ScriptedTrigger {
        var t = ScriptedTrigger(scenario: scenario)
        t.running = true
        t.advance(by: clock)
        return t
    }

    func testAutoCardsAreProposedInTheirWindowWhileRunning() {
        var t = trigger(clock: 12)
        XCTAssertTrue(t.evaluate(state: state, at: 0).isEmpty)
        t.advance(by: 1.5)
        let cues = t.evaluate(state: state, at: 1)
        XCTAssertEqual(cues.map(\.key), [.scripted("hr")])
        XCTAssertEqual(cues.first?.priority, .critical)
        XCTAssertEqual(cues.first?.reveal, .auto)
        XCTAssertEqual(cues.first?.expiresAt, 1)                   // now or not at all
        XCTAssertEqual(CueFormat.string(cues[0].content.main), "HR  Z4")

        // Not again while it is on screen; nothing while paused.
        t.showing = .scripted("hr")
        XCTAssertTrue(t.evaluate(state: state, at: 2).isEmpty)
        t.showing = nil
        t.running = false
        XCTAssertTrue(t.evaluate(state: state, at: 2).isEmpty)
    }

    func testRequestsAnswerWithTheWindowsCardElseTheFirstUnseen() {
        var t = trigger(clock: 22)
        XCTAssertEqual(t.request(.glance, at: 0)?.key, .scripted("gel"))
        XCTAssertNil(t.request(.idle, at: 0))
        var outside = trigger(clock: 0)
        XCTAssertEqual(outside.request(.glance, at: 0)?.key, .scripted("turn"))
        XCTAssertEqual(outside.request(.glance, at: 0)?.key, .scripted("gel"))
        XCTAssertNil(outside.request(.glance, at: 0))                    // all glance cards seen
        let dwell = outside.request(.dwell, at: 0)
        XCTAssertEqual(dwell?.key, .scripted("gap"))
        XCTAssertEqual(dwell?.minShow ?? 0, 8, accuracy: 1e-9)
        XCTAssertGreaterThan(dwell?.minShow ?? 0, 8)                     // held through its eighth second
        XCTAssertNil(outside.request(.dwell, at: 0))

        // The loop forgets what was seen.
        outside.advance(by: 40.01)
        XCTAssertEqual(outside.clock, 0)
        XCTAssertTrue(outside.seen.isEmpty)
    }

    func testQuietScreenIsTheDashboardStandingStillElseAmbient() {
        let t = ScriptedTrigger(scenario: Scenarios.operatorSOF)
        XCTAssertEqual(t.quietScreen(band: .stationary, motion: 0, heartRate: 96),
                       .dashboard(title: "OPERATOR / SOF", rows: Scenarios.operatorSOF.dashboard))
        XCTAssertEqual(t.quietScreen(band: .hard, motion: 100, heartRate: 180), .ambient(big: "060", unit: "AZ", sub: "WP2 80m"))
    }

    func testScriptedArbiterLetsTheNewestCardTakeTheScreen() {
        var arbiter = Arbiter(config: .scripted)
        let budget = Budget.relaxed
        var t = trigger(clock: 13.5)
        let hr = t.evaluate(state: state, at: 0)
        XCTAssertEqual(arbiter.decide(hr, budget: budget, at: 0).showing?.key, .scripted("hr"))

        // A glance answer replaces the critical card at once, though it is only info...
        let glance = t.request(.glance, at: 1)!
        let (shown, decisions) = arbiter.decide([glance], budget: budget, at: 1)
        XCTAssertEqual(shown?.key, .scripted("turn"))
        XCTAssertEqual(decisions.first { $0.key == .scripted("hr") }?.reason, .cutShort(by: .scripted("turn")))
        // ...and asking again restarts it.
        let again = t.request(.glance, at: 3)!
        XCTAssertEqual(again.key, .scripted("gel"))
        XCTAssertEqual(arbiter.decide([again], budget: budget, at: 3).showing?.key, .scripted("gel"))
        XCTAssertEqual(arbiter.decide([t.cue(for: Scenarios.cyclingTri.cards[2], priority: .info, show: 5, at: 4)],
                                      budget: budget, at: 4).decisions.first?.reason, .replaced)
        XCTAssertEqual(arbiter.shownAt, 4)

        // No cooldowns: the same card can come straight back.
        XCTAssertEqual(arbiter.decide([], budget: budget, at: 9.01).decisions.first?.reason, .finished)
        XCTAssertEqual(arbiter.decide(t.evaluate(state: state, at: 9.01), budget: budget, at: 9.01).showing?.key,
                       .scripted("hr"))
    }

    func testRaceArbiterIsUnchangedByTheScriptedRule() {
        var arbiter = Arbiter()
        XCTAssertFalse(arbiter.config.newestWins)
        let split = Cue(key: .split(mile: 1), priority: .advisory, content: CueContent(main: .label("X")),
                        createdAt: 0, expiresAt: 20, minShow: 3)
        let later = Cue(key: .split(mile: 2), priority: .advisory, content: CueContent(main: .label("Y")),
                        createdAt: 1, expiresAt: 20, minShow: 3)
        _ = arbiter.decide([split], budget: .steady, at: 0)
        XCTAssertEqual(arbiter.decide([later], budget: .steady, at: 1).showing?.key, .split(mile: 1))
    }
}
