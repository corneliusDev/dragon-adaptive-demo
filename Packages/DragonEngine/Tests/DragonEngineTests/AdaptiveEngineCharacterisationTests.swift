//  AdaptiveEngineCharacterisationTests.swift
//  Pins what today's engine does, so the pipeline rewrite can't change it by accident.
//  Run time `t` is passed explicitly; the scenario clock only moves with `dt` while running.

import XCTest
import DragonEngine

final class AdaptiveEngineCharacterisationTests: XCTestCase {
    /// An engine running `scenario` whose clock has been advanced to `clock`.
    private func engine(_ scenario: Scenario = Scenarios.cyclingTri, clock: Double) -> AdaptiveEngine {
        let e = AdaptiveEngine(scenario: scenario)
        e.running = true
        _ = e.tick(dt: clock, at: 0)
        return e
    }

    // MARK: - Glance / dwell

    func testGlanceSurfacesTheGlanceCardForTheCurrentWindow() {
        let e = engine(clock: 6)
        e.handle(.glance, at: 0)
        XCTAssertEqual(e.active?.id, "turn")
        XCTAssertEqual(e.attention, .glance)

        let later = engine(clock: 22)
        later.handle(.glance, at: 0)
        XCTAssertEqual(later.active?.id, "gel")
    }

    func testGlanceOutsideAnyWindowFallsBackToFirstUnseenGlanceCard() {
        let e = AdaptiveEngine(scenario: Scenarios.cyclingTri)
        e.handle(.glance, at: 0)
        XCTAssertEqual(e.active?.id, "turn")

        e.handle(.glance, at: 1)
        XCTAssertEqual(e.active?.id, "gel")
    }

    func testGlanceNeverSurfacesADwellCard() {
        let e = engine(clock: 30)                     // only "gap" (dwell) is in window
        e.handle(.glance, at: 0)
        XCTAssertEqual(e.active?.id, "turn")          // first unseen glance card instead
    }

    func testDwellSurfacesTheDwellCardForTheCurrentWindow() {
        let e = engine(clock: 30)
        e.handle(.dwell, at: 0)
        XCTAssertEqual(e.active?.id, "gap")
        XCTAssertEqual(e.attention, .dwell)

        let sof = engine(Scenarios.operatorSOF, clock: 30)
        sof.handle(.dwell, at: 0)
        XCTAssertEqual(sof.active?.id, "stat")
    }

    func testDwellAlsoSurfacesGlanceCards() {
        let e = engine(clock: 6)
        e.handle(.dwell, at: 0)
        XCTAssertEqual(e.active?.id, "turn")
    }

    func testIdleAttentionSurfacesNothing() {
        let e = engine(clock: 6)
        e.handle(.idle, at: 0)
        XCTAssertNil(e.active)
        XCTAssertEqual(e.attention, .idle)
    }

    // MARK: - Auto cards

    func testAutoCardAppearsWhileRunningInItsWindow() {
        let e = engine(clock: 12.9)
        XCTAssertNil(e.active)

        _ = e.tick(dt: 0.2, at: 0.1)                  // clock 13.1
        XCTAssertEqual(e.active?.id, "hr")
        XCTAssertEqual(e.attention, .idle)

        let sof = engine(Scenarios.operatorSOF, clock: 15)
        XCTAssertEqual(sof.active?.id, "con")
    }

    func testAutoCardDoesNotAppearWhilePaused() {
        let e = engine(clock: 12.9)
        e.running = false
        _ = e.tick(dt: 1, at: 1)
        XCTAssertEqual(e.clock, 12.9, accuracy: 1e-9)
        XCTAssertNil(e.active)
    }

    func testAutoCardReplacesAGlancedCard() {
        let e = engine(clock: 12)
        e.handle(.glance, at: 0)
        XCTAssertEqual(e.active?.id, "turn")

        _ = e.tick(dt: 1.5, at: 0.5)                  // clock 13.5
        XCTAssertEqual(e.active?.id, "hr")
        XCTAssertEqual(e.attention, .idle)
    }

    func testAutoCardResurfacesAfterTimingOutInsideItsWindow() {
        let e = engine(clock: 13.5)
        XCTAssertEqual(e.active?.id, "hr")

        _ = e.tick(dt: 0, at: 5.01)
        XCTAssertEqual(e.flywheel, 1)
        XCTAssertEqual(e.active?.id, "hr")
    }

    // MARK: - Lifetimes and flywheel

    func testGlanceCardLivesFiveSeconds() {
        let e = AdaptiveEngine(scenario: Scenarios.cyclingTri)
        e.handle(.glance, at: 100)

        _ = e.tick(dt: 0.05, at: 105)
        XCTAssertEqual(e.active?.id, "turn")

        _ = e.tick(dt: 0.05, at: 105.01)
        XCTAssertNil(e.active)
    }

    func testDwellCardLivesEightSeconds() {
        let e = AdaptiveEngine(scenario: Scenarios.cyclingTri)
        e.handle(.dwell, at: 100)

        _ = e.tick(dt: 0.05, at: 107.99)
        XCTAssertNotNil(e.active)

        _ = e.tick(dt: 0.05, at: 108.01)
        XCTAssertNil(e.active)
    }

    func testFlywheelIncrementsWhenAnActiveCardTimesOut() {
        let e = AdaptiveEngine(scenario: Scenarios.cyclingTri)
        var reported: [Int] = []
        e.onFlywheel = { reported.append($0) }

        e.handle(.glance, at: 0)
        _ = e.tick(dt: 0.05, at: 4)
        XCTAssertEqual(e.flywheel, 0)

        _ = e.tick(dt: 0.05, at: 5.1)
        XCTAssertEqual(e.flywheel, 1)
        _ = e.tick(dt: 0.05, at: 6)                   // no card, no increment
        XCTAssertEqual(e.flywheel, 1)

        e.handle(.dwell, at: 10)
        _ = e.tick(dt: 0.05, at: 18.1)
        XCTAssertEqual(e.flywheel, 2)
        XCTAssertEqual(reported, [1, 2])
    }

    func testAttentionFallsBackToIdle() {
        let e = AdaptiveEngine(scenario: Scenarios.cyclingTri)
        e.handle(.glance, at: 0)
        _ = e.tick(dt: 0, at: 1.5)
        XCTAssertEqual(e.attention, .glance)
        _ = e.tick(dt: 0, at: 1.51)
        XCTAssertEqual(e.attention, .idle)

        e.handle(.dwell, at: 10)
        _ = e.tick(dt: 0, at: 12.6)
        XCTAssertEqual(e.attention, .dwell)
        _ = e.tick(dt: 0, at: 12.61)
        XCTAssertEqual(e.attention, .idle)
    }

    // MARK: - Clock

    func testClockLoopsAfterFortySecondsAndForgetsSeenCards() {
        let e = AdaptiveEngine(scenario: Scenarios.cyclingTri)
        e.handle(.glance, at: 0)                      // turn seen
        e.handle(.glance, at: 0)                      // gel seen
        e.running = true
        _ = e.tick(dt: 40, at: 100)
        XCTAssertEqual(e.clock, 40)
        _ = e.tick(dt: 0.05, at: 100)
        XCTAssertEqual(e.clock, 0)

        e.handle(.glance, at: 100)
        XCTAssertEqual(e.active?.id, "turn")          // unseen again
    }

    func testResetAndSetScenarioClearState() {
        let e = engine(clock: 13.5)
        XCTAssertNotNil(e.active)

        e.setScenario(Scenarios.operatorSOF)
        XCTAssertEqual(e.scenario.key, "sof")
        XCTAssertNil(e.active)
        XCTAssertFalse(e.running)
        XCTAssertEqual(e.clock, 0)
        XCTAssertEqual(e.flywheel, 0)
        XCTAssertEqual(e.attention, .idle)
    }

    // MARK: - Motion

    func testMotionBandsSwitchAt6And38And72() {
        let e = AdaptiveEngine(scenario: Scenarios.cyclingTri)
        let cases: [(Double, MotionBand)] = [
            (0, .stationary), (5.99, .stationary),
            (6, .light), (37.99, .light),
            (38, .moderate), (71.99, .moderate),
            (72, .hard), (100, .hard),
        ]
        for (motion, band) in cases {
            e.motion = motion
            XCTAssertEqual(e.band, band, "motion \(motion)")
        }
        XCTAssertEqual(MotionBand.allLabels, ["STATIONARY", "LIGHT", "MODERATE", "HARD"])
    }

    func testHeartRateFallsBackToMotionEstimate() {
        let e = AdaptiveEngine(scenario: Scenarios.cyclingTri)
        e.motion = 50
        XCTAssertEqual(e.heartRate, 142)
        e.measuredHeartRate = 150
        XCTAssertEqual(e.heartRate, 150)
    }

    // MARK: - Render

    func testStationaryWithNoCardDrawsTheDashboard() {
        let e = AdaptiveEngine(scenario: Scenarios.cyclingTri)
        let sig = e.tick(dt: 0, at: 0).signature
        XCTAssertTrue(sig.hasPrefix("c|l8|t24,48,1,8,CYCLING / TRI"))
        XCTAssertTrue(sig.contains("LOOK FOR CONTEXT"))
        XCTAssertFalse(sig.contains("FUEL  GEL @ 0:45"))   // only the first 4 rows
    }

    func testMovingWithNoCardDrawsAmbient() {
        let e = AdaptiveEngine(scenario: Scenarios.cyclingTri)
        e.motion = 80
        XCTAssertEqual(
            e.tick(dt: 0, at: 0).signature,
            "c|l15|t152,136,3,15,27.2|t152,168,1,9,MPH"
        )
    }

    func testActiveCardDrawsOverDashboard() {
        let e = AdaptiveEngine(scenario: Scenarios.cyclingTri)
        e.handle(.glance, at: 0)
        let sig = e.render().signature
        XCTAssertTrue(sig.contains("t152,128,3,15,TURN 200m"))
        XCTAssertTrue(sig.contains("t152,162,2,14,BEAR RIGHT"))
        XCTAssertTrue(sig.contains("t152,206,1,11,NAV"))
        XCTAssertFalse(sig.contains("LOOK FOR CONTEXT"))
    }
}

private extension MotionBand {
    static var allLabels: [String] {
        [MotionBand.stationary, .light, .moderate, .hard].map(\.label)
    }
}
