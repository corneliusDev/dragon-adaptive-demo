//  ReviewModel.swift
//  The review screen's state: the result against the target, the splits
//  against the plan, how many cues showed / were held back / were dismissed,
//  every cue that showed with what the runner did and whether it helped, and
//  the one question ("how was the display?"), saved into the run's cue log
//  (CueLog.rate) and written back to its file. Plain Swift, no SwiftUI.

import Foundation
import Observation
import DragonEngine

@Observable
final class ReviewModel {
    /// One cue that showed, for the list.
    struct CueRow: Identifiable, Equatable {
        /// LoggedCue.id.
        var id: Int
        /// "5.6": where along the race, in the plan's unit.
        var marker: String
        /// "Behind plan +0:48", "Fuel", "Mile 3 split".
        var title: String
        /// "seen", "not looked at", "dismissed".
        var response: String
        /// "pace +4.7% → +3.1%, better"; nil for cues without an outcome.
        var outcome: String?
        var improved: Bool?
        var rating: CueRating?
    }

    /// One split bar: seconds against the plan's seconds for the same stretch.
    struct SplitBar: Identifiable, Equatable {
        var marker: Int
        var time: TimeInterval
        var planTime: TimeInterval
        var id: Int { marker }
        var slower: Bool { time > planTime }
    }

    let record: RunRecord
    private(set) var log: CueLog
    private let store: RunStore
    /// Set after a rating is written to the log file; "Saved" on screen.
    private(set) var savedMessage: String?
    private(set) var saveError: String?

    init(record: RunRecord, log: CueLog, store: RunStore) {
        self.record = record
        self.log = log
        self.store = store
    }

    /// Loads the record's cue log from the store.
    convenience init(record: RunRecord, store: RunStore) throws {
        self.init(record: record, log: try store.log(for: record), store: store)
    }

    var unit: DistanceUnit { record.plan.unit }
    var summary: RunSummary { log.summary }

    // MARK: Result

    /// "1:44:29", or "2.4 mi" for a run ended before the line.
    var resultText: String {
        record.finishTime.map(RaceFormat.clock) ?? RaceFormat.distance(record.distance, unit: unit)
    }

    /// "Target 1:45:00 · beat it by 0:31", or "Ended at 1:02:13 · target 1:45:00".
    var targetLine: String {
        if let finish = record.finishTime { return RaceFormat.result(finish: finish, target: record.plan.targetTime) }
        return "Ended at \(RaceFormat.clock(record.endedAt)) · target \(RaceFormat.clock(record.plan.targetTime))"
    }

    var beatTarget: Bool { (record.finishTime ?? .infinity) <= record.plan.targetTime }

    // MARK: Splits

    var splits: [SplitBar] { record.splits.map { SplitBar(marker: $0.marker, time: $0.time, planTime: $0.planTime) } }

    /// "Splits vs plan (8:01)"
    var splitsTitle: String {
        "Splits vs plan (\(RaceFormat.paceValue(perUnit: record.plan.averagePace)))"
    }

    // MARK: Cues

    var shownCount: Int { summary.total.shown }
    var heldBackCount: Int { summary.total.heldBack }
    var dismissedCount: Int { summary.responses[.dismissed] ?? 0 }

    var cueRows: [CueRow] {
        log.appearances.map { e in
            var title = RaceFormat.cueTitle(e.cue.key, content: e.cue.content)
            if e.cue.key == .paceGap, let g = e.state.gap { title += " \(RaceFormat.gap(g))" }
            var response = RaceFormat.response(e.response)
            if e.cue.kind == .fuel, e.response == .glanced || e.response == .heldLook { response = "✓ acknowledged" }
            return CueRow(id: e.cue.id, marker: RaceFormat.marker(e.state.distance, unit: unit), title: title,
                          response: response, outcome: e.outcome.map(RaceFormat.outcome),
                          improved: e.outcome?.improved, rating: e.rating)
        }
    }

    // MARK: The question

    var rating: CueRating? { log.header.rating }

    /// The answer to "how was the display?", into the cue log and its file.
    func rate(_ rating: CueRating) {
        log.rate(rating)
        write("Saved: \(RaceFormat.rating(rating).lowercased())")
    }

    /// A rating for one cue (CueLog.rate(cue:)); the same rating again clears it.
    func rate(cue id: Int, _ rating: CueRating) {
        let current = log.appearances.first { $0.cue.id == id }?.rating
        log.rate(cue: id, current == rating ? nil : rating)
        write("Saved")
    }

    private func write(_ message: String) {
        do {
            try store.saveLog(log, for: record)
            savedMessage = message
            saveError = nil
        } catch {
            saveError = "Couldn't save the rating: \(error.localizedDescription)"
        }
    }

    /// The saved log file, for SHARE and the full log.
    var logURL: URL { store.logURL(for: record) }
}

/// The home screen's lists: saved plans and past runs.
@Observable
final class HomeModel {
    let environment: AppEnvironment
    private(set) var plans: [SavedPlan] = []
    private(set) var runs: [RunRecord] = []
    private(set) var error: String?

    init(environment: AppEnvironment) {
        self.environment = environment
        reload()
    }

    func reload() {
        plans = environment.plans.load()
        runs = environment.runs.load()
    }

    func plan(_ id: UUID) -> SavedPlan? { plans.first { $0.id == id } }
    func run(_ id: UUID) -> RunRecord? { runs.first { $0.id == id } }

    func delete(plan: SavedPlan) {
        do { try environment.plans.delete(plan.id) } catch { self.error = error.localizedDescription }
        reload()
    }

    func delete(run: RunRecord) {
        do { try environment.runs.delete(run) } catch { self.error = error.localizedDescription }
        reload()
    }

    /// A copy of a plan under a new name, to tweak for another race.
    func duplicate(_ plan: SavedPlan) {
        var copy = plan
        copy.id = UUID()
        copy.name = plan.name + " copy"
        copy.updatedAt = Date()
        do { try environment.plans.save(copy) } catch { self.error = error.localizedDescription }
        reload()
    }
}
