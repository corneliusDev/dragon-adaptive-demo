//  RunEngineFrameTests.swift
//  RunEngine as the coordinator: a step carries a frame only when what is
//  drawn changed, the frame is the renderer's for the step's cue and budget,
//  and a race in kilometres draws kilometres.

import XCTest
import DragonEngine

final class RunEngineFrameTests: XCTestCase {
    private func race(_ profile: SyntheticProfile, unit: DistanceUnit = .miles, display: DisplaySetting = .balanced,
                      until end: TimeInterval = 900) -> [(step: RunEngine.Step, frame: HUDFrame)] {
        var run = SyntheticRun(profile: profile)
        var config = RunEngine.Config(unit: unit)
        config.display = display
        var engine = RunEngine(plan: run.plan, config: config)
        var out: [(RunEngine.Step, HUDFrame)] = []
        while run.time < end {
            for event in run.advance(by: 0.5) { engine.ingest(event) }
            let step = engine.update(at: run.time)
            out.append((step, engine.frame()))
        }
        return out
    }

    func testAStepCarriesAFrameOnlyWhenWhatIsDrawnChanged() {
        let steps = race(.onPlan)
        XCTAssertNotNil(steps.first?.step.frame)                        // the first frame always goes out
        var last: HUDFrame?
        var sent = 0
        for (step, frame) in steps {
            if let new = step.frame {
                XCTAssertEqual(new, frame)
                XCTAssertNotEqual(new.signature, last?.signature)
                last = new
                sent += 1
            } else {
                XCTAssertEqual(frame.signature, last?.signature)         // unchanged: nothing to send
            }
        }
        XCTAssertGreaterThan(sent, 2)                                    // the splits came and went
        XCTAssertLessThan(sent, steps.count / 10)
    }

    func testTheFrameIsTheRenderersForTheStepsCueAndBudget() {
        for (step, frame) in race(.onPlan, display: .minimal) {
            let expected = Renderer.frame(for: step.current, budget: step.budget, state: step.state, unit: .miles)
            XCTAssertEqual(frame, expected, "t=\(step.state.elapsed)")
        }
        // Minimal leaves a steady runner one element: the splits are drawn reduced.
        let splits = race(.onPlan, display: .minimal).filter { $0.step.current?.key.kind == .split }
        XCTAssertFalse(splits.isEmpty)
        for (step, frame) in splits {
            XCTAssertEqual(Renderer.form(for: step.budget), .reduced)
            XCTAssertFalse(frame.ops.contains { if case .rect = $0 { return true } else { return false } })
        }
    }

    func testAKilometreRaceDrawsKilometres() {
        let shown = race(.onPlan, unit: .kilometers, until: 400).first { $0.step.current?.key == .split(kilometer: 1) }
        let texts = shown?.frame.ops.compactMap { op -> String? in
            if case .text(_, _, _, _, _, let s) = op { return s } else { return nil }
        }
        XCTAssertEqual(texts?.first, "KM 1")
    }

    func testEveryFrameOfARaceStaysInsideTheSafeZoneAndTheTextLimits() {
        for profile in SyntheticProfile.all {
            var run = SyntheticRun(profile: profile)
            var engine = RunEngine(plan: run.plan)
            var frames = 0
            while !run.isFinished {
                for event in run.advance(by: 1) { engine.ingest(event) }
                // Only changed frames go out; an unchanged one is the last of these.
                guard let frame = engine.update(at: run.time).frame else { continue }
                frames += 1
                for op in frame.ops where !op.isInsideSafeZone {
                    XCTFail("\(profile.name) t=\(run.time): \(op) outside the safe zone")
                }
                for case .text(_, _, let font, _, _, let s) in frame.ops where s.count > font.maxChars {
                    XCTFail("\(profile.name) t=\(run.time): \(s) over font \(font.rawValue)'s limit")
                }
            }
            XCTAssertGreaterThan(frames, 13, profile.name)
        }
    }
}
