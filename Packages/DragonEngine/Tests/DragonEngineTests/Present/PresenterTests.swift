//  PresenterTests.swift
//  Chunk 14: the Presenter's in-between frames for each segue — how many,
//  when, and the colour levels, offsets and luma of each — the heads-up
//  drawn over a frame, and that every intermediate frame of every screen
//  stays inside the safe zone and the font limits. Safety and critical cues
//  and answers cut in under every segue.

import XCTest
import DragonEngine

final class PresenterTests: XCTestCase {
    private let config = SegueConfig()
    private func sample(_ name: String) -> ScreenSample {
        ScreenGallery.race(unit: .miles).first { $0.name == name }!
    }
    private var split: HUDFrame { sample("split").frame(.full, unit: .miles) }
    private var kick: HUDFrame { sample("kickClock").frame(.full, unit: .miles) }
    private var quiet: HUDFrame { sample("quiet").frame(.full, unit: .miles) }

    private func colors(_ f: HUDFrame) -> [UInt8] {
        f.ops.compactMap { op -> UInt8? in
            switch op {
            case .text(_, _, _, let c, _, _), .line(_, _, _, _, let c), .rect(_, _, _, _, let c),
                 .rectf(_, _, _, _, let c), .circ(_, _, _, let c), .circf(_, _, _, let c): return c
            case .clear, .luma, .led: return nil
            }
        }
    }
    private func luma(_ f: HUDFrame) -> UInt8? { FrameDiff.luma(f) }
    /// How far the frame's ops sit below the same ops in `base`.
    private func offset(_ f: HUDFrame, from base: HUDFrame) -> Int? {
        guard let a = f.ops.compactMap(\.bounds).first, let b = base.ops.compactMap(\.bounds).first else { return nil }
        return a.minY - b.minY
    }
    private func steps(_ from: HUDFrame, _ to: HUDFrame, _ t: Transition) -> [(at: TimeInterval, frame: HUDFrame)] {
        Presenter.steps(from: from, to: to, transition: t)
    }

    func testInstantIsOneFrame() {
        let t = Transition.between(nil, sample("split").cue, segue: .instant)
        XCTAssertTrue(t.isCut)
        let s = steps(quiet, split, t)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].at, 0)
        XCTAssertEqual(s[0].frame, split)
        XCTAssertEqual(Presenter.frame(from: quiet, to: split, transition: t, elapsed: 0), split)
    }

    func testFadeInIsFourBrighterStepsOverThreeHundredMilliseconds() {
        let t = Transition.between(nil, sample("split").cue, segue: .fade)
        let s = steps(quiet, split, t)
        XCTAssertEqual(s.count, 4)
        XCTAssertEqual(s.map(\.at), [0, 0.1, 0.2, 0.3].map { $0 }, accuracy: 1e-9)
        // MILE 1 (10), 8:14 (15), +0:13 VS PLAN (13), the tag's box (8) and label (11).
        XCTAssertEqual(s.map { colors($0.frame) }, [[3, 4, 3, 2, 3], [5, 8, 7, 4, 6], [8, 11, 10, 6, 8], [10, 15, 13, 8, 11]])
        XCTAssertEqual(s.last?.frame, split)
        XCTAssertTrue(s.allSatisfy { luma($0.frame) == 13 }, "a fade leaves the luma alone")
        // Between steps, the latest step.
        XCTAssertEqual(Presenter.frame(from: quiet, to: split, transition: t, elapsed: 0.15), s[1].frame)
        XCTAssertEqual(Presenter.frame(from: quiet, to: split, transition: t, elapsed: 5), split)
    }

    func testFadeOutDimsToTheStatusDotOverHalfASecond() {
        let t = Transition.between(sample("split").cue, nil, segue: .fade)
        let s = steps(split, quiet, t)
        XCTAssertEqual(s.count, 4)
        XCTAssertEqual(s.map(\.at), [0, 0.5 / 3, 1.0 / 3, 0.5], accuracy: 1e-9)
        XCTAssertEqual(s.dropLast().map { colors($0.frame) }, [[8, 11, 10, 6, 8], [5, 8, 7, 4, 6], [3, 4, 3, 2, 3]])
        XCTAssertEqual(s.last?.frame, quiet, "ends on the status dot")
    }

    func testCueToCueFadesOutThenIn() {
        let t = Transition.between(sample("split").cue, sample("terrain").cue, segue: .fade)
        let terrain = sample("terrain").frame(.full, unit: .miles)
        let s = steps(split, terrain, t)
        XCTAssertEqual(s.count, 7)
        XCTAssertEqual(s.map(\.at), [0, 0.5 / 3, 1.0 / 3, 0.5, 0.6, 0.7, 0.8], accuracy: 1e-9)
        XCTAssertEqual(s.last?.frame, terrain)
    }

    func testSlideRisesEightPixelsIntoPlaceWhileFadingIn() {
        let t = Transition.between(nil, sample("kickClock").cue.map { var c = $0; c.priority = .advisory; return c },
                                   segue: .slide)
        let s = steps(quiet, kick, t)
        XCTAssertEqual(s.count, 4)
        XCTAssertEqual(s.map(\.at), [0, 0.1, 0.2, 0.3], accuracy: 1e-9)
        XCTAssertEqual(s.map { offset($0.frame, from: kick) }, [8, 5, 3, 0])
        XCTAssertEqual(s.map { colors($0.frame) }, [[2, 4, 3], [5, 8, 6], [7, 11, 8], [9, 15, 11]])
        XCTAssertEqual(s.last?.frame, kick)
        // The split's tag box sits 6 px above the safe zone's bottom: it rises from there.
        let low = steps(quiet, split, Transition.between(nil, sample("split").cue, segue: .slide))
        XCTAssertEqual(low.map { offset($0.frame, from: split) }, [6, 5, 3, 0])
        // On the way out it sinks as it fades.
        let out = steps(kick, quiet, Transition(out: Transition.outPhase(.slide, config: config)))
        XCTAssertEqual(out.dropLast().map { offset($0.frame, from: kick) }, [0, 3, 5])
    }

    func testGlowRampsTheWholeDisplaysLumaUpFromDarkAndDown() {
        let t = Transition.between(nil, sample("split").cue, segue: .glow)
        let s = steps(quiet, split, t)
        XCTAssertEqual(s.map(\.at), [0, 0.1, 0.2, 0.3], accuracy: 1e-9)
        XCTAssertEqual(s.map { luma($0.frame) }, [3, 7, 10, 13])
        XCTAssertTrue(s.allSatisfy { colors($0.frame) == colors(split) }, "colours as they are")
        let out = steps(split, quiet, Transition.between(sample("split").cue, nil, segue: .glow))
        XCTAssertEqual(out.map(\.at), [0, 0.5 / 3, 1.0 / 3, 0.5], accuracy: 1e-9)
        XCTAssertEqual(out.map { luma($0.frame) }, [10, 7, 3, 13])
        XCTAssertEqual(out.last?.frame, quiet)
    }

    func testTheStepsFollowTheConfig() {
        var c = SegueConfig()
        c.fadeIn = 0.6
        c.fadeInSteps = 3
        c.slideDistance = 12
        let s = steps(quiet, kick, Transition(in: Transition.inPhase(.slide, config: c)))
        XCTAssertEqual(s.map(\.at), [0, 0.3, 0.6], accuracy: 1e-9)
        XCTAssertEqual(s.map { offset($0.frame, from: kick) }, [12, 6, 0])
    }

    func testSafetyCriticalAndAnswersCutInUnderEverySegue() {
        let race = ScreenGallery.race(unit: .miles)
        for segue in Segue.allCases {
            for s in race {
                guard let cue = s.cue else { continue }
                for from in [nil, sample("split").cue] {
                    let t = Transition.between(from, cue, segue: segue)
                    if cue.priority >= .critical {
                        XCTAssertTrue(t.isCut, "\(s.name) \(segue)")
                    }
                    var asked = cue
                    asked.requested = true
                    XCTAssertTrue(Transition.between(from, asked, segue: segue).isCut, "answer \(s.name) \(segue)")
                    // A cut puts the cue on screen in the first frame.
                    let frame = s.frame(.full, unit: .miles)
                    if t.isCut { XCTAssertEqual(Presenter.steps(from: split, to: frame, transition: t).map(\.frame), [frame]) }
                }
            }
        }
        // The kick clock (safety) and the pace gap (critical) are cuts; a split eases in.
        XCTAssertTrue(Transition.between(nil, sample("kickClock").cue, segue: .slide).isCut)
        XCTAssertTrue(Transition.between(nil, sample("paceGap").cue, segue: .glow).isCut)
        XCTAssertFalse(Transition.between(nil, sample("split").cue, segue: .fade).isCut)
    }

    func testEveryIntermediateFrameStaysInsideTheSafeZoneAndTheFontLimits() {
        for unit in DistanceUnit.allCases {
            let samples = ScreenGallery.samples(unit: unit)
            for segue in Segue.allCases {
                let t = Transition(out: Transition.outPhase(segue, config: config), in: Transition.inPhase(segue, config: config))
                for a in samples {
                    for form in Renderer.Form.allCases {
                        let from = a.frame(form, unit: unit)
                        for b in samples.prefix(14) {
                            let to = b.frame(form, unit: unit)
                            for (at, f) in Presenter.steps(from: from, to: to, transition: t) {
                                let what = "\(a.name)→\(b.name) \(segue) \(form) at \(at)"
                                XCTAssertTrue(f.ops.allSatisfy(\.isInsideSafeZone), what)
                                for case .text(_, _, let font, _, _, let s) in f.ops {
                                    XCTAssertLessThanOrEqual(s.count, font.maxChars, what)
                                    XCTAssertEqual(font.onGlasses, font, what)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Heads-up

    func testDotPulseBrightensTheStatusDot() {
        let up = Presenter.headsUp(quiet, kinds: [.dotPulse], elapsed: 0)
        XCTAssertEqual(up.ops.filter { if case .circf = $0 { return true } else { return false } },
                       [.circf(x: 270, y: 44, r: 3, color: 15)])
        // Over a cue, the dot is drawn where it always is.
        let over = Presenter.headsUp(split, kinds: [.dotPulse], elapsed: 0.5)
        XCTAssertEqual(over.ops.last, .circf(x: 270, y: 44, r: 3, color: 15))
        XCTAssertEqual(Array(over.ops.dropLast()), split.ops)
    }

    func testEdgeTickFillsOverTheLastSecond() {
        func fill(_ e: TimeInterval) -> Int? {
            Presenter.headsUp(quiet, kinds: [.edgeTick], elapsed: e).ops.compactMap { op -> Int? in
                if case .rectf(let x0, _, let x1, _, _) = op { return x1 - x0 } else { return nil }
            }.first
        }
        // The box is up from the start; nothing filled until the last second, then 4 steps.
        XCTAssertTrue(Presenter.headsUp(quiet, kinds: [.edgeTick], elapsed: 0).ops.contains(.rect(x0: 132, y0: 216, x1: 172, y1: 220, color: 8)))
        XCTAssertNil(fill(0))
        XCTAssertNil(fill(0.49))
        XCTAssertEqual([0.5, 0.75, 1.0, 1.25, 1.5].map { fill($0) }, [10, 20, 30, 40, 40])
        for e in stride(from: 0.0, through: 1.5, by: 0.1) {
            XCTAssertTrue(Presenter.headsUp(split, kinds: [.edgeTick], elapsed: e).ops.allSatisfy(\.isInsideSafeZone))
        }
    }

    func testLedBlinkAddsTheLedOpAndWatchTapDrawsNothing() {
        XCTAssertEqual(Presenter.headsUp(quiet, kinds: [.ledBlink], elapsed: 0).ops.last, .led(.blink))
        XCTAssertEqual(Presenter.headsUp(split, kinds: [.watchTap], elapsed: 0), split)
        XCTAssertEqual(Presenter.headsUp(split, kinds: [], elapsed: 0), split)
    }
}

private func XCTAssertEqual(_ a: [TimeInterval], _ b: [TimeInterval], accuracy: Double,
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, "\(a) vs \(b)", file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, "\(a) vs \(b)", file: file, line: line) }
}
