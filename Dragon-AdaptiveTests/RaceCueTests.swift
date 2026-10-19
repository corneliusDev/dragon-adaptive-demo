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
}
