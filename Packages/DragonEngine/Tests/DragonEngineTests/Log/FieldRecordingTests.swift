//  FieldRecordingTests.swift
//  Real runs replayed through the engine: every recording in
//  Fixtures/field (a RunRecording .json with its cue log .jsonl beside it,
//  copied off the phone) must give the cues its log says the run gave.
//  The same check runs on a recording made here by a RunPacer, so the
//  comparison itself is always exercised.

import XCTest
import DragonEngine

final class FieldRecordingTests: XCTestCase {
    private var fieldFolder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/field")
    }

    /// Recording / cue log pairs in `folder`, by base name.
    private func pairs(in folder: URL) throws -> [(recording: URL, log: URL)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.compactMap { json in
            let log = json.deletingPathExtension().appendingPathExtension("jsonl")
            return FileManager.default.fileExists(atPath: log.path) ? (json, log) : nil
        }
    }

    /// Replays the recording and compares with the saved log (the runner's
    /// rating, added at the review, isn't the engine's).
    private func check(recording url: URL, log logURL: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let recording = try RunRecording(jsonData: Data(contentsOf: url))
        let saved = try CueLog(jsonLines: Data(contentsOf: logURL))
        let replayed = RunEngine.replay(recording).log
        XCTAssertEqual(replayed.events, saved.events, "\(url.lastPathComponent): cues differ", file: file, line: line)
        XCTAssertEqual(replayed.header.finishTime, saved.header.finishTime, url.lastPathComponent, file: file, line: line)
        XCTAssertEqual(replayed.header.name, saved.header.name, file: file, line: line)
    }

    func testFieldRecordingsReplayWithTheirCues() throws {
        for pair in try pairs(in: fieldFolder) {
            try check(recording: pair.recording, log: pair.log)
        }
    }

    /// The harness on a recording made the way the app makes one.
    func testTheCheckPassesForAPacedRecordingAndCatchesADifferentOne() throws {
        let plan = RunPlan(distanceMeters: 3_000, targetTime: 900)
        let source = syntheticRecording(.slowFade(from: 1_000), seed: 4, plan: plan)
        let recorder = RunRecorder(name: "field check", plan: plan, unit: .kilometers, display: .coach)
        var config = RunEngine.Config(unit: .kilometers)
        config.name = "field check"
        config.display = .coach
        var engine = RunEngine(plan: plan, config: config)
        var pacer = RunPacer()
        for e in source.events { pacer.receive(e) }
        pacer.advance(to: source.duration + 30, engine: &engine, ingested: recorder.record)
        recorder.noteUpdates(step: pacer.config.step, through: pacer.lastUpdate ?? 0)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("field-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try recorder.recording.jsonData().write(to: folder.appendingPathComponent("run.json"))
        try engine.log.jsonLines().write(to: folder.appendingPathComponent("run.jsonl"))
        let found = try pairs(in: folder)
        XCTAssertEqual(found.count, 1)
        try check(recording: found[0].recording, log: found[0].log)

        // A different display setting decides differently: the check would see it.
        var other = recorder.recording
        other.display = .minimal
        XCTAssertNotEqual(RunEngine.replay(other).log.events, engine.log.events)
    }
}
