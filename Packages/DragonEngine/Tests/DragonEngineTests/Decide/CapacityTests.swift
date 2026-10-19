//  CapacityTests.swift
//  Chunk 6 acceptance: one test per row of the design's capacity budget table,
//  from hand-built RunStates; the glance and held-look windows; the display
//  setting; and the arbiter obeying a budget RunEngine computed.

import XCTest
import DragonEngine

final class CapacityTests: XCTestCase {
    private let capacity = Capacity()

    private func state(phase: MovementPhase = .steady, effort: Double? = 80, ahead: Ahead? = nil,
                       quality: DataQuality = CapacityTests.goodData) -> RunState {
        RunState(elapsed: 600, distance: 2_000, ahead: ahead,
                 effort: effort.map { MotionBand(motion: $0) } ?? .stationary,
                 effortScore: effort, phase: phase, quality: quality)
    }

    private static var goodData: DataQuality {
        var q = DataQuality()
        q.gpsAccuracy = 5
        q.secondsSinceFix = 0.5
        q.paceUnknown = false
        q.secondsSinceHeartRate = 1
        return q
    }

    private func assertBudget(_ b: Budget, _ elements: Int, _ minPriority: Priority,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(b.maxElements, elements, "elements", file: file, line: line)
        XCTAssertEqual(b.minPriority, minPriority, "priority", file: file, line: line)
    }

    // MARK: The table, row by row

    func testStandingGivesThreeElementsInfoAndUp() {
        let s = state(phase: .stopped, effort: 3)
        XCTAssertEqual(capacity.situation(for: s), .standing)
        assertBudget(capacity.budget(for: s, at: 600), 3, .info)
        // Standing counts even with effort still reading high (hands on knees).
        assertBudget(capacity.budget(for: state(phase: .stopped, effort: 90), at: 600), 3, .info)
    }

    func testEasyAndSteadyGivesThreeElementsInfoAndUp() {
        let s = state(effort: 30)
        XCTAssertEqual(capacity.situation(for: s), .easy)
        assertBudget(capacity.budget(for: s, at: 600), 3, .info)
    }

    func testSteadyAtRaceEffortGivesTwoElementsAdvisoryAndUp() {
        let s = state(effort: 80)
        XCTAssertEqual(capacity.situation(for: s), .raceEffort)
        assertBudget(capacity.budget(for: s, at: 600), 2, .advisory)
        // No effort reading at all: treated as race effort, not as easy.
        assertBudget(capacity.budget(for: state(effort: nil), at: 600), 2, .advisory)
    }

    func testHardEffortGivesOneElementCriticalAndUp() {
        let s = state(effort: 92)
        XCTAssertEqual(capacity.situation(for: s), .hardEffort)
        assertBudget(capacity.budget(for: s, at: 600), 1, .critical)
    }

    func testClimbingGivesOneElementCriticalAndUp() {
        let s = state(phase: .climbing, effort: 80)
        XCTAssertEqual(capacity.situation(for: s), .climbing)
        assertBudget(capacity.budget(for: s, at: 600), 1, .critical)
        // Easy effort on a climb is still a climb.
        assertBudget(capacity.budget(for: state(phase: .climbing, effort: 30), at: 600), 1, .critical)
    }

    func testSurgeGivesNothingExceptSafety() {
        let s = state(phase: .surging, effort: 90)
        XCTAssertEqual(capacity.situation(for: s), .surge)
        let b = capacity.budget(for: s, at: 600)
        assertBudget(b, 0, .safety)
        XCTAssertTrue(b.admits(.safety))
        XCTAssertFalse([.info, .advisory, .critical].contains { b.admits($0) })
    }

    func testFinalKickGivesNothingExceptSafety() {
        let s = state(phase: .kick, effort: 94)
        XCTAssertEqual(capacity.situation(for: s), .kick)
        let b = capacity.budget(for: s, at: 600)
        assertBudget(b, 0, .safety)
        XCTAssertFalse(b.admits(.critical))
    }

    func testTechnicalTurnWithinFiftyMetresGivesNothingExceptSafety() {
        let turn = CourseFeature.turn(Turn(distance: 2_030, angle: 85))
        let near = state(effort: 80, ahead: Ahead(feature: turn, meters: 30))
        XCTAssertEqual(capacity.situation(for: near), .technicalTurn)
        assertBudget(capacity.budget(for: near, at: 600), 0, .safety)
        // Further out it's ordinary running; a hill 30 m ahead isn't a turn.
        let far = state(effort: 80, ahead: Ahead(feature: turn, meters: 80))
        assertBudget(capacity.budget(for: far, at: 600), 2, .advisory)
        let hill = CourseFeature.hill(Hill(startDistance: 2_030, endDistance: 2_400, gain: 20))
        assertBudget(capacity.budget(for: state(effort: 80, ahead: Ahead(feature: hill, meters: 30)), at: 600),
                     2, .advisory)
    }

    func testFinalFourHundredMetresByPositionGivesNothingExceptSafety() {
        // A half marathon: the stretch starts 400 m from the plan's finish,
        // decided by position, whatever the runner does.
        let total = 21_097.5
        let c = Capacity(raceDistance: total)
        func at(_ left: Double, phase: MovementPhase = .steady, effort: Double = 80) -> RunState {
            var s = state(phase: phase, effort: effort)
            s.distance = total - left
            return s
        }
        for s in [at(400), at(176), at(10), at(176, phase: .stopped, effort: 5), at(300, effort: 30),
                  at(200, phase: .kick, effort: 95), at(-5)] {
            XCTAssertEqual(c.situation(for: s), .finalStretch, "\(total - s.distance) m to go")
            let b = c.budget(for: s, at: 600)
            assertBudget(b, 0, .safety)
            XCTAssertTrue(b.finalStretch)
            XCTAssertTrue(b.admits(.safety))
            XCTAssertFalse([.info, .advisory, .critical].contains { b.admits($0) })
        }
        // Just before it, ordinary running; with no finish there's no stretch.
        XCTAssertEqual(c.situation(for: at(401)), .raceEffort)
        XCTAssertFalse(c.budget(for: at(401), at: 600).finalStretch)
        XCTAssertEqual(Capacity().situation(for: at(100)), .raceEffort)
        // Coach (or a glance) adds room, but still safety only.
        var coach = Capacity(setting: .coach, raceDistance: total)
        coach.note(AttentionSample(t: 600, event: .glance))
        assertBudget(coach.budget(for: at(100), at: 600), 2, .safety)
    }

    func testRunnerGlancedAddsOneElementForOneAndAHalfSeconds() {
        var c = Capacity()
        let s = state(effort: 80)
        c.note(AttentionSample(t: 600, event: .glance))
        assertBudget(c.budget(for: s, at: 600), 3, .advisory)
        assertBudget(c.budget(for: s, at: 601.5), 3, .advisory)
        assertBudget(c.budget(for: s, at: 601.6), 2, .advisory)
    }

    func testRunnerHeldALookAddsTwoElementsForTwoPointSixSeconds() {
        var c = Capacity()
        let s = state(effort: 80)
        c.note(AttentionSample(t: 600, event: .dwell))
        // The glasses send idle 1.5 s after the wave: it doesn't cut the window short.
        c.note(AttentionSample(t: 601.5, event: .idle))
        assertBudget(c.budget(for: s, at: 602), 4, .advisory)
        assertBudget(c.budget(for: s, at: 602.6), 4, .advisory)
        assertBudget(c.budget(for: s, at: 602.7), 2, .advisory)
    }

    func testUnreliableGPSOrHeartRateHoldsBackTheCuesThatDependOnIt() {
        var noGPS = CapacityTests.goodData
        noGPS.secondsSinceFix = 12
        noGPS.distanceEstimated = true
        noGPS.paceUnknown = true
        XCTAssertEqual(capacity.budget(for: state(quality: noGPS), at: 600).unreliable, [.gps])

        var poorFix = CapacityTests.goodData
        poorFix.gpsAccuracy = 30
        XCTAssertEqual(capacity.budget(for: state(quality: poorFix), at: 600).unreliable, [.gps])

        var noHR = CapacityTests.goodData
        noHR.secondsSinceHeartRate = 9
        XCTAssertEqual(capacity.budget(for: state(quality: noHR), at: 600).unreliable, [.heartRate])
        XCTAssertEqual(capacity.budget(for: state(), at: 600).unreliable, [])

        // Through the arbiter: a GPS cue waits while a cue that needs nothing shows.
        let budget = capacity.budget(for: state(quality: noGPS), at: 600)
        func cue(_ key: CueKey, _ p: Priority, needs: Set<CueInput>) -> Cue {
            Cue(key: key, priority: p, content: CueContent(main: .label("X")), createdAt: 600, expiresAt: 630,
                minShow: 3, needs: needs)
        }
        var arbiter = Arbiter()
        let (shown, decisions) = arbiter.decide([cue(.paceGap, .critical, needs: [.gps]),
                                                 cue(.split(mile: 2), .advisory, needs: [])],
                                                budget: budget, at: 600)
        XCTAssertEqual(shown?.key, .split(mile: 2))
        let held = decisions.first { $0.key == .paceGap }
        XCTAssertEqual(held?.reason, .unreliable(.gps))
        XCTAssertEqual(held?.outcome, .heldBack)
        XCTAssertEqual(held?.text, "GPS unreliable right now")

        // Heart rate unreliable holds a heart-rate cue but not a GPS one.
        var hrArbiter = Arbiter()
        let hrBudget = capacity.budget(for: state(quality: noHR), at: 600)
        let hr = hrArbiter.decide([cue(.paceGap, .critical, needs: [.heartRate])], budget: hrBudget, at: 600)
        XCTAssertNil(hr.showing)
        XCTAssertEqual(hr.decisions.first?.reason, .unreliable(.heartRate))
        var gpsArbiter = Arbiter()
        XCTAssertEqual(gpsArbiter.decide([cue(.paceGap, .critical, needs: [.gps])], budget: hrBudget, at: 600)
            .showing?.key, .paceGap)
    }

    func testPaceGapCueNeedsGPSAndSplitsNeedNothing() {
        let race = cueRace(.slowFade(from: 9 * DistanceUnit.metersPerMile))
        XCTAssertEqual(race.proposals(.paceGap).first?.cue.needs, [.gps])
        XCTAssertEqual(race.splitProposals.first?.cue.needs, [])
    }

    // MARK: Attention on a hard effort

    func testGlanceDuringAHardEffortAddsOneElementForOneAndAHalfSecondsThenTheBudgetReturns() {
        var c = Capacity()
        let hard = state(effort: 92)
        assertBudget(c.budget(for: hard, at: 600), 1, .critical)
        c.note(AttentionSample(t: 600, event: .glance))
        for t in stride(from: 600.0, through: 601.5, by: 0.25) {
            assertBudget(c.budget(for: hard, at: t), 2, .critical)
        }
        assertBudget(c.budget(for: hard, at: 601.55), 1, .critical)
        assertBudget(c.budget(for: hard, at: 620), 1, .critical)
    }

    func testGlanceThroughRunEngineDuringAHardEffort() {
        var run = SyntheticRun(profile: .onPlan)
        var engine = RunEngine(plan: run.plan)
        engine.effortOverride = 95
        var budgets: [(t: TimeInterval, budget: Budget)] = []
        while run.time < 120 {
            for event in run.advance(by: 0.25) { engine.ingest(event) }
            if run.time == 100 { engine.ingest(.attention(AttentionSample(t: 100, event: .glance))) }
            let step = engine.update(at: run.time)
            XCTAssertEqual(step.situation, .hardEffort, "t=\(run.time)")
            budgets.append((run.time, step.budget))
        }
        for (t, b) in budgets where t > 60 {
            XCTAssertEqual(b.maxElements, t >= 100 && t <= 101.5 ? 2 : 1, "t=\(t)")
            XCTAssertEqual(b.minPriority, .critical)
        }
    }

    // MARK: Display setting

    func testDisplaySettingShiftsTheBudgetByOneElementEachWay() {
        let rows: [(RunState, Int)] = [(state(phase: .stopped, effort: 3), 3), (state(effort: 80), 2),
                                       (state(effort: 92), 1), (state(phase: .kick, effort: 94), 0)]
        for (s, balanced) in rows {
            let minimal = Capacity(setting: .minimal).budget(for: s, at: 600)
            let normal = Capacity(setting: .balanced).budget(for: s, at: 600)
            let coach = Capacity(setting: .coach).budget(for: s, at: 600)
            XCTAssertEqual(normal.maxElements, balanced)
            XCTAssertEqual(minimal.maxElements, max(0, balanced - 1))
            XCTAssertEqual(coach.maxElements, balanced + 1)
            // Only the element count moves, and safety always gets through.
            XCTAssertEqual(Set([minimal.minPriority, normal.minPriority, coach.minPriority]).count, 1)
            XCTAssertTrue([minimal, normal, coach].allSatisfy { $0.admits(.safety) })
        }
        // Coach in a kick has room for one element, but still only for safety.
        let coachKick = Capacity(setting: .coach).budget(for: state(phase: .kick, effort: 94), at: 600)
        XCTAssertFalse(coachKick.admits(.critical))
        // Minimal on a hard effort empties the budget: only safety gets through.
        let minimalHard = Capacity(setting: .minimal).budget(for: state(effort: 92), at: 600)
        XCTAssertTrue(minimalHard.isEmpty)
        XCTAssertFalse(minimalHard.admits(.critical))
        XCTAssertTrue(minimalHard.admits(.safety))
    }

    func testRunEngineDisplaySettingAndEffortOverrideChangeTheBudget() {
        var run = SyntheticRun(profile: .onPlan)
        var engine = RunEngine(plan: run.plan)
        for event in run.advance(by: 60) { engine.ingest(event) }
        XCTAssertEqual(engine.update(at: run.time).budget.maxElements, 2)
        engine.displaySetting = .coach
        XCTAssertEqual(engine.update(at: run.time).budget.maxElements, 3)
        engine.displaySetting = .minimal
        XCTAssertEqual(engine.update(at: run.time).budget.maxElements, 1)

        // Dragging the effort up makes it sparser.
        engine.displaySetting = .balanced
        var last = Int.max
        for effort in stride(from: 0.0, through: 100, by: 10) {
            engine.effortOverride = effort
            let n = engine.update(at: run.time).budget.maxElements
            XCTAssertLessThanOrEqual(n, last, "effort \(effort)")
            last = n
        }
        XCTAssertEqual(last, 1)
        engine.effortOverride = nil
        XCTAssertEqual(engine.update(at: run.time).budget.maxElements, 2)
    }
}
