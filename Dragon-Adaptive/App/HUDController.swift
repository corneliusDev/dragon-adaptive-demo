//  HUDController.swift
//  Orchestrates engine + attention + motion + glasses. Drives a 20fps loop,
//  pushes frames to the glasses when connected and to the on-phone mirror.
//
//  Live HUD version:
//  - Calibration is OFF, so the display moves again.
//  - Sends a short BLE OK test pattern after connect.
//  - Then hands off to the adaptive HUD.
//  - Forces redraws on gesture, reset, scenario change, and run toggle.
//
//  The engine is clock-free: this controller owns run time (monotonic seconds
//  since launch) and passes it to every engine call.
//
//  Two pipelines: with a RunPlan loaded (a synthetic race, the RACE source) the
//  plan-driven RunEngine decides what to show, from race run time; otherwise
//  today's scenario AdaptiveEngine does. In the race the effort slider stands
//  in for the measured effort in the capacity budget (drag it up and the
//  display gets sparser), and the Minimal / Balanced / Coach setting shifts it.
//  The race's cue log (every arbiter decision, the runner's responses and the
//  outcomes) replaces the flywheel count in RACE mode; when the race finishes
//  race time keeps running (at the race speed) so the result shows on the
//  glasses for its 10 s and the display goes dark; then the log is saved to
//  Documents/CueLogs as JSON lines and the review list opens.
//
//  Segues (chunk 14): the race sends RunEngine's presented frame (cues eased
//  on and off, heads-ups drawn) rather than its target; the Segue / HeadsUp
//  settings come from SegueSettingsStore and follow it when it changes; a
//  heads-up with .watchTap on goes to `haptics` (a no-op until chunk 12).

import Foundation
import Combine
import SwiftUI
import DragonEngine

enum VitalsMode {
    case manual      // motion slider; HR estimated from motion
    case synthetic   // SyntheticVitalsSource stands in for the Apple Watch
    case race        // SyntheticRaceSource: a whole race, GPS + watch
}

final class HUDController: ObservableObject {
    @Published var connection: ConnectionState = .idle
    @Published var frame = HUDFrame()
    /// The motion slider (0–100): the legacy demos' motion input.
    @Published var motion: Double = 0
    @Published var running = false
    @Published var scenarioKey = "tri"
    @Published var flywheel = 0
    @Published var bandLabel = "STATIONARY"
    @Published var attnLabel = "○ IDLE"
    @Published var ctxLabel = "—"
    @Published var vitalsMode: VitalsMode = .synthetic
    @Published var vitalsLabel = "—"

    // Synthetic race
    @Published var raceProfile: SyntheticProfile = .designWalkthrough
    @Published var raceSpeed: Double = 1
    @Published var racePlaying = false
    @Published var raceLabel = "—"
    /// What the state estimator makes of the race so far (debug overlay).
    @Published var raceState: RunState?
    /// The arbiter's latest decisions (the last step that had any), for the overlay.
    @Published var raceDecisions: [Decision] = []
    @Published var showStateOverlay = true
    /// What the arbiter was allowed to show on the latest step, and why (overlay).
    @Published var raceBudget: Budget?
    @Published var raceSituation: Capacity.Situation?
    /// Minimal / Balanced / Coach for the race pipeline.
    @Published var displaySetting: DisplaySetting = .balanced {
        didSet { runEngine.displaySetting = displaySetting }
    }
    /// A screen from the gallery held on the mirror and the glasses in place of
    /// the live HUD; nil = live.
    @Published private(set) var galleryFrame: HUDFrame?
    /// A run from the main flow (LiveRunModel) drawing the glasses in place of
    /// this controller's own pipelines; nil = the controller's own.
    @Published private(set) var runFrame: HUDFrame?
    /// Every glance or held look (glasses gesture or the LOOK button), for the
    /// main flow's live run.
    var onAttention: ((AttentionEvent) -> Void)?
    /// The race's cue log so far.
    @Published private(set) var raceLog: CueLog?
    /// Where the race's cue log was last saved; nil until it has been.
    @Published private(set) var raceLogURL: URL?
    /// The review list is open (set when a race finishes, or by CUE LOG).
    @Published var showCueLog = false
    /// The slider's effort (0–100) in place of the measured one, once dragged in a race; nil = measured.
    @Published var effortOverride: Double? {
        didSet { runEngine.effortOverride = effortOverride }
    }

    /// Segue, heads-up and tuning, persisted; the race engine follows it.
    let segueSettings: SegueSettingsStore
    /// Where the Watch-tap heads-up goes (no-op until chunk 12).
    var haptics: HeadsUpHaptics = NoHeadsUpHaptics()
    private var segueSubscription: AnyCancellable?

    private let engine = AdaptiveEngine(scenario: Scenarios.cyclingTri)
    private let session = GlassesSession()
    private let sim = SimulatedAttentionSource()
    private let synthetic = SyntheticVitalsSource()
    private let race = SyntheticRaceSource()

    // Race pipeline: everything the race's GPS and watch sent goes through the
    // RunEngine (estimator → triggers → arbiter), updated at race run time.
    private lazy var runEngine = HUDController.makeRunEngine(plan: race.run.plan, display: displaySetting,
                                                             effort: effortOverride,
                                                             name: "\(race.profile.name) seed \(race.seed)",
                                                             segues: segueSettings.settings)
    private var raceStarted = false
    private var raceLogSaved = false
    /// Told the engine the runner crossed the line.
    private var raceFinishSent = false
    /// Race seconds since the synthetic run finished (it stops sending there).
    private var raceAfterFinish: TimeInterval = 0
    /// Race seconds after the finish before the review opens: the result's 10 s, then a moment of dark.
    private let reviewDelay: TimeInterval = 12
    /// Race run time: the run's own until it finishes, then counting on.
    private var raceTime: TimeInterval { race.run.time + raceAfterFinish }
    private var raceStartDate = Date()
    private let logStore = CueLogStore.documents

    // HR older than this is treated as missing and the engine falls back to its estimate.
    private let hrStaleAfter: TimeInterval = 5
    private var lastHR: Double?
    private var lastHRAt: TimeInterval = -.infinity   // run time of the last HR reading

    // Monotonic run time handed to the engine.
    private let launchUptime = ProcessInfo.processInfo.systemUptime
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime - launchUptime }

    private var gesture: GestureAttentionSource?
    private var backend: GlassesBackend?
    private var timer: Timer?

    // Keep this false for live HUD motion.
    // Change to true only when you want to freeze the glasses on the calibration pattern.
    private let showCalibrationOnConnect = false

    init(segueSettings: SegueSettingsStore = SegueSettingsStore()) {
        print("[HUDController] init")
        self.segueSettings = segueSettings
        segueSubscription = segueSettings.$settings.dropFirst().sink { [weak self] settings in
            self?.applySegueSettings(settings)
        }

        sim.onEvent = { [weak self] event in
            print("[HUDController] simulated attention event: \(event)")
            guard let self = self else { return }
            self.engine.handle(event, at: self.now)
            self.receiveRaceAttention(event)
            self.onAttention?(event)
            self.backend?.invalidate()
        }
        sim.start()

        synthetic.onSample = { [weak self] sample in
            self?.receive(sample)
        }

        race.onVitals = { [weak self] sample in
            guard let self = self else { return }
            self.receive(sample)
            self.runEngine.ingest(.vitals(sample))
            self.raceStarted = true
        }
        race.onSample = { [weak self] fix in
            guard let self = self else { return }
            self.runEngine.ingest(.location(fix))
            self.raceStarted = true
        }
        race.onAttention = { [weak self] sample in
            guard let self = self else { return }
            print("[HUDController] race attention: \(sample.event) at \(Int(sample.t)) s")
            self.runEngine.ingest(.attention(sample))
        }

        engine.onFlywheel = { [weak self] n in
            DispatchQueue.main.async {
                self?.flywheel = n
            }
        }

        session.onState = { [weak self] state in
            DispatchQueue.main.async {
                print("[HUDController] connection state: \(state.label)")
                self?.connection = state
            }
        }

        session.onConnected = { [weak self] glasses in
            guard let self = self else { return }

            print("[HUDController] onConnected: \(glasses.name)")

            let backend = GlassesBackend(glasses: glasses)
            backend.partialRedraw = self.segueSettings.settings.partialRedraw
            self.backend = backend

            let gesture = GestureAttentionSource(glasses: glasses)
            gesture.onEvent = { [weak self] event in
                print("[HUDController] glasses gesture event: \(event)")
                guard let self = self else { return }
                self.engine.handle(event, at: self.now)
                self.receiveRaceAttention(event)
                self.onAttention?(event)
                self.backend?.invalidate()
            }
            gesture.start()
            self.gesture = gesture

            if self.showCalibrationOnConnect {
                backend.sendCalibrationPattern()
                print("[HUDController] holding calibration pattern. Set showCalibrationOnConnect = false to run HUD.")
            } else {
                backend.sendTestPattern()
                backend.invalidate()

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) {
                    print("[HUDController] engine taking over display after test pattern")
                    self.backend?.invalidate()
                    self.pushImmediateFrame()
                }
            }
        }

        startLoop()
    }

    deinit {
        print("[HUDController] deinit")
        timer?.invalidate()
        synthetic.stop()
        race.stop()
        gesture?.stop()
        session.disconnect()
    }

    // MARK: - Controls

    func connect() {
        print("[HUDController] connect tapped")
        session.connect()
    }

    func disconnect() {
        print("[HUDController] disconnect tapped")

        gesture?.stop()
        gesture = nil

        backend?.invalidate()
        backend = nil

        session.disconnect()
    }

    func glance() {
        print("[HUDController] glance tapped")
        sim.fire(.glance)
        backend?.invalidate()
        pushImmediateFrame()
    }

    func dwell() {
        print("[HUDController] dwell triggered")
        sim.fire(.dwell)
        backend?.invalidate()
        pushImmediateFrame()
    }

    func toggleRun() {
        running.toggle()
        engine.running = running
        syncSynthetic()
        backend?.invalidate()
        print("[HUDController] running: \(running)")
    }

    func reset() {
        print("[HUDController] reset")

        engine.reset()
        running = false
        resetVitals()

        backend?.invalidate()
        pushImmediateFrame()
    }

    func setScenario(_ key: String) {
        print("[HUDController] set scenario: \(key)")

        scenarioKey = key
        engine.setScenario(key == "sof" ? Scenarios.operatorSOF : Scenarios.cyclingTri)

        running = false
        resetVitals()

        backend?.invalidate()
        pushImmediateFrame()
    }

    func setVitalsMode(_ mode: VitalsMode) {
        print("[HUDController] vitals mode: \(mode)")

        vitalsMode = mode
        resetVitals()
        syncSynthetic()
        pushImmediateFrame()
    }

    // MARK: - Synthetic race

    func setRaceProfile(_ profile: SyntheticProfile) {
        print("[HUDController] race profile: \(profile.name)")
        raceProfile = profile
        resetRace()
    }

    func setRaceSpeed(_ speed: Double) {
        raceSpeed = speed
        race.speed = speed
    }

    func toggleRace() {
        if race.isStreaming {
            race.stop()
        } else {
            if race.run.isFinished { resetRace() }
            if vitalsMode != .race { setVitalsMode(.race) }
            race.speed = raceSpeed
            race.start()
            // The gun: the engine sees the runner standing at the line before the race clock moves.
            pushImmediateFrame()
        }
        racePlaying = race.isStreaming
    }

    func resetRace() {
        race.reset(profile: raceProfile)
        racePlaying = false
        runEngine = HUDController.makeRunEngine(plan: race.run.plan, display: displaySetting, effort: effortOverride,
                                                name: "\(raceProfile.name) seed \(race.seed)",
                                                segues: segueSettings.settings)
        raceStarted = false
        raceLogSaved = false
        raceFinishSent = false
        raceAfterFinish = 0
        raceStartDate = Date()
        raceLog = nil
        raceLogURL = nil
        raceState = nil
        raceDecisions = []
        raceBudget = nil
        raceSituation = nil
        raceLabel = "—"
    }

    func toggleStateOverlay() {
        showStateOverlay.toggle()
    }

    // MARK: - Screen gallery

    /// Holds `frame` on the mirror and sends it to the glasses (if connected)
    /// until resumeLiveHUD().
    func showOnGlasses(_ frame: HUDFrame) {
        print("[HUDController] gallery frame with \(frame.ops.count) ops")
        galleryFrame = frame
        backend?.invalidate()
        pushImmediateFrame()
    }

    /// Holds `frame` in place of the live HUD like showOnGlasses, but as one
    /// frame of an animation (the segue preview): the glasses get only what
    /// changed, not a forced full redraw.
    func present(_ frame: HUDFrame) {
        galleryFrame = frame
        pushImmediateFrame()
    }

    /// The race engine follows the segue settings as they change.
    private func applySegueSettings(_ settings: SegueSettingsStore.Settings) {
        runEngine.segue = settings.segue
        runEngine.headsUp = settings.headsUp
        runEngine.segueConfig = settings.config
        backend?.partialRedraw = settings.partialRedraw
    }

    func resumeLiveHUD() {
        guard galleryFrame != nil else { return }
        galleryFrame = nil
        backend?.invalidate()
        pushImmediateFrame()
    }

    var glassesConnected: Bool { backend != nil }

    // MARK: - Main-flow run

    /// Shows a live run's frame on the mirror and the glasses; nil hands the
    /// display back to this controller's own pipelines.
    func showRunFrame(_ frame: HUDFrame?) {
        runFrame = frame
        backend?.invalidate()
        pushImmediateFrame()
    }

    /// Back to the measured effort for the budget.
    func useMeasuredEffort() {
        effortOverride = nil
    }

    /// A RunEngine with the controller's display setting and effort override applied.
    static func makeRunEngine(plan: RunPlan, display: DisplaySetting, effort: Double?, name: String = "",
                              segues: SegueSettingsStore.Settings = .init()) -> RunEngine {
        var config = RunEngine.Config()
        config.display = display
        config.name = name
        config.segue = segues.segue
        config.headsUp = segues.headsUp
        config.segues = segues.config
        var engine = RunEngine(plan: plan, config: config)
        engine.effortOverride = effort
        return engine
    }

    var raceTargetTime: TimeInterval { race.run.plan.targetTime }

    /// Saves the race's cue log so far and opens the review list (the CUE LOG button).
    func openCueLog() {
        saveRaceLog()
        showCueLog = true
    }

    /// Writes the cue log to Documents/CueLogs; the file is named for the
    /// profile, seed and the time the race was set up.
    private func saveRaceLog() {
        let log = runEngine.log
        raceLog = log
        do {
            raceLogURL = try logStore.save(log, name: CueLogStore.runName(log.header.name.isEmpty ? "race" : log.header.name,
                                                                          at: raceStartDate))
        } catch {
            print("[HUDController] cue log save failed: \(error)")
        }
    }

    /// Attention reaches the race pipeline at race run time.
    private func receiveRaceAttention(_ event: AttentionEvent) {
        guard vitalsMode == .race, raceStarted else { return }
        runEngine.ingest(.attention(AttentionSample(t: raceTime, event: event)))
    }

    /// A plan is loaded: the RunEngine drives the HUD.
    private var usesRunEngine: Bool { vitalsMode == .race }

    private var raceTag: String {
        guard let s = raceState else { return "—" }
        let miles = s.distance / DistanceUnit.metersPerMile
        let hr = s.heartRate.map { "HR \(Int($0))" } ?? "HR —"
        let gps: String
        if let age = s.quality.secondsSinceFix, age < 3, let acc = s.quality.gpsAccuracy {
            gps = String(format: "±%.0f m", acc)
        } else {
            gps = "NO GPS"
        }
        let done = race.run.isFinished ? " · FINISHED" : ""
        return String(format: "%.2f mi · %@ · %@ · %@%@", miles, RunStateFormat.clock(s.elapsed), hr, gps, done)
    }

    // MARK: - Vitals

    private func receive(_ sample: VitalsSample) {
        if let m = sample.motion {
            motion = m
        }

        if let hr = sample.heartRate {
            lastHR = hr
            lastHRAt = now
        }
    }

    /// The synthetic watch streams only while the scenario is playing.
    private func syncSynthetic() {
        if vitalsMode == .synthetic && running {
            synthetic.start()
        } else {
            synthetic.stop()
        }
        if vitalsMode != .race {
            race.stop()
            racePlaying = false
        }
    }

    private func resetVitals() {
        synthetic.stop()
        synthetic.reset()
        lastHR = nil
        lastHRAt = -.infinity
        motion = 0
    }

    private var freshHeartRate: Int? {
        guard let hr = lastHR, now - lastHRAt < hrStaleAfter else {
            return nil
        }
        return Int(hr)
    }

    // MARK: - Loop

    private func startLoop() {
        timer?.invalidate()

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            self?.tick()
        }

        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }

        print("[HUDController] render loop started")
    }

    private func tick() {
        step(dt: 1.0 / 20.0)
    }

    private func pushImmediateFrame() {
        step(dt: 0)
    }

    private func step(dt: Double) {
        engine.motion = motion
        engine.measuredHeartRate = freshHeartRate

        // The legacy engine keeps ticking (attention, band labels) either way.
        let legacyFrame = engine.tick(dt: dt, at: now)
        let nextFrame: HUDFrame
        var raceState: RunState?
        var decisions: [Decision] = []
        var budget: (Budget, Capacity.Situation)?
        if usesRunEngine {
            if raceStarted {
                if race.run.isFinished, raceAfterFinish < 60 {
                    raceAfterFinish += dt * raceSpeed
                }
                if race.run.isFinished && !raceFinishSent {
                    raceFinishSent = true
                    runEngine.finish(at: race.run.finishTime ?? race.run.time)
                }
                let step = runEngine.update(at: raceTime)
                if step.headsUpBegan, let signal = step.headsUp, runEngine.headsUp.contains(.watchTap) {
                    haptics.headsUp(signal)
                }
                raceState = step.state
                decisions = step.decisions
                budget = (step.budget, step.situation)
                if step.decisions.contains(where: { $0.outcome == .shown && $0.t == raceTime && $0.reason == .won }) {
                    print("[HUDController] race cue at \(RunStateFormat.clock(raceTime)): \(runEngine.current.map { HUDController.cueTag($0, state: step.state) } ?? "—")")
                }
                if raceFinishSent && raceAfterFinish >= reviewDelay && !raceLogSaved {
                    raceLogSaved = true
                    DispatchQueue.main.async {
                        self.saveRaceLog()
                        self.showCueLog = true
                    }
                }
            }
            // Mid-change frames and the heads-up included; the target before the race starts.
            nextFrame = raceStarted ? runEngine.presentedFrame : runEngine.frame()
        } else {
            nextFrame = legacyFrame
        }
        let shownFrame = galleryFrame ?? runFrame ?? nextFrame
        let cue = usesRunEngine ? runEngine.current : nil
        let cueState = runEngine.state
        let log = usesRunEngine && raceStarted ? runEngine.log : nil

        DispatchQueue.main.async {
            self.frame = shownFrame
            self.bandLabel = self.engine.band.label
            self.attnLabel = self.attnTag
            if self.usesRunEngine {
                self.ctxLabel = cue.map { HUDController.cueTag($0, state: cueState) } ?? "quiet"
            } else {
                self.ctxLabel = self.engine.active.map {
                    "\($0.tag) · \($0.line1)"
                } ?? (self.engine.band == .stationary ? "dashboard" : "ambient only")
            }
            self.vitalsLabel = self.vitalsTag
            if self.vitalsMode == .race {
                self.raceState = raceState
                self.raceBudget = budget?.0
                self.raceSituation = budget?.1
                if !decisions.isEmpty { self.raceDecisions = decisions }
                if let log { self.raceLog = log }
                self.raceLabel = self.raceTag
                self.racePlaying = self.race.isStreaming
            }
        }

        if !showCalibrationOnConnect {
            backend?.apply(shownFrame)
        }
    }

    /// "MILE 3 · 8:14" for the telemetry row; live pieces (the kick clock's
    /// countdown) read from `state`.
    static func cueTag(_ cue: Cue, state: RunState? = nil) -> String {
        let c = cue.content
        let now = state.map(CueFormat.Now.init)
        return [c.heading ?? c.tag.map(CueText.label), c.main].compactMap { $0 }
            .map { CueFormat.string($0, unit: .miles, now: now) }
            .joined(separator: " · ")
    }

    private var attnTag: String {
        switch engine.attention {
        case .glance:
            return "◉ GLANCE"
        case .dwell:
            return "◉◉ DWELL"
        case .idle:
            return "○ IDLE"
        }
    }

    private var vitalsTag: String {
        let hr = engine.measuredHeartRate.map { "HR \($0)" } ?? "HR \(engine.heartRate) est"
        return "\(hr) · MOT \(Int(motion))"
    }
}
