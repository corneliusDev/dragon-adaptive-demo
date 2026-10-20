//  SeguePlanTests.swift
//  Chunk 14 part B in the app: the race plan carries its segue and
//  heads-ups (saved, reloaded, and defaulted for plans saved before them);
//  the plan editor's PREVIEW starts and STOP stops the preview player with
//  the chosen style; the Watch tap can't be turned on with no Watch; the
//  live run sends the engine's presented frames (fade steps, heads-ups, the
//  LED op through GlassesBackend) and taps the Watch, light or strong, when
//  the plan's Watch tap is on.

import XCTest
import ActiveLookSDK
import DragonEngine
@testable import Dragon_Adaptive

/// Records what PREVIEW was asked to play.
final class PreviewRecorder: SeguePreviewPlaying {
    var played: [(segue: Segue, headsUp: Set<HeadsUpKind>, config: SegueConfig)] = []
    var stops = 0
    private(set) var isPlaying = false

    func play(segue: Segue, headsUp: Set<HeadsUpKind>, config: SegueConfig) {
        played.append((segue, headsUp, config))
        isPlaying = true
    }

    func stop() {
        stops += 1
        isPlaying = false
    }
}

final class StubWatch: WatchAvailability {
    var canTap: Bool
    init(_ canTap: Bool) { self.canTap = canTap }
}

/// Records the commands the haptics send to the Watch.
final class FakeCommandLink: WatchCommandSending {
    var sent: [WatchCommand] = []
    var reachable = true

    func send(_ command: WatchCommand) -> Bool {
        guard reachable else { return false }
        sent.append(command)
        return true
    }
}

final class PlanSegueTests: XCTestCase {
    private func model(_ plan: SavedPlan? = nil, watch: Bool = true, previewer: SeguePreviewPlaying? = nil,
                       defaults: (Segue, Set<HeadsUpKind>) = (.fade, [.dotPulse])) -> PlanEditorModel {
        let m = PlanEditorModel(plan: plan, segueDefaults: defaults, watch: StubWatch(watch), previewer: previewer)
        if plan == nil {
            m.name = "Park 5K"
            m.preset = .fiveK
            m.target = "25:00"
        }
        return m
    }

    private func temporaryStore() -> PlanStore {
        PlanStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("plans-\(UUID())"))
    }

    func testChoicesPersistWithThePlanAndReload() throws {
        let store = temporaryStore()
        let m = model()
        m.segue = .slide
        m.setHeadsUp(.dotPulse, on: false)
        m.setHeadsUp(.ledBlink, on: true)
        m.setHeadsUp(.watchTap, on: true)
        let saved = try XCTUnwrap(try m.save(to: store))
        XCTAssertEqual(saved.segue, .slide)
        XCTAssertEqual(saved.headsUp, [.ledBlink, .watchTap])

        let loaded = try XCTUnwrap(store.plan(saved.id))
        XCTAssertEqual(loaded.segue, .slide)
        XCTAssertEqual(loaded.headsUp, [.ledBlink, .watchTap])
        let reopened = model(loaded)
        XCTAssertEqual(reopened.segue, .slide)
        XCTAssertTrue(reopened.isOn(.ledBlink))
        XCTAssertFalse(reopened.isOn(.dotPulse))

        // Heads-ups all off persists as off.
        for kind in HeadsUpKind.allCases { reopened.setHeadsUp(kind, on: false) }
        reopened.segue = .instant
        try reopened.save(to: store)
        XCTAssertEqual(store.plan(saved.id)?.headsUp, [])
        XCTAssertEqual(store.plan(saved.id)?.segue, .instant)
    }

    func testANewPlanStartsFromTheAppWideSettings() {
        let m = model(defaults: (.glow, [.edgeTick]))
        XCTAssertEqual(m.segue, .glow)
        XCTAssertEqual(m.headsUp, [.edgeTick])
        // A saved plan keeps its own, whatever the app-wide settings say.
        var plan = m.makePlan()!
        plan.segue = .instant
        plan.headsUp = [.ledBlink]
        let edit = model(plan, defaults: (.glow, [.edgeTick]))
        XCTAssertEqual(edit.segue, .instant)
        XCTAssertEqual(edit.headsUp, [.ledBlink])
    }

    func testPlanJSONSavedBeforeTheFieldsLoadsWithFadeAndDotPulse() throws {
        var plan = model().makePlan()!
        plan.segue = .glow
        plan.headsUp = [.edgeTick]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode([plan])) as? [[String: Any]])
        XCTAssertNotNil(object[0]["segue"])
        object[0].removeValue(forKey: "segue")
        object[0].removeValue(forKey: "headsUp")
        let old = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode([SavedPlan].self, from: old)
        XCTAssertEqual(decoded[0].segue, .fade)
        XCTAssertEqual(decoded[0].headsUp, [.dotPulse])
        XCTAssertEqual(decoded[0].name, "Park 5K")
        XCTAssertEqual(decoded[0].distanceMeters, 5_000)

        // Through the store, as the app reads plans.json.
        let store = temporaryStore()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try old.write(to: store.directory.appendingPathComponent("plans.json"))
        let loaded = try XCTUnwrap(store.load().first)
        XCTAssertEqual(loaded.segue, .fade)
        XCTAssertEqual(loaded.headsUp, [.dotPulse])
        XCTAssertEqual(model(loaded).segue, .fade)
    }

    func testPreviewStartsAndStopStopsWithTheChosenStyle() {
        let recorder = PreviewRecorder()
        let m = model(previewer: recorder)
        m.segue = .slide
        m.previewSegue()
        XCTAssertTrue(m.isPreviewing)
        XCTAssertTrue(recorder.isPlaying)
        XCTAssertEqual(recorder.played.last?.segue, .slide)
        XCTAssertEqual(recorder.played.last?.headsUp, [.dotPulse])
        XCTAssertEqual(recorder.played.last?.config, SegueConfig())
        XCTAssertEqual(m.previewing, "SLIDE · DOT PULSE")

        // One heads-up's PREVIEW: that heads-up before the cue, in the chosen segue.
        m.previewHeadsUp(.edgeTick)
        XCTAssertEqual(recorder.played.last?.segue, .slide)
        XCTAssertEqual(recorder.played.last?.headsUp, [.edgeTick])
        XCTAssertEqual(m.previewing, "SLIDE · EDGE TICK")

        m.stopPreview()
        XCTAssertFalse(m.isPreviewing)
        XCTAssertFalse(recorder.isPlaying)
        XCTAssertEqual(recorder.stops, 1)
    }

    func testPreviewDrivesTheRealControllerOnTheMirror() {
        let preview = SeguePreviewController(hud: nil)
        let m = model(previewer: preview)
        m.segue = .glow
        m.previewSegue()
        XCTAssertTrue(preview.isPlaying)
        XCTAssertEqual(preview.label, "GLOW · DOTPULSE")
        let sample = SeguePreview(segue: .glow, headsUp: [.dotPulse], config: SegueConfig())
        for t in stride(from: 0.05, through: sample.appearsAt + sample.shown / 2, by: 0.05) { preview.tick(at: t) }
        XCTAssertEqual(preview.frame, sample.cueFrame, "the cue is up on the in-editor mirror")
        m.stopPreview()
        XCTAssertFalse(preview.isPlaying)
    }

    func testWatchTapIsDisabledWhenTheWatchIsNotReachable() {
        let recorder = PreviewRecorder()
        let m = model(watch: false, previewer: recorder)
        XCTAssertFalse(m.watchTapAvailable)
        XCTAssertNotNil(m.watchTapNote)
        m.setHeadsUp(.watchTap, on: true)
        XCTAssertFalse(m.isOn(.watchTap), "can't be turned on with no Watch")
        m.previewHeadsUp(.watchTap)
        XCTAssertTrue(recorder.played.isEmpty, "nothing to preview")
        m.setHeadsUp(.dotPulse, on: true)
        m.previewSegue()
        XCTAssertEqual(recorder.played.last?.headsUp, [.dotPulse])

        let watch = StubWatch(true)
        let n = PlanEditorModel(watch: watch)
        XCTAssertTrue(n.watchTapAvailable)
        XCTAssertNil(n.watchTapNote)
        n.setHeadsUp(.watchTap, on: true)
        XCTAssertTrue(n.isOn(.watchTap))
        // The Watch goes away: the choice stays and can still be turned off.
        watch.canTap = false
        XCTAssertNotNil(n.watchTapNote)
        XCTAssertTrue(n.isOn(.watchTap))
        n.setHeadsUp(.watchTap, on: false)
        XCTAssertFalse(n.isOn(.watchTap))
    }
}

final class LiveRunSegueTests: XCTestCase {
    private func plan(_ segue: Segue, _ headsUp: Set<HeadsUpKind>) -> SavedPlan {
        var p = SavedPlan(name: "Test 5K", preset: .fiveK, distanceMeters: 5_000, unit: .miles, targetTime: 1_500,
                          pacing: .even, course: nil, courseFileName: nil, zones: nil, fuelEvery: nil,
                          display: .balanced)
        p.segue = segue
        p.headsUp = headsUp
        return p
    }

    /// One frame sent to the glasses, with the cue the engine had up when it went.
    private struct Sent {
        let frame: HUDFrame
        let cue: Cue?
    }

    /// Runs the synthetic race at 1x past the first mile marker, at 20 Hz
    /// around it, and returns every frame sent from `from` (race seconds) on.
    private func runPastTheFirstMile(_ model: LiveRunModel, onFrame: ((HUDFrame) -> Void)? = nil) -> [Sent] {
        var sent: [Sent] = []
        var recording = false
        model.onFrame = { [unowned model] f in
            onFrame?(f)
            if recording { sent.append(Sent(frame: f, cue: model.engine.current)) }
        }
        model.start(timer: false)
        model.speed = 1
        while (model.state?.distance ?? 0) < DistanceUnit.metersPerMile - 80 && model.raceTime < 900 {
            model.advance(realSeconds: 1)
        }
        recording = true
        let end = model.raceTime + 40
        while model.raceTime < end { model.advance(realSeconds: 0.05) }
        return sent
    }

    private func isSplit(_ cue: Cue?) -> Bool {
        if case .split(1, _)? = cue?.key { return true }
        return false
    }

    private func brightestText(_ f: HUDFrame) -> UInt8 {
        f.ops.compactMap { if case .text(_, _, _, let c, _, _) = $0 { return c } else { return nil } }.max() ?? 0
    }

    func testWithFadeTheFirstFramesOfANewCueAreTheDimmedFadeSteps() throws {
        let model = LiveRunModel(plan: plan(.fade, []))
        XCTAssertEqual(model.engine.segue, .fade, "the plan's segue")
        XCTAssertEqual(model.engine.headsUp, [])
        let sent = runPastTheFirstMile(model)
        let first = try XCTUnwrap(sent.firstIndex { isSplit($0.cue) }, "the mile 1 split went up")
        let target = Renderer.frame(for: sent[first].cue, budget: model.engine.budget!, state: model.engine.state,
                                    unit: .miles)
        let steps = sent[first...].prefix(4).map(\.frame)
        XCTAssertEqual(steps.count, 4)
        // Brighter and brighter: 1/4, 2/4, 3/4 of the target's colour, then the target.
        let levels = steps.map(brightestText)
        XCTAssertLessThan(levels[0], levels[1], "\(levels)")
        XCTAssertLessThan(levels[1], levels[2], "\(levels)")
        XCTAssertLessThan(levels[2], levels[3], "\(levels)")
        XCTAssertEqual(levels[3], brightestText(target))
        XCTAssertEqual(steps[0], Presenter.scaled(steps[3], by: 0.25), "the first frame is the dimmest fade step")
    }

    func testWithInstantTheFirstFrameIsTheFullCue() throws {
        let model = LiveRunModel(plan: plan(.instant, []))
        let sent = runPastTheFirstMile(model)
        let first = try XCTUnwrap(sent.firstIndex { isSplit($0.cue) })
        let next = sent[(first + 1)...].first { isSplit($0.cue) }
        XCTAssertEqual(brightestText(sent[first].frame), 15, "full brightness at once")
        if let next {
            // Anything after it is the same cue redrawn (a live number), not a brighter step.
            XCTAssertEqual(brightestText(next.frame), 15)
        }
    }

    func testWithDotPulseAHeadsUpFramePrecedesThePredictableCue() throws {
        let model = LiveRunModel(plan: plan(.fade, [.dotPulse]))
        let sent = runPastTheFirstMile(model)
        let first = try XCTUnwrap(sent.firstIndex { isSplit($0.cue) })
        let bright = HUDOp.circf(x: 270, y: 44, r: 3, color: SegueConfig().headsUpDotColor)
        let before = sent[..<first]
        let pulse = try XCTUnwrap(before.last { $0.frame.ops.contains(bright) }, "the dot pulsed before the split")
        XCTAssertNil(pulse.cue, "on the quiet screen, before the cue was up")
        XCTAssertFalse(sent[first].frame.ops.contains(bright), "the pulse ends as the cue comes")
    }

    func testLedOpsReachTheGlassesWhenLedBlinkIsOn() {
        let glasses = GlassesRecorder()
        let hud = HUDController(segueSettings: SegueSettingsStore(defaults: UserDefaults(suiteName: "led-\(UUID())")!))
        hud.attach(GlassesBackend(commands: glasses))
        let model = LiveRunModel(plan: plan(.fade, [.ledBlink]))
        var frames = 0
        _ = runPastTheFirstMile(model, onFrame: { frames += 1; hud.showRunFrame($0) })
        XCTAssertTrue(glasses.calls.contains("led \(LedState.blink.rawValue)"), "the LED blinked for the heads-up")
        XCTAssertTrue(glasses.calls.contains("led \(LedState.off.rawValue)"), "and stopped when the cue came")
        // Each frame went once; the run doesn't force a whole redraw per frame (segue steps redraw what changed).
        XCTAssertEqual(glasses.held.count, frames)
        XCTAssertLessThan(glasses.held.filter { $0.contains("rectf 0,0,303,255") }.count, frames)

        // Off: no LED.
        let quiet = GlassesRecorder()
        let hud2 = HUDController(segueSettings: SegueSettingsStore(defaults: UserDefaults(suiteName: "led-\(UUID())")!))
        hud2.attach(GlassesBackend(commands: quiet))
        _ = runPastTheFirstMile(LiveRunModel(plan: plan(.fade, [.dotPulse])), onFrame: { hud2.showRunFrame($0) })
        XCTAssertFalse(quiet.calls.contains("led \(LedState.blink.rawValue)"))
        withExtendedLifetime((glasses, quiet)) {}
    }
}

final class WatchTapTests: XCTestCase {
    private func plan(_ headsUp: Set<HeadsUpKind>) -> SavedPlan {
        var p = SavedPlan(name: "Test 5K", preset: .fiveK, distanceMeters: 5_000, unit: .miles, targetTime: 1_500,
                          pacing: .even, course: nil, courseFileName: nil, zones: nil, fuelEvery: nil,
                          display: .balanced)
        p.headsUp = headsUp
        return p
    }

    private func runAMileAndAHalf(_ model: LiveRunModel) {
        model.start(timer: false)
        model.speed = 1
        while (model.state?.distance ?? 0) < DistanceUnit.metersPerMile * 1.5 && model.raceTime < 1_000 {
            model.advance(realSeconds: 0.25)
        }
    }

    func testAnAdvisoryHeadsUpSendsALightTap() {
        let link = FakeCommandLink()
        let model = LiveRunModel(plan: plan([.dotPulse, .watchTap]))
        model.haptics = WatchHeadsUpHaptics(link: link)
        runAMileAndAHalf(model)
        XCTAssertFalse(link.sent.isEmpty, "the mile 1 split's heads-up tapped the wrist")
        XCTAssertTrue(link.sent.allSatisfy { $0 == .tapLight }, "\(link.sent)")
    }

    func testACriticalHeadsUpSendsAStrongTap() {
        let link = FakeCommandLink()
        let haptics = WatchHeadsUpHaptics(link: link)
        haptics.headsUp(RunEngine.HeadsUpSignal(key: .kickClock, since: 10, dueAt: 11.5, priority: .safety))
        haptics.headsUp(RunEngine.HeadsUpSignal(key: .paceGap, since: 20, dueAt: 21.5, priority: .critical))
        haptics.headsUp(RunEngine.HeadsUpSignal(key: .fuel(1), since: 30, dueAt: 31.5, priority: .advisory))
        haptics.headsUp(RunEngine.HeadsUpSignal(key: .status, since: 40, dueAt: 41.5, priority: .info))
        XCTAssertEqual(link.sent, [.tapStrong, .tapStrong, .tapLight, .tapLight])
        XCTAssertEqual(haptics.sent, 4)
        link.reachable = false
        haptics.headsUp(RunEngine.HeadsUpSignal(key: .paceGap, since: 50, dueAt: 51.5, priority: .critical))
        XCTAssertEqual(haptics.unsent, 1)
    }

    func testNothingIsSentWhenWatchTapIsOff() {
        let link = FakeCommandLink()
        let model = LiveRunModel(plan: plan([.dotPulse]))
        model.haptics = WatchHeadsUpHaptics(link: link)
        runAMileAndAHalf(model)
        XCTAssertNotNil(model.engine.log.appearances.first, "cues showed")
        XCTAssertEqual(link.sent, [])
    }

    func testTheTapGoesThroughTheWatchLinkAsAVersionOneMessage() throws {
        let connectivity = FakeWatchTransport()
        let mirroring = FakeWatchTransport(reachable: false)
        let link = WatchLink(connectivity: connectivity, mirroring: mirroring, health: FakeHealthStore())
        XCTAssertTrue(link.canTap)
        WatchHeadsUpHaptics(link: link)
            .headsUp(RunEngine.HeadsUpSignal(key: .kickClock, since: 1, dueAt: 2.5, priority: .safety))
        let data = try XCTUnwrap(connectivity.sent.last)
        let message = try WatchMessage.decode(data)
        XCTAssertEqual(message.body, .command(.tapStrong))
        // Mirrored workout up: it goes that way.
        mirroring.isReachable = true
        WatchHeadsUpHaptics(link: link)
            .headsUp(RunEngine.HeadsUpSignal(key: .split(marker: 2, unit: .miles), since: 3, dueAt: 4.5))
        XCTAssertEqual(try WatchMessage.decode(try XCTUnwrap(mirroring.sent.last)).body, .command(.tapLight))
    }
}
