//  RunRecord.swift
//  One run done from the main flow: the plan it ran (a copy, so editing the
//  plan later doesn't rewrite history), how it ended, the splits, and the
//  cue log file. RunStore keeps records as JSON (Runs/<id>.json) and the cue
//  logs as JSON lines through CueLogStore, so the review's rating goes back
//  into the same log file that SHARE exports.

import Foundation
import DragonEngine

/// One mile or kilometre marker passed (SplitTrigger.Split, kept).
struct SplitRecord: Codable, Equatable {
    var marker: Int
    /// Seconds for the split, and the plan's seconds for the same stretch.
    var time: TimeInterval
    var planTime: TimeInterval

    init(marker: Int, time: TimeInterval, planTime: TimeInterval) {
        self.marker = marker
        self.time = time
        self.planTime = planTime
    }

    init(_ split: SplitTrigger.Split) {
        self.init(marker: split.marker, time: split.time, planTime: split.planTime)
    }
}

struct RunRecord: Codable, Equatable, Identifiable {
    var id = UUID()
    var plan: SavedPlan
    /// App clock at the start, for the list and the log's file name.
    var startedAt: Date
    /// Run time the runner crossed the line; nil if the run was ended before it.
    var finishTime: TimeInterval?
    /// Run time and metres covered when END was tapped.
    var endedAt: TimeInterval
    var distance: Double
    var splits: [SplitRecord]
    /// File name of the cue log in the store's cue log folder.
    var cueLogFile: String
    /// Where the run's data came from ("Synthetic race"), for the list.
    var source: String

    var finished: Bool { finishTime != nil }

    /// "1:44:29" or "Ended at 2.4 mi".
    var resultText: String {
        finishTime.map(RaceFormat.clock) ?? "Ended at \(RaceFormat.distance(distance, unit: plan.unit))"
    }
}

/// Past runs: records in `runs`, cue logs in `cueLogs` (Documents/CueLogs in the app).
struct RunStore {
    let runs: URL
    let cueLogs: URL

    private var logStore: CueLogStore { CueLogStore(directory: cueLogs) }

    /// Newest first.
    func load() -> [RunRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: runs, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(RunRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    func record(_ id: UUID) -> RunRecord? {
        try? JSONDecoder().decode(RunRecord.self, from: Data(contentsOf: url(id)))
    }

    /// Saves the log (as `record.cueLogFile`) and then the record.
    func save(_ record: RunRecord, log: CueLog) throws {
        try saveLog(log, for: record)
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: url(record.id), options: .atomic)
    }

    func log(for record: RunRecord) throws -> CueLog {
        try logStore.load(logURL(for: record))
    }

    /// Writes the log back (after the review's rating).
    func saveLog(_ log: CueLog, for record: RunRecord) throws {
        try logStore.save(log, name: (record.cueLogFile as NSString).deletingPathExtension)
    }

    func logURL(for record: RunRecord) -> URL { cueLogs.appendingPathComponent(record.cueLogFile) }

    func delete(_ record: RunRecord) throws {
        try? FileManager.default.removeItem(at: logURL(for: record))
        try FileManager.default.removeItem(at: url(record.id))
    }

    private func url(_ id: UUID) -> URL { runs.appendingPathComponent("\(id.uuidString).json") }
}
