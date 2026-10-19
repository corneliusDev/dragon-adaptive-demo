//  CueLogAppTests.swift
//  The race's cue log in the app: saved to and loaded from a JSON-lines file
//  the way HUDController saves it, and the text the review list and the
//  telemetry row (which replaced the flywheel counter) show.

import XCTest
import DragonEngine
@testable import Dragon_Adaptive

final class CueLogAppTests: XCTestCase {
    /// The first ten minutes of the on-plan race through the controller's engine.
    private func raceLog() -> CueLog {
        let source = SyntheticRaceSource(profile: .onPlan, seed: 42)
        var engine = HUDController.makeRunEngine(plan: source.run.plan, display: .balanced, effort: nil,
                                                 name: "onPlan seed 42")
        source.onSample = { engine.ingest(.location($0)) }
        source.onVitals = { engine.ingest(.vitals($0)) }
        while source.run.time < 600 {
            source.step(by: 0.5)
            engine.update(at: source.run.time)
        }
        return engine.log
    }

    func testCueLogSavesToItsFolderAndLoadsBackUnchanged() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cuelogs-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CueLogStore(directory: dir)
        let log = raceLog()
        XCTAssertEqual(log.header.name, "onPlan seed 42")
        XCTAssertFalse(log.appearances.isEmpty)

        let name = CueLogStore.runName(log.header.name, at: Date(timeIntervalSince1970: 0))
        let url = try store.save(log, name: name)
        XCTAssertEqual(url.pathExtension, "jsonl")
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, dir.standardizedFileURL)
        XCTAssertFalse(url.lastPathComponent.contains(" "))
        XCTAssertEqual(try store.load(url), log)
    }

    func testReviewTextForCountsResponsesAndOutcomes() {
        let log = raceLog()
        let summary = log.summary
        XCTAssertEqual(CueLogFormat.counts(summary), "\(summary.total.shown) shown · \(summary.total.heldBack) held back")
        XCTAssertGreaterThanOrEqual(summary.counts(.split).shown, 1)
        let split = log.appearances.first { $0.cue.key == .split(mile: 1) }
        XCTAssertEqual(split.map { CueLogFormat.content($0.cue.content) }?.prefix(9), "MILE 1 · ")
        XCTAssertEqual(split?.text, "highest priority the budget allows")

        XCTAssertEqual(CueLogFormat.response(.heldLook), "held a look")
        XCTAssertEqual(CueLogFormat.response(nil), "still up")
        XCTAssertEqual(CueLogFormat.outcome(CueOutcome(measure: .paceOffset, shownAt: 100, at: 160, atShow: 0.047,
                                                       after: 0.031, gapAtShow: 28, gapAfter: 29,
                                                       laterAt: 280, gapLater: 4)),
                       "pace +4.7% → +3.1% after 60 s · better · gap +0:28 → +0:29, +0:04 at 180 s")
        XCTAssertEqual(CueLogFormat.outcome(CueOutcome(measure: .paceOffset, shownAt: 100, at: 100, atShow: 0.047,
                                                       after: nil, gapAtShow: 18)),
                       "pace +4.7% · waiting · gap +0:18")
        XCTAssertEqual(CueLogFormat.outcome(CueOutcome(measure: .heartRate, shownAt: 0, at: 60, atShow: 176, after: 171)),
                       "HR 176 → 171 after 60 s · better")
        XCTAssertEqual(CueLogFormat.finish(summary), "not finished · target 1:45:00")
    }
}
