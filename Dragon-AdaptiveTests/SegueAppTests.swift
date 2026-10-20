//  SegueAppTests.swift
//  Chunk 14 in the app: GlassesBackend draws every frame inside hold and
//  flush, never calls clear() inside a hold (it blacks the display out with
//  a filled rectangle), redraws only what changed, and maps LED ops to
//  led(state:) — checked on a recorder standing in for the SDK. The segue
//  settings persist across launches and the race engine follows them; the
//  PREVIEW controller plays the chosen style on the mirror and the glasses
//  and stops on STOP.

import XCTest
import ActiveLookSDK
import DragonEngine
@testable import Dragon_Adaptive

/// Records every ActiveLook call the backend makes.
final class GlassesRecorder: GlassesCommands {
    var calls: [String] = []

    func clear() { calls.append("clear") }
    func luma(level: UInt8) { calls.append("luma \(level)") }
    func color(level: UInt8) { calls.append("color \(level)") }
    func line(x0: Int16, x1: Int16, y0: Int16, y1: Int16) { calls.append("line") }
    func rect(x0: Int16, x1: Int16, y0: Int16, y1: Int16) { calls.append("rect") }
    func rectf(x0: Int16, x1: Int16, y0: Int16, y1: Int16) { calls.append("rectf \(x0),\(y0),\(x1),\(y1)") }
    func circ(x: Int16, y: Int16, radius: UInt8) { calls.append("circ") }
    func circf(x: Int16, y: Int16, radius: UInt8) { calls.append("circf") }
    func txt(x: Int16, y: Int16, rotation: TextRotation, font: UInt8, color: UInt8, string: String) {
        calls.append("txt \(string)")
    }
    func holdFlush(holdFlush: HoldFlushAction) { calls.append(holdFlush == .HOLD ? "hold" : "flush") }
    func led(state: LedState) { calls.append("led \(state.rawValue)") }
    func power(on: Bool) { calls.append("power") }

    /// The calls between each hold and its flush.
    var held: [[String]] {
        var out: [[String]] = []
        var current: [String]?
        for c in calls {
            if c == "hold" { current = [] } else if c == "flush" { out.append(current ?? []); current = nil }
            else { current?.append(c) }
        }
        return out
    }
}

final class GlassesBackendTests: XCTestCase {
    private func frames() -> [HUDFrame] {
        let samples = ScreenGallery.samples(unit: .miles)
        let split = samples.first { $0.name == "split" }!.frame(.full, unit: .miles)
        let quiet = samples.first { $0.name == "quiet" }!.frame(.full, unit: .miles)
        let fade = Presenter.steps(from: quiet, to: split, transition: Transition(in: Transition.inPhase(.fade, config: SegueConfig())))
        let up = Presenter.headsUp(quiet, kinds: [.dotPulse, .ledBlink, .edgeTick], elapsed: 1.2)
        return [quiet, up, quiet] + fade.map(\.frame) + samples.map { $0.frame(.full, unit: .miles) }
    }

    func testEveryFrameIsWrappedInHoldAndFlushAndNeverClearsInsideAHold() {
        let glasses = GlassesRecorder()
        let backend = GlassesBackend(commands: glasses)
        let all = frames()
        for f in all { backend.apply(f) }
        let distinct = zip(all, [HUDFrame?.none] + all.map { Optional($0) }).filter { $0.0.signature != $0.1?.signature }.count
        XCTAssertEqual(glasses.calls.filter { $0 == "hold" }.count, distinct, "one hold per frame sent")
        XCTAssertEqual(glasses.calls.filter { $0 == "flush" }.count, distinct)
        // Strictly alternating, starting with hold.
        let hf = glasses.calls.filter { $0 == "hold" || $0 == "flush" }
        XCTAssertEqual(hf, Array(repeating: ["hold", "flush"], count: distinct).flatMap { $0 })
        XCTAssertFalse(glasses.calls.contains("clear"), "clear() is not held by the SDK")
        // Drawing happens only inside a hold (the LED is not drawing and comes after the flush).
        let outside = glasses.calls.filter { $0 != "hold" && $0 != "flush" && !$0.hasPrefix("led") }.count
        XCTAssertEqual(outside, glasses.held.joined().count)
        // The first frame's clear became a black rectangle over the whole display.
        XCTAssertEqual(Array(glasses.held[0].prefix(2)), ["color 0", "rectf 0,0,303,255"])
    }

    func testOnlyWhatChangedIsRedrawn() {
        let glasses = GlassesRecorder()
        let backend = GlassesBackend(commands: glasses)
        let clock = Cue(key: .kickClock, priority: .safety,
                        content: CueContent(heading: .label("TO BEAT 1:45:00"), main: .timeLeft(until: 6_300),
                                            subtitle: [.label("LEFT 0.16 MI")]),
                        createdAt: 6_100, expiresAt: 6_400, minShow: 300)
        func frame(_ t: TimeInterval) -> HUDFrame {
            Renderer.frame(for: clock, form: .full, effort: .hard, unit: .miles,
                           now: CueFormat.Now(elapsed: t, distance: 21_000))
        }
        backend.apply(frame(6_200))
        let whole = glasses.held[0]
        backend.apply(frame(6_201))
        let tick = glasses.held[1]
        XCTAssertLessThan(tick.count, whole.count)
        XCTAssertEqual(tick.filter { $0.hasPrefix("txt") }, ["txt 1:39"])
        XCTAssertFalse(tick.contains("rectf 0,0,303,255"), "no full black-out")
        // Partial redraw off: the whole frame again.
        backend.partialRedraw = false
        backend.apply(frame(6_202))
        XCTAssertTrue(glasses.held[2].contains("rectf 0,0,303,255"))
        // After invalidate (a gesture, the test pattern) the next frame is whole.
        backend.partialRedraw = true
        backend.invalidate()
        backend.apply(frame(6_202))
        XCTAssertTrue(glasses.held[3].contains("rectf 0,0,303,255"))
    }

    func testLedOpsMapToLedState() {
        let glasses = GlassesRecorder()
        let backend = GlassesBackend(commands: glasses)
        let quiet = ScreenGallery.samples(unit: .miles).first { $0.name == "quiet" }!.frame(.full, unit: .miles)
        var blink = quiet
        blink.add(.led(.blink))
        var on = quiet
        on.add(.led(.on))
        backend.apply(quiet)
        backend.apply(blink)
        backend.apply(on)
        backend.apply(quiet)
        XCTAssertEqual(glasses.calls.filter { $0.hasPrefix("led") },
                       ["led \(LedState.blink.rawValue)", "led \(LedState.on.rawValue)", "led \(LedState.off.rawValue)"])
    }
}

final class SegueSettingsTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "segues-\(UUID())"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testDefaultsAreFadeAndDotPulse() {
        let store = SegueSettingsStore(defaults: freshDefaults())
        XCTAssertEqual(store.segue, .fade)
        XCTAssertEqual(store.headsUp, [.dotPulse])
        XCTAssertEqual(store.config, SegueConfig())
        XCTAssertTrue(store.settings.partialRedraw)
    }

    func testSettingsPersistAcrossLaunches() {
        let defaults = freshDefaults()
        let first = SegueSettingsStore(defaults: defaults)
        first.segue = .glow
        first.setHeadsUp(.dotPulse, on: false)
        first.setHeadsUp(.ledBlink, on: true)
        first.setHeadsUp(.watchTap, on: true)
        first.settings.config.quietGap = 2.5
        first.settings.config.fadeInSteps = 6
        // A new launch: a new store on the same defaults.
        let second = SegueSettingsStore(defaults: defaults)
        XCTAssertEqual(second.segue, .glow)
        XCTAssertEqual(second.headsUp, [.ledBlink, .watchTap])
        XCTAssertEqual(second.config.quietGap, 2.5)
        XCTAssertEqual(second.config.fadeInSteps, 6)
        // Off (no heads-up at all) persists too.
        second.headsUp = []
        XCTAssertEqual(SegueSettingsStore(defaults: defaults).headsUp, [])
        second.reset()
        XCTAssertEqual(SegueSettingsStore(defaults: defaults).settings, SegueSettingsStore.Settings())
    }

    func testTheRaceEngineTakesTheSettings() {
        var s = SegueSettingsStore.Settings()
        s.segue = .slide
        s.headsUp = [.edgeTick]
        s.config.quietGap = 2
        let plan = SyntheticRun(profile: .onPlan).plan
        let engine = HUDController.makeRunEngine(plan: plan, display: .balanced, effort: nil, segues: s)
        XCTAssertEqual(engine.segue, .slide)
        XCTAssertEqual(engine.headsUp, [.edgeTick])
        XCTAssertEqual(engine.arbiter.config.quietGap, 2)
    }
}

final class SeguePreviewTests: XCTestCase {
    func testThePreviewLoopPlaysTheChosenSegue() {
        for segue in Segue.allCases {
            var p = SeguePreview(segue: segue, headsUp: [.dotPulse], config: SegueConfig())
            XCTAssertEqual(p.appearsAt, 2.5, "1 s of quiet, then the 1.5 s heads-up")
            let expected = Presenter.steps(from: p.quietFrame, to: p.cueFrame,
                                           transition: Transition.between(nil, p.cue, segue: segue))
            var frames: [HUDFrame] = []
            for t in stride(from: 0.0, through: p.period * 2, by: 0.05) {
                frames.append(p.frame(at: (t * 100).rounded() / 100))
            }
            let at = { (t: Double) in frames[Int((t / 0.05).rounded())] }
            // The heads-up: the dot bright from 1 s until the cue.
            XCTAssertTrue(at(1.0).ops.contains(.circf(x: 270, y: 44, r: 3, color: 15)), "\(segue)")
            XCTAssertFalse(at(0.5).ops.contains(.circf(x: 270, y: 44, r: 3, color: 15)), "\(segue)")
            // The cue's entrance is the segue's steps.
            for step in expected {
                XCTAssertEqual(at(p.appearsAt + step.at), step.frame, "\(segue) at +\(step.at)")
            }
            XCTAssertEqual(at(p.appearsAt + 1), p.cueFrame, "\(segue): up")
            // It leaves and comes back: the second loop plays the same entrance.
            XCTAssertEqual(at(p.leavesAt + 1.0), p.quietFrame, "\(segue): gone")
            XCTAssertEqual(at(p.period + p.appearsAt + expected[0].at), expected[0].frame, "\(segue): loops")
        }
    }

    func testPreviewOnTheControllerHoldsTheMirrorAndGlassesUntilStop() {
        let store = SegueSettingsStore(defaults: UserDefaults(suiteName: "segues-preview-\(UUID())")!)
        let hud = HUDController(segueSettings: store)
        let haptics = NoHeadsUpHaptics()
        let preview = SeguePreviewController(hud: hud, haptics: haptics)
        preview.play(segue: .fade, headsUp: [.dotPulse, .watchTap], config: SegueConfig())
        XCTAssertTrue(preview.isPlaying)
        XCTAssertEqual(preview.label, "FADE · DOTPULSE · WATCHTAP")
        // Driven directly through one loop: the mirror's frame is the preview's.
        let p = SeguePreview(segue: .fade, headsUp: [.dotPulse, .watchTap], config: SegueConfig())
        for t in stride(from: 0.05, through: p.period + 1.2, by: 0.05) { preview.tick(at: t) }
        XCTAssertEqual(hud.galleryFrame, preview.frame, "held in place of the live HUD (and sent to the glasses)")
        XCTAssertEqual(haptics.count, 2, "a Watch tap at each heads-up")
        let mirrored = expectation(description: "mirror")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertEqual(hud.frame, hud.galleryFrame)
            mirrored.fulfill()
        }
        wait(for: [mirrored], timeout: 2)
        preview.stop()
        XCTAssertFalse(preview.isPlaying)
        XCTAssertNil(hud.galleryFrame, "back to the live HUD")
    }
}
