//  LiveRunModel.swift
//  The live run screen's state. For now the run's data is a synthetic race
//  generated from the chosen plan (its distance, target, pacing and course,
//  or the synthetic course when none was imported), played at 1x or 10x;
//  chunk 11 swaps in the phone's sensors and chunk 12 the Watch. Everything
//  it sends goes through a RunEngine built from the plan, and the engine's
//  frame goes to the phone mirror and (through `onFrame`) the glasses.
//
//  The model owns race time: a Foundation timer ticks 20 times a second and
//  each tick advances the race by tick × speed, in steps of at most
//  `Config.maxStep` race seconds so the engine sees the race at the rate it
//  would live. Tests call advance(realSeconds:) instead of the timer. After
//  the finish, race time runs on for `Config.afterFinish` so the result shows
//  on the glasses for its 10 s and the display goes dark.
//
//  END saves the cue log and a RunRecord through the RunStore and hands the
//  record to the review. Plain Swift (Observation), no SwiftUI.

import Foundation
import Observation
import DragonEngine

@Observable
final class LiveRunModel {
    struct Config: Equatable {
        /// Seconds between timer ticks (20 frames a second).
        var tick: TimeInterval = 1.0 / 20
        /// Most race seconds per engine update.
        var maxStep: TimeInterval = 0.5
        /// Race seconds the display keeps running after the finish.
        var afterFinish: TimeInterval = 15
        /// Speeds the runner can pick.
        var speeds: [Double] = [1, 10]
        /// Seed for the synthetic race.
        var seed: UInt64 = 42
    }

    /// What the engine is doing, in plain words.
    struct Status: Equatable {
        /// "Showing: behind plan", "Quiet: nothing worth a cue", "Finished in 24:58".
        var headline: String
        /// "Effort moderate · room for 2 cues · steady at race effort".
        var detail: String
    }

    let plan: SavedPlan
    let config: Config
    /// Extra speed from the UI test hook (AppEnvironment.timeScale).
    let timeScale: Double
    /// Where the data comes from, for the screen and the record.
    let sourceName = "Synthetic race"
    /// The synthetic runner's behaviour.
    let profile: SyntheticProfile

    /// 1x or 10x.
    var speed: Double = 1

    private(set) var frame = HUDFrame()
    private(set) var state: RunState?
    private(set) var status = Status(headline: "Ready", detail: "Tap START to begin the race")
    /// "Pace gap: outranked by the mile 3 split": the latest cue held back in this mile/km.
    private(set) var heldBack: String?
    private(set) var hasStarted = false
    /// The timer is running.
    private(set) var isRunning = false
    /// Run time the runner crossed the line.
    private(set) var finishTime: TimeInterval?
    /// Cues that have gone on screen so far.
    private(set) var cuesShown = 0
    /// The finished record, once END has saved it.
    private(set) var record: RunRecord?

    /// Each new frame, for the glasses.
    @ObservationIgnored var onFrame: ((HUDFrame) -> Void)?

    @ObservationIgnored private(set) var engine: RunEngine
    @ObservationIgnored private var run: SyntheticRun
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var afterFinish: TimeInterval = 0
    @ObservationIgnored private var finishSent = false
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var heldBackMarker = 0

    init(plan: SavedPlan, profile: SyntheticProfile = .onPlan, timeScale: Double = 1, config: Config = Config()) {
        self.plan = plan
        self.profile = profile
        self.timeScale = timeScale
        self.config = config
        let runPlan = plan.runPlan
        run = SyntheticRun(profile: profile, seed: config.seed, plan: runPlan)
        var engineConfig = RunEngine.Config(unit: plan.unit)
        engineConfig.display = plan.display
        engineConfig.name = plan.name
        // The synthetic race fills in the synthetic course when the plan has none.
        engine = RunEngine(plan: run.plan, config: engineConfig)
    }

    deinit { timer?.invalidate() }

    /// Race run time: the run's own until the finish, then counting on.
    var raceTime: TimeInterval { run.time + afterFinish }
    var isFinished: Bool { finishTime != nil }
    var unit: DistanceUnit { plan.unit }

    // MARK: Controls

    /// The gun: the engine sees the runner at the line, then the clock runs.
    /// `timer: false` (tests) leaves advancing to advance(realSeconds:).
    func start(timer useTimer: Bool = true) {
        guard !hasStarted else { return resume(timer: useTimer) }
        hasStarted = true
        startedAt = Date()
        for event in run.advance(by: 0) { engine.ingest(event) }
        publish(engine.update(at: 0))
        resume(timer: useTimer)
    }

    func pause() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    func resume(timer useTimer: Bool = true) {
        guard hasStarted, !isRunning else { return }
        isRunning = true
        guard useTimer else { return }
        let t = Timer(timeInterval: config.tick, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.advance(realSeconds: self.config.tick)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func togglePause() { isRunning ? pause() : resume() }

    /// A glance or held look from the glasses (or the developer LOOK button).
    func receive(_ event: AttentionEvent) {
        guard hasStarted, !isFinished else { return }
        engine.ingest(.attention(AttentionSample(t: raceTime, event: event)))
    }

    /// Advances the race by `realSeconds` × speed (× the test time scale).
    func advance(realSeconds: TimeInterval) {
        guard isRunning else { return }
        var remaining = realSeconds * speed * timeScale
        var last: RunEngine.Step?
        while remaining > 1e-9 {
            if isFinished && afterFinish >= config.afterFinish { break }
            let dt = min(remaining, config.maxStep)
            remaining -= dt
            if run.isFinished {
                afterFinish = min(afterFinish + dt, config.afterFinish)
            } else {
                for event in run.advance(by: dt) { engine.ingest(event) }
            }
            if run.isFinished && !finishSent, let crossed = run.finishTime {
                finishSent = true
                engine.finish(at: crossed)
                finishTime = crossed
            }
            last = engine.update(at: raceTime)
            if let step = last { noteHeldBack(step) }
        }
        if let last { publish(last) }
        if isFinished && afterFinish >= config.afterFinish { pause() }
    }

    /// Stops the run, saves its cue log and record, and returns the record.
    @discardableResult
    func end(store: RunStore) throws -> RunRecord {
        pause()
        if let record { return record }
        let log = engine.log
        let fileName = CueLogStore.fileName(CueLogStore.runName(plan.name, at: startedAt))
        let r = RunRecord(plan: plan, startedAt: startedAt, finishTime: finishTime, endedAt: raceTime,
                          distance: state?.distance ?? 0,
                          splits: engine.split.splits.map(SplitRecord.init),
                          cueLogFile: fileName, source: sourceName)
        try store.save(r, log: log)
        record = r
        return r
    }

    // MARK: Read-outs

    var elapsedText: String { RaceFormat.clock(finishTime ?? state?.elapsed ?? 0) }
    var distanceText: String { RaceFormat.distanceValue(min(state?.distance ?? 0, plan.distanceMeters), unit: unit) }
    var heartText: String { state?.heartRate.map { "\(Int($0.rounded()))" } ?? "—" }
    var projectedText: String { (finishTime ?? state?.projectedFinish).map(RaceFormat.clock) ?? "—" }
    /// Projected (or actual) finish − target: + = behind.
    var gap: TimeInterval? {
        if let f = finishTime { return f - plan.targetTime }
        return state?.gapToTarget
    }
    var gapText: String { gap.map(RaceFormat.gap) ?? "—" }
    /// Behind by at least a second (what "+0:01" shows).
    var isBehind: Bool { (gap ?? 0).rounded() > 0 }
    /// "MILE 10.5" / "KM 16.9"; "FINISHED" after the line.
    var positionText: String {
        if isFinished { return "FINISHED" }
        let d = min(state?.distance ?? 0, plan.distanceMeters)
        return "\(unit == .miles ? "MILE" : "KM") \(RaceFormat.marker(d, unit: unit))"
    }

    // MARK: Private

    private func publish(_ step: RunEngine.Step) {
        state = step.state
        let drawn = engine.frame()
        if drawn.signature != frame.signature {
            frame = drawn
            onFrame?(drawn)
        }
        cuesShown = engine.log.appearances.count
        status = Self.status(step: step, current: engine.current, finishTime: finishTime)
    }

    /// The latest cue held back, kept until the runner reaches the next marker.
    private func noteHeldBack(_ step: RunEngine.Step) {
        let marker = Int(step.state.distance / unit.meters)
        if marker != heldBackMarker {
            heldBackMarker = marker
            heldBack = nil
        }
        // Arbiter.decided[i] is the cue decisions[i] is about.
        let cues = engine.arbiter.decided
        guard let i = step.decisions.lastIndex(where: { $0.outcome == .heldBack }), i < cues.count else { return }
        let d = step.decisions[i]
        heldBack = "\(RaceFormat.cueTitle(d.key, content: cues[i].content)): \(d.text)"
    }

    static func status(step: RunEngine.Step, current: Cue?, finishTime: TimeInterval?) -> Status {
        let b = step.budget
        let room = b.isEmpty ? "safety cues only" : (b.maxElements == 1 ? "room for 1 cue" : "room for \(b.maxElements) cues")
        let detail = "Effort \(step.state.effort.label.lowercased()) · \(room) · \(step.situation.label)"
        let headline: String
        if let current {
            headline = "Showing: \(RaceFormat.cueTitle(current.key, content: current.content).lowercased())"
        } else if let finishTime {
            headline = "Finished in \(RaceFormat.clock(finishTime))"
        } else {
            headline = "Quiet: nothing worth a cue"
        }
        return Status(headline: headline, detail: detail)
    }
}
