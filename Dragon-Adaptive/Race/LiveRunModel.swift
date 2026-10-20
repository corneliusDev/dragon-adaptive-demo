//  LiveRunModel.swift
//  The live run screen's state. The run's data comes from one of three feeds:
//
//      synthetic  a synthetic race generated from the chosen plan (its
//                 distance, target, pacing and course, or the synthetic
//                 course when none was imported), played at 1x or 10x.
//      phone      the phone's own sensors (PhoneSensorRun: GPS, motion,
//                 pedometer, barometer) on a real run, in real time.
//      replay     a real run's RunRecording played back at 1x or 10x.
//
//  Everything goes through a RunEngine built from the plan, and the engine's
//  presented frame (cues eased on and off by the plan's segue, its heads-ups
//  drawn, the LED op included) goes to the phone mirror and (through
//  `onFrame`) the glasses, each frame once. A heads-up starting with the
//  plan's Watch tap on goes to `haptics` (the Watch, light or strong by the
//  coming cue's priority).
//
//  Synthetic: the model owns race time. A Foundation timer ticks 20 times a
//  second and each tick advances the race by tick × speed, in steps of at
//  most `Config.maxStep` race seconds so the engine sees the race at the rate
//  it would live. Tests call advance(realSeconds:) instead of the timer.
//  After the finish, race time runs on for `Config.afterFinish` so the result
//  shows on the glasses for its 10 s and the display goes dark.
//
//  Phone and replay: a RunPacer updates the engine on a fixed grid of run
//  time (four times a second), the phone's a couple of seconds behind the
//  sensors so late readings make it. Each sensor reading also nudges the
//  pacer, so the run keeps going with the screen locked even if the timer
//  doesn't fire. A phone run records every input the engine takes; a replay
//  plays a recording on the grid it was made on, so it decides exactly as
//  the run did. A real run finishes when the engine's distance reaches the
//  plan's.
//
//  A phone run's heart rate comes from the Watch, the synthetic Watch or
//  nowhere (HeartSource, on the sensors). With the Watch, START also starts
//  the Watch workout and END ends it; ending the workout on the Watch sets
//  `endedOnWatch`, and the live screen ends the run as if END were tapped.
//
//  END saves the cue log and a RunRecord through the RunStore (and, for a
//  phone run, its recording) and hands the record to the review. Plain Swift
//  (Observation), no SwiftUI.

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
        /// Engine update grid and sensor lag for phone runs (replays use the recording's grid).
        var pacer = RunPacer.Config()
    }

    /// Where the run's data comes from.
    enum Feed {
        case synthetic(SyntheticProfile)
        case phone(PhoneSensorRun)
        /// A recording, with a label for the screen ("Park 5K, 18 Oct").
        case replay(RunRecording, label: String)
    }

    enum Kind: Equatable {
        case synthetic, phone, replay
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
    let kind: Kind
    /// Where the data comes from, for the screen and the record.
    let sourceName: String
    /// The synthetic runner's behaviour (synthetic runs).
    let profile: SyntheticProfile?
    /// The phone's sensors (phone runs).
    let sensors: PhoneSensorRun?
    /// What the phone run may use, and the explanations (phone runs).
    let permissions: SensorPermissions?

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
    /// "GPS ±5 m · 312 fixes · motion, cadence, altitude" (phone runs).
    private(set) var sensorText: String?
    /// The Watch workout was ended on the Watch: the run should end too.
    private(set) var endedOnWatch = false

    /// Each new frame, for the glasses.
    @ObservationIgnored var onFrame: ((HUDFrame) -> Void)?
    /// Where the Watch-tap heads-up goes (the plan's Watch tap on).
    @ObservationIgnored var haptics: HeadsUpHaptics?

    @ObservationIgnored private(set) var engine: RunEngine
    @ObservationIgnored private var run: SyntheticRun?
    /// Phone and replay: the update grid, and what a phone run has recorded.
    @ObservationIgnored private(set) var pacer: RunPacer
    @ObservationIgnored private(set) var recorder: RunRecorder?
    @ObservationIgnored private var replay: ReplaySource?
    /// Replay: run time played so far, and where the recording ends.
    @ObservationIgnored private var replayTime: TimeInterval = 0
    @ObservationIgnored private var replayEnd: TimeInterval = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var afterFinish: TimeInterval = 0
    @ObservationIgnored private var finishSent = false
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var heldBackMarker = 0

    convenience init(plan: SavedPlan, profile: SyntheticProfile = .onPlan, timeScale: Double = 1,
                     config: Config = Config(), segueConfig: SegueConfig = SegueConfig()) {
        self.init(plan: plan, feed: .synthetic(profile), timeScale: timeScale, config: config, segueConfig: segueConfig)
    }

    /// `segueConfig`: the app-wide segue tuning (the plan picks the segue and heads-ups).
    init(plan: SavedPlan, feed: Feed, timeScale: Double = 1, config: Config = Config(),
         segueConfig: SegueConfig = SegueConfig()) {
        self.plan = plan
        self.timeScale = timeScale
        self.config = config
        let engineConfig = LiveRunModel.engineConfig(for: plan, segues: segueConfig)
        switch feed {
        case .synthetic(let profile):
            kind = .synthetic
            sourceName = "Synthetic race"
            self.profile = profile
            sensors = nil
            permissions = nil
            let synthetic = SyntheticRun(profile: profile, seed: config.seed, plan: plan.runPlan)
            run = synthetic
            pacer = RunPacer(config: config.pacer)
            // The synthetic race fills in the synthetic course when the plan has none.
            engine = RunEngine(plan: synthetic.plan, config: engineConfig)
        case .phone(let sensors):
            kind = .phone
            sourceName = "Phone sensors"
            profile = nil
            self.sensors = sensors
            permissions = SensorPermissions(sensors.providers)
            pacer = RunPacer(config: config.pacer)
            recorder = RunRecorder(name: plan.name, plan: plan.runPlan, unit: plan.unit, display: plan.display)
            engine = RunEngine(plan: plan.runPlan, config: engineConfig)
        case .replay(let recording, let label):
            kind = .replay
            sourceName = "Replay: \(label)"
            profile = nil
            sensors = nil
            permissions = nil
            replay = ReplaySource(recording)
            replayEnd = recording.endedAt ?? recording.duration
            pacer = RunPacer(config: RunPacer.Config(step: recording.updateStep ?? config.pacer.step, lag: 0))
            engine = RunEngine(plan: recording.plan ?? plan.runPlan, config: engineConfig)
        }
    }

    deinit {
        timer?.invalidate()
        sensors?.stop()
    }

    /// The engine's settings for a plan: its unit, display setting, name,
    /// segue and heads-ups (with the app's segue tuning). A replay uses the
    /// same, so it decides as the run did.
    static func engineConfig(for plan: SavedPlan, segues: SegueConfig = SegueConfig()) -> RunEngine.Config {
        var c = RunEngine.Config(unit: plan.unit)
        c.display = plan.display
        c.name = plan.name
        c.segue = plan.segue
        c.headsUp = plan.headsUp
        c.segues = segues
        return c
    }

    /// Race run time: synthetic, the run's own until the finish, then
    /// counting on; phone and replay, the engine's latest update.
    var raceTime: TimeInterval {
        if let run { return run.time + afterFinish }
        return pacer.lastUpdate ?? 0
    }
    /// Where a phone run's heart rate comes from; nil for other runs.
    var heartSource: HeartSource? { sensors?.heartSource }
    /// 1x / 10x applies (not to a real run).
    var hasSpeeds: Bool { kind != .phone }
    var isFinished: Bool { finishTime != nil }
    var unit: DistanceUnit { plan.unit }

    // MARK: Controls

    /// The gun: the engine sees the runner at the line, then the clock runs.
    /// `timer: false` (tests) leaves advancing to advance(realSeconds:).
    /// A phone run needs location: without it, nothing starts (the screen
    /// shows why, and offers synthetic data).
    func start(timer useTimer: Bool = true) {
        guard !hasStarted else { return resume(timer: useTimer) }
        if kind == .phone && !(permissions?.canRun ?? false) {
            permissions?.prepare()
            return
        }
        hasStarted = true
        startedAt = Date()
        switch kind {
        case .synthetic:
            for event in run?.advance(by: 0) ?? [] { engine.ingest(event) }
            let step = engine.update(at: 0)
            noteHeadsUp(step)
            publish(step)
        case .phone:
            status = Status(headline: "Starting", detail: "Waiting for the first GPS fix")
            sensors?.onEvent = { [weak self] event in self?.received(event) }
            sensors?.onEndedRemotely = { [weak self] in self?.endedOnWatch = true }
            sensors?.start()
            sensorText = sensors?.summary
        case .replay:
            advanceReplay(by: 0)
        }
        resume(timer: useTimer)
    }

    func pause() {
        timer?.invalidate()
        timer = nil
        if isRunning { sensors?.pause() }
        isRunning = false
    }

    func resume(timer useTimer: Bool = true) {
        guard hasStarted, !isRunning else { return }
        isRunning = true
        if kind == .phone { sensors?.resume() }
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
        switch kind {
        case .synthetic:
            engine.ingest(.attention(AttentionSample(t: raceTime, event: event)))
        case .phone:
            // Held by the pacer like any input, so the recording replays it.
            pacer.receive(.attention(AttentionSample(t: sensors?.runTime ?? 0, event: event)))
        case .replay:
            break   // the recording has the run's own
        }
    }

    /// Advances the race by `realSeconds` × speed (× the test time scale).
    /// A phone run follows the sensors' clock instead: it runs every update due.
    func advance(realSeconds: TimeInterval) {
        guard isRunning else { return }
        switch kind {
        case .synthetic: advanceSynthetic(realSeconds: realSeconds)
        case .phone: advancePhone()
        case .replay: advanceReplay(by: realSeconds * speed * timeScale)
        }
    }

    private func advanceSynthetic(realSeconds: TimeInterval) {
        // run is mutated in place (run?.…), never copied out: it's a big value.
        guard run != nil else { return }
        var remaining = realSeconds * speed * timeScale
        var last: RunEngine.Step?
        while remaining > 1e-9 {
            if isFinished && afterFinish >= config.afterFinish { break }
            let dt = min(remaining, config.maxStep)
            remaining -= dt
            if run?.isFinished == true {
                afterFinish = min(afterFinish + dt, config.afterFinish)
            } else {
                for event in run?.advance(by: dt) ?? [] { engine.ingest(event) }
            }
            if run?.isFinished == true && !finishSent, let crossed = run?.finishTime {
                finishSent = true
                engine.finish(at: crossed)
                finishTime = crossed
            }
            last = engine.update(at: raceTime)
            if let step = last {
                noteHeldBack(step)
                noteHeadsUp(step)
            }
        }
        if let last { publish(last) }
        if isFinished && afterFinish >= config.afterFinish { pause() }
    }

    /// A reading from the phone: held for its update, and a nudge to run what's due.
    private func received(_ event: RunEvent) {
        pacer.receive(event)
        if isRunning { advancePhone() }
    }

    private func advancePhone() {
        guard let sensors else { return }
        runPacer(to: sensors.runTime)
        sensorText = sensors.summary
    }

    private func advanceReplay(by dt: TimeInterval) {
        guard let replay else { return }
        replayTime = min(replayTime + dt, replayEnd)
        for event in replay.samples(until: replayTime) { pacer.receive(event) }
        runPacer(to: replayTime)
        if replayTime >= replayEnd { pause() }
    }

    /// Runs the pacer's due updates (recording what a phone run's engine takes)
    /// and shows the latest.
    private func runPacer(to now: TimeInterval) {
        var last: RunEngine.Step?
        while let update = pacer.nextUpdate(by: now) {
            for event in update.inputs {
                engine.ingest(event)
                recorder?.record(event)
            }
            let step = engine.update(at: update.t)
            noteHeldBack(step)
            noteHeadsUp(step)
            last = step
        }
        if finishTime == nil, let crossed = engine.log.header.finishTime { finishTime = crossed }
        if let last { publish(last) }
    }

    /// Stops the run, saves its cue log and record, and returns the record.
    @discardableResult
    func end(store: RunStore) throws -> RunRecord {
        pause()
        sensors?.stop()
        if let record { return record }
        let log = engine.log
        let runName = CueLogStore.runName(plan.name, at: startedAt)
        let fileName = CueLogStore.fileName(runName)
        var r = RunRecord(plan: plan, startedAt: startedAt, finishTime: finishTime, endedAt: raceTime,
                          distance: state?.distance ?? 0,
                          splits: engine.split.splits.map(SplitRecord.init),
                          cueLogFile: fileName, source: sourceName)
        if let recorder, hasStarted {
            recorder.noteUpdates(step: pacer.config.step, through: pacer.lastUpdate ?? 0)
            r.recordingFile = try store.saveRecording(recorder.recording, name: runName)
        }
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
        // What the glasses show now: mid-segue frames and the heads-up included.
        let drawn = engine.presentedFrame
        if drawn.signature != frame.signature {
            frame = drawn
            onFrame?(drawn)
        }
        cuesShown = engine.log.appearances.count
        status = Self.status(step: step, current: engine.current, finishTime: finishTime)
    }

    /// A heads-up starting with the plan's Watch tap on: tap the wrist (not on a replay).
    private func noteHeadsUp(_ step: RunEngine.Step) {
        guard kind != .replay, step.headsUpBegan, let signal = step.headsUp, plan.headsUp.contains(.watchTap) else { return }
        haptics?.headsUp(signal)
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
