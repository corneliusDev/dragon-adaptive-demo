//  RaceCueTests.swift
//  The RACE source feeding the plan-driven RunEngine, the way HUDController
//  wires it: the first mile's split comes out as a frame for the mirror and
//  the glasses, and as the telemetry row's label.

import XCTest
import DragonEngine
@testable import Dragon_Adaptive

final class RaceCueTests: XCTestCase {
    func testSyntheticRaceThroughRunEngineShowsTheMileOneSplit() {
        let source = SyntheticRaceSource(profile: .onPlan, seed: 42)
        var engine = RunEngine(plan: source.run.plan)
        source.onSample = { engine.ingest(.location($0)) }
        source.onVitals = { engine.ingest(.vitals($0)) }

        var shown: Cue?
        var frame = HUDFrame()
        while source.run.time < 600, shown == nil {
            source.step(by: 0.5)          // 10× speed at 20 ticks a second
            engine.update(at: source.run.time)
            if engine.current?.key == .split(mile: 1) {
                shown = engine.current
                frame = engine.frame()
            }
        }
        guard let cue = shown else { return XCTFail("no mile 1 split in the first 10 minutes") }
        XCTAssertEqual(HUDController.cueTag(cue).prefix(9), "MILE 1 · ")
        let texts = frame.ops.compactMap { op -> String? in
            if case .text(_, _, _, _, _, let s) = op { return s } else { return nil }
        }
        XCTAssertEqual(texts.first, "MILE 1")
        XCTAssertTrue(texts.contains("SPLIT"))
    }

    func testOverlayShowsTheArbitersDecisionAndReasonDuringASyntheticRace() {
        let source = SyntheticRaceSource(profile: .onPlan, seed: 42)
        var engine = RunEngine(plan: source.run.plan)
        source.onSample = { engine.ingest(.location($0)) }
        source.onVitals = { engine.ingest(.vitals($0)) }

        var lines: [String] = []
        while source.run.time < 600, lines.count < 2 {
            source.step(by: 0.5)
            let step = engine.update(at: source.run.time)
            for d in step.decisions where d.key == .split(mile: 1) {
                lines.append(RunStateFormat.decision(d))
            }
        }
        XCTAssertEqual(lines.first, "SHOWN · mile 1 split · highest priority the budget allows")
        XCTAssertEqual(lines.dropFirst().first?.hasPrefix("SHOWN · mile 1 split · keeps the screen"), true)
        XCTAssertEqual(RunStateFormat.decision(Decision(t: 0, key: .paceGap, priority: .critical,
                                                        reason: .coolingDown(until: 42))),
                       "HELD · pace gap · in its cooldown for 42 s more")
    }

    func testEffortSliderMakesTheRaceDisplaySparserAndDisplaySettingShiftsIt() {
        // The way HUDController builds its race engine: Balanced, measured effort.
        let source = SyntheticRaceSource(profile: .onPlan, seed: 42)
        var engine = HUDController.makeRunEngine(plan: source.run.plan, display: .balanced, effort: nil)
        source.onSample = { engine.ingest(.location($0)) }
        source.onVitals = { engine.ingest(.vitals($0)) }
        while source.run.time < 120 { source.step(by: 0.5) }
        let t = source.run.time
        XCTAssertEqual(engine.update(at: t).budget.maxElements, 2)

        // Dragging the slider up never adds room, and at the top it's one element, critical only.
        var previous = Int.max
        for effort in stride(from: 0.0, through: 100, by: 5) {
            engine.effortOverride = effort
            let budget = engine.update(at: t).budget
            XCTAssertLessThanOrEqual(budget.maxElements, previous, "effort \(effort)")
            previous = budget.maxElements
        }
        let top = engine.update(at: t)
        XCTAssertEqual(top.budget.maxElements, 1)
        XCTAssertEqual(top.budget.minPriority, .critical)
        XCTAssertEqual(RunStateFormat.budget(top.budget, situation: top.situation),
                       "room for 1 · critical and up · hard effort")

        // Minimal empties it; Coach gives the element back and one more.
        engine.displaySetting = .minimal
        XCTAssertEqual(RunStateFormat.budget(engine.update(at: t).budget, situation: .hardEffort),
                       "safety only · hard effort")
        engine.displaySetting = .coach
        XCTAssertEqual(engine.update(at: t).budget.maxElements, 2)

        // And a fresh engine keeps the controller's choices.
        let rebuilt = HUDController.makeRunEngine(plan: source.run.plan, display: .coach, effort: 95)
        XCTAssertEqual(rebuilt.displaySetting, .coach)
        XCTAssertEqual(rebuilt.effortOverride, 95)
    }

    func testBudgetTextSaysWhichInputsAreHeldBack() {
        var budget = Budget.steady
        budget.unreliable = [.gps, .heartRate]
        XCTAssertEqual(RunStateFormat.budget(budget, situation: .raceEffort),
                       "room for 2 · advisory and up · steady at race effort · GPS held · HR held")
        XCTAssertEqual(RunStateFormat.budget(.safetyOnly, situation: .kick), "safety only · final kick")
    }
}
