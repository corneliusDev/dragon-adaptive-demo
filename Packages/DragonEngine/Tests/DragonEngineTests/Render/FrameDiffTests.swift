//  FrameDiffTests.swift
//  Chunk 14: redraw only what changed. Drawing FrameDiff's patch over the
//  old frame must look exactly like drawing the new frame whole (on the
//  Raster model of the display), for every pair of screens the renderer
//  draws, every step of every segue, the heads-ups, a live countdown and
//  random frames; and it falls back to a full redraw when it can't be sure.

import XCTest
import DragonEngine

final class FrameDiffTests: XCTestCase {
    /// Asserts the patch (when there is one) over `old` looks like `new`.
    private func assertPatchMatches(_ old: HUDFrame, _ new: HUDFrame, _ what: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        guard let patch = FrameDiff.patch(from: old, to: new) else { return }
        XCTAssertFalse(patch.contains(.clear), "\(what): a patch never clears", file: file, line: line)
        var display = Raster.of(old)
        display.draw(patch)
        XCTAssertTrue(display == Raster.of(new), "\(what): patched display differs from the new frame", file: file, line: line)
    }

    private var screens: [(String, HUDFrame)] {
        DistanceUnit.allCases.flatMap { unit in
            ScreenGallery.samples(unit: unit).flatMap { s in
                Renderer.Form.allCases.map { ("\(s.name) \(unit) \($0)", s.frame($0, unit: unit)) }
            }
        }
    }

    func testPatchingBetweenAnyTwoScreensLooksLikeTheNewScreen() {
        let all = screens
        var patched = 0
        for (a, old) in all {
            for (b, new) in all.prefix(30) {
                assertPatchMatches(old, new, "\(a) → \(b)")
                if FrameDiff.patch(from: old, to: new) != nil { patched += 1 }
            }
        }
        XCTAssertGreaterThan(patched, 0)
    }

    func testPatchingEverySegueStepAndHeadsUpLooksLikeTheStep() {
        let race = ScreenGallery.race(unit: .miles)
        for sample in race {
            let frame = sample.frame(.full, unit: .miles)
            let quiet = Renderer.frame(for: nil, form: .full, effort: sample.effort, unit: .miles)
            for segue in Segue.allCases {
                let t = Transition(out: Transition.outPhase(segue, config: SegueConfig()),
                                   in: Transition.inPhase(segue, config: SegueConfig()))
                let steps = Presenter.steps(from: quiet, to: frame, transition: t).map(\.frame)
                    + Presenter.steps(from: frame, to: quiet, transition: t).map(\.frame)
                for (old, new) in zip([quiet] + steps, steps) {
                    assertPatchMatches(old, new, "\(sample.name) \(segue)")
                }
            }
            var kinds: [Set<HeadsUpKind>] = HeadsUpKind.allCases.map { [$0] }
            kinds.append(Set(HeadsUpKind.allCases))
            for k in kinds {
                for elapsed in stride(from: 0.0, through: 1.5, by: 0.25) {
                    let up = Presenter.headsUp(frame, kinds: k, elapsed: elapsed)
                    assertPatchMatches(frame, up, "\(sample.name) heads-up \(k) at \(elapsed)")
                    assertPatchMatches(up, frame, "\(sample.name) heads-up \(k) off")
                }
            }
        }
    }

    func testACountdownTickRedrawsOnlyTheNumber() {
        let clock = Cue(key: .kickClock, priority: .safety,
                        content: CueContent(heading: .phrase([.label("TO BEAT"), .duration(6_300)]),
                                            main: .timeLeft(until: 6_300),
                                            subtitle: [.phrase([.label("LEFT"), .distance(260)])]),
                        createdAt: 6_100, expiresAt: 6_400, minShow: 300)
        let now = { (e: TimeInterval) in CueFormat.Now(elapsed: e, distance: 21_000) }
        let a = Renderer.frame(for: clock, form: .full, effort: .hard, unit: .miles, now: now(6_200))
        let b = Renderer.frame(for: clock, form: .full, effort: .hard, unit: .miles, now: now(6_201))
        XCTAssertNotEqual(a, b)
        let patch = FrameDiff.patch(from: a, to: b)
        XCTAssertNotNil(patch)
        // A black box over the old number and the new number, nothing else.
        XCTAssertEqual(patch?.count, 2, "\(String(describing: patch))")
        assertPatchMatches(a, b, "countdown")
    }

    func testTheLedIsSentOnlyWhenItChanges() {
        var a = HUDFrame(); a.add(.clear); a.add(.luma(10)); a.add(.circf(x: 270, y: 44, r: 3, color: 7))
        var b = a; b.add(.led(.blink))
        XCTAssertEqual(FrameDiff.patch(from: a, to: b), [.led(.blink)])
        XCTAssertEqual(FrameDiff.patch(from: b, to: a), [.led(.off)])
        XCTAssertEqual(FrameDiff.patch(from: b, to: b), [])
    }

    func testFallsBackToAFullRedrawWhenUnsure() {
        var a = HUDFrame(); a.add(.clear); a.add(.luma(10))
        a.add(.rectf(x0: 40, y0: 40, x1: 100, y1: 100, color: 15)); a.add(.rectf(x0: 60, y0: 60, x1: 120, y1: 120, color: 5))
        // The same ops in another order: what is on top changes.
        var b = HUDFrame(); b.add(.clear); b.add(.luma(10))
        b.add(.rectf(x0: 60, y0: 60, x1: 120, y1: 120, color: 5)); b.add(.rectf(x0: 40, y0: 40, x1: 100, y1: 100, color: 15))
        XCTAssertNil(FrameDiff.patch(from: a, to: b))
        // A frame that doesn't start by clearing: nothing to diff against.
        var c = HUDFrame(); c.add(.text(x: 152, y: 120, font: .large, color: 15, align: .center, "X"))
        XCTAssertNil(FrameDiff.patch(from: a, to: c))
        XCTAssertNil(FrameDiff.patch(from: c, to: a))
        // Everything changed: redraw rather than patch.
        let split = ScreenGallery.race(unit: .miles).first { $0.name == "split" }!.frame(.full, unit: .miles)
        let quiet = Renderer.frame(for: nil, form: .full, effort: .moderate, unit: .miles)
        XCTAssertNil(FrameDiff.patch(from: quiet, to: split))
    }

    func testRandomFramesPatchToTheSameDisplay() {
        var rng = SplitMix(state: 7)
        func int(_ r: ClosedRange<Int>) -> Int { r.lowerBound + Int(rng.next() % UInt64(r.count)) }
        func op() -> HUDOp {
            let x = int(20...250), y = int(30...200), c = UInt8(int(0...15))
            switch int(0...5) {
            case 0: return .text(x: x, y: y, font: HUDFont(rawValue: UInt8(int(1...3)))!, color: c, align: .center,
                                 String(repeating: "8", count: int(1...6)))
            case 1: return .line(x0: x, y0: y, x1: x + int(0...30), y1: y + int(0...15), color: c)
            case 2: return .rect(x0: x, y0: y, x1: x + int(1...30), y1: y + int(1...15), color: c)
            case 3: return .rectf(x0: x, y0: y, x1: x + int(1...30), y1: y + int(1...15), color: c)
            case 4: return .circ(x: x, y: y, r: int(2...12), color: c)
            default: return .circf(x: x, y: y, r: int(2...12), color: c)
            }
        }
        var patched = 0
        for i in 0..<300 {
            var old = HUDFrame(); old.add(.clear); old.add(.luma(UInt8(int(8...15))))
            for _ in 0..<int(3...12) { old.add(op()) }
            var new = old
            // Change a few: remove, replace or add ops.
            for _ in 0..<int(1...3) {
                let drawing = new.ops.indices.dropFirst(2)
                switch int(0...2) {
                case 0 where !drawing.isEmpty: new.ops.remove(at: drawing.randomElement(using: &rng)!)
                case 1 where !drawing.isEmpty: new.ops[drawing.randomElement(using: &rng)!] = op()
                default: new.add(op())
                }
            }
            if int(0...3) == 0 { new.ops[1] = .luma(UInt8(int(8...15))) }
            if int(0...3) == 0 { new.add(.led(.blink)) }
            assertPatchMatches(old, new, "random \(i)")
            if FrameDiff.patch(from: old, to: new) != nil { patched += 1 }
        }
        XCTAssertGreaterThan(patched, 50, "most small changes are patched")
    }
}

/// A small seeded generator, so the random frames are the same every run.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
