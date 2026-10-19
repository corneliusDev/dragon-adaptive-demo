//  RendererTests.swift
//  Chunk 7 acceptance for the renderer: a stored golden frame per cue kind
//  (full and reduced, miles and kilometres), every op inside the safe zone,
//  and no text over its font's character limit or above the font the
//  glasses draw.

import XCTest
import DragonEngine

final class RendererTests: XCTestCase {
    private let units = DistanceUnit.allCases
    private let forms = Renderer.Form.allCases
    private let bands: [MotionBand] = [.stationary, .light, .moderate, .hard]

    /// Every sample in every form, unit and effort band.
    private func everyFrame() -> [(label: String, frame: HUDFrame)] {
        units.flatMap { unit in
            ScreenGallery.samples(unit: unit).flatMap { sample in
                forms.flatMap { form in
                    bands.map { band -> (String, HUDFrame) in
                        var s = sample
                        s.effort = band
                        return ("\(unit.rawValue) \(sample.name) \(form.rawValue) \(band.label)", s.frame(form, unit: unit))
                    }
                }
            }
        }
    }

    private func texts(_ frame: HUDFrame) -> [String] {
        frame.ops.compactMap { if case .text(_, _, _, _, _, let s) = $0 { return s } else { return nil } }
    }

    // MARK: Snapshots

    func testEveryCueKindHasASampleScreen() {
        for unit in units {
            let kinds = Set(ScreenGallery.samples(unit: unit).compactMap { $0.cue?.key.kind })
            XCTAssertEqual(kinds, Set(CueKind.allCases), unit.rawValue)
            XCTAssertTrue(ScreenGallery.samples(unit: unit).contains { $0.cue == nil && $0.quiet == .statusDot })
        }
    }

    func testEachScreenMatchesItsGoldenFrame() {
        var entries: [(name: String, value: String)] = []
        for unit in units {
            for sample in ScreenGallery.samples(unit: unit) {
                for form in forms {
                    entries.append(("\(unit.rawValue).\(sample.name).\(form.rawValue)",
                                    sample.frame(form, unit: unit).signature))
                }
            }
        }
        Goldens.check(entries, against: "renderer-goldens.txt")
    }

    func testTheDesignsWordsComeOutAsDrawn() {
        let mi = Dictionary(uniqueKeysWithValues: ScreenGallery.samples(unit: .miles).map { ($0.name, $0) })
        XCTAssertEqual(texts(mi["split"]!.frame(.full, unit: .miles)), ["MILE 1", "8:14", "+0:13 VS PLAN", "SPLIT"])
        XCTAssertEqual(texts(mi["paceGap"]!.frame(.full, unit: .miles)),
                       ["BEHIND PLAN", "+0:48", "FINISH 1:45:48", "NEED 7:53 / MI"])
        XCTAssertEqual(texts(mi["detail"]!.frame(.full, unit: .miles)),
                       ["LAST 3 SPLITS", "MILE 9", "7:44", "MILE 10", "7:58", "MILE 11", "8:14",
                        "NEED 7:49 / MI", "PROJ 1:45:22 +0:22"])
        XCTAssertEqual(texts(mi["kickClock"]!.frame(.full, unit: .miles)), ["TO BEAT 1:45:00", "1:38", "LEFT 0.16 MI"])
        XCTAssertEqual(texts(mi["terrain"]!.frame(.full, unit: .miles)), ["HILL 0.20 MI", "HOLD EFFORT", "TERRAIN"])
        XCTAssertEqual(texts(mi["target"]!.frame(.full, unit: .miles)),
                       ["TARGET", "1:45:00", "8:01 / MI EVEN", "GLANCE FOR STATUS"])
        XCTAssertTrue(texts(mi["quiet"]!.frame(.full, unit: .miles)).isEmpty)

        let km = Dictionary(uniqueKeysWithValues: ScreenGallery.samples(unit: .kilometers).map { ($0.name, $0) })
        XCTAssertEqual(texts(km["split"]!.frame(.full, unit: .kilometers)), ["KM 1", "5:07", "+0:08 VS PLAN", "SPLIT"])
        XCTAssertEqual(texts(km["kickClock"]!.frame(.full, unit: .kilometers)),
                       ["TO BEAT 1:45:00", "1:38", "LEFT 0.26 KM"])
    }

    func testReducedFormIsTheValueAndItsCaption() {
        let mi = Dictionary(uniqueKeysWithValues: ScreenGallery.samples(unit: .miles).map { ($0.name, $0) })
        XCTAssertEqual(texts(mi["split"]!.frame(.reduced, unit: .miles)), ["MILE 1", "8:14"])
        XCTAssertEqual(texts(mi["paceGap"]!.frame(.reduced, unit: .miles)), ["BEHIND PLAN", "+0:48"])
        XCTAssertEqual(texts(mi["kickClock"]!.frame(.reduced, unit: .miles)), ["TO BEAT 1:45:00", "1:38"])
        XCTAssertEqual(texts(mi["detail"]!.frame(.reduced, unit: .miles)), ["MILE 11 8:14", "NEED 7:49 / MI"])
        XCTAssertEqual(texts(mi["fuel"]!.frame(.reduced, unit: .miles)), ["GEL NOW"])
        XCTAssertEqual(texts(mi["heartCeiling"]!.frame(.reduced, unit: .miles)), ["!", "HR 178 Z5"])
        for unit in units {
            for sample in ScreenGallery.samples(unit: unit) where sample.cue != nil {
                XCTAssertLessThan(sample.frame(.reduced, unit: unit).ops.count, sample.frame(.full, unit: unit).ops.count,
                                  sample.name)
            }
        }
    }

    func testTheBudgetPicksTheForm() {
        XCTAssertEqual(Renderer.form(for: .relaxed), .full)
        XCTAssertEqual(Renderer.form(for: .steady), .full)
        XCTAssertEqual(Renderer.form(for: .strained), .reduced)
        XCTAssertEqual(Renderer.form(for: .safetyOnly), .reduced)

        let split = ScreenGallery.samples(unit: .miles)[0]
        let state = RunState(elapsed: 0, distance: 0, effort: split.effort)
        XCTAssertEqual(Renderer.frame(for: split.cue, budget: .steady, state: state, unit: .miles),
                       split.frame(.full, unit: .miles))
        XCTAssertEqual(Renderer.frame(for: split.cue, budget: .strained, state: state, unit: .miles),
                       split.frame(.reduced, unit: .miles))
        var config = RenderConfig()
        config.fullFormElements = 3
        XCTAssertEqual(Renderer.form(for: .steady, config: config), .reduced)
    }

    func testBrighterAsEffortRises() {
        let split = ScreenGallery.samples(unit: .miles)[0]
        let lumas = bands.map { band -> UInt8? in
            var s = split
            s.effort = band
            if case .luma(let l) = s.frame(.full, unit: .miles).ops[1] { return l } else { return nil }
        }
        XCTAssertEqual(lumas, [8, 11, 13, 15])
    }

    // MARK: Safe zone and text limits

    func testEveryDrawOpOfEveryScreenLiesInsideTheSafeZone() {
        for (label, frame) in everyFrame() {
            XCTAssertEqual(frame.ops.first, .clear, label)
            for op in frame.ops {
                XCTAssertTrue(op.isInsideSafeZone, "\(label): \(op) at \(String(describing: op.bounds))")
            }
        }
    }

    func testNoTextExceedsItsFontsCharacterLimitInMilesOrKilometres() {
        for (label, frame) in everyFrame() {
            for op in frame.ops {
                guard case .text(_, _, let font, _, _, let s) = op else { continue }
                XCTAssertLessThanOrEqual(s.count, font.maxChars, "\(label): \(s)")
                XCTAssertLessThanOrEqual(font.rawValue, HUDFont.largestOnGlasses.rawValue, "\(label): \(s)")
            }
        }
    }

    func testNothingInTheGalleryIsCutShort() {
        // Each string drawn is exactly the content's text: fitting never had to truncate.
        for unit in units {
            for sample in ScreenGallery.race(unit: unit) {
                guard let c = sample.cue?.content else { continue }
                var expected = [c.heading, c.main, c.footer].compactMap { $0 } + c.subtitle
                expected += c.rows.flatMap { [$0.label, $0.value] }
                let words = Set(expected.map { CueFormat.string($0, unit: unit) } + [c.tag].compactMap { $0 } + ["!"])
                for s in texts(sample.frame(.full, unit: unit)) {
                    XCTAssertTrue(words.contains(s), "\(unit.rawValue) \(sample.name): \(s)")
                }
            }
        }
    }

    func testOverlongTextStepsDownAFontThenIsCutToTheLimit() {
        let long = Cue(key: .scripted("x"), priority: .info,
                       content: CueContent(main: .label("A VERY LONG HEADLINE"), subtitle: [.label(String(repeating: "W", count: 40))],
                                           tag: "TAG"),
                       createdAt: 0, expiresAt: 1, minShow: 1)
        for form in forms {
            let frame = Renderer.frame(for: long, form: form, effort: .moderate, unit: .miles)
            for op in frame.ops {
                XCTAssertTrue(op.isInsideSafeZone, "\(op)")
                if case .text(_, _, let font, _, _, let s) = op { XCTAssertLessThanOrEqual(s.count, font.maxChars) }
            }
            // 20 characters is over font 3's 14: drawn in font 2 instead, whole.
            XCTAssertTrue(frame.ops.contains(.text(x: 152, y: form == .full ? 128 : 132, font: .medium, color: 15,
                                                   align: .center, "A VERY LONG HEADLINE")))
        }
        XCTAssertEqual(HUDText.fit("1:45:00", font: .huge).font, .large)          // font 4 never reaches the glasses
        XCTAssertEqual(HUDText.fit("FINISH 1:45:48 PLUS", font: .large).font, .medium)
        XCTAssertEqual(HUDText.fit(String(repeating: "X", count: 30), font: .large).string.count, 28)
        XCTAssertEqual(HUDText.fit(String(repeating: "X", count: 30), font: .large).font, .small)
        XCTAssertEqual(HUDText.fit("NEED 7:49 / MI", font: .large, width: 100).font, .small)
    }

    func testFontLimitsAreTheGlassesLimits() {
        XCTAssertEqual(HUDFont.allCases.map(\.maxChars), [28, 20, 14, 10])
        XCTAssertEqual(HUDFont.allCases.map(\.onGlasses), [.small, .medium, .large, .large])
    }

    func testDistanceTextIsInTheRenderersUnit() {
        XCTAssertEqual(CueFormat.string(.distance(322), unit: .miles), "0.20 MI")
        XCTAssertEqual(CueFormat.string(.distance(322), unit: .kilometers), "0.32 KM")
        XCTAssertEqual(CueFormat.string(.distance(21_097.5), unit: .kilometers), "21.1 KM")
    }
}
