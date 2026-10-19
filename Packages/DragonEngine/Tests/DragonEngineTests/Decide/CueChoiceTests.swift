//  CueChoiceTests.swift
//  The placeholder choice, and the minimal render of what it picks.

import XCTest
import DragonEngine

final class CueChoiceTests: XCTestCase {
    private func cue(_ key: CueKey, _ priority: Priority, at t: TimeInterval, show: TimeInterval = 3,
                     expires: TimeInterval = 20) -> Cue {
        Cue(key: key, priority: priority, content: CueContent(main: .label("X")),
            createdAt: t, expiresAt: t + expires, minShow: show)
    }

    func testHighestPriorityWinsAndACueStaysForItsMinimumTime() {
        var choice = CueChoice()
        let split = cue(.split(mile: 1), .advisory, at: 0)
        let gap = cue(.paceGap, .critical, at: 0, show: 5)
        XCTAssertEqual(choice.update(proposed: [split, gap], at: 0)?.key, .paceGap)
        XCTAssertEqual(choice.update(proposed: [], at: 4.9)?.key, .paceGap)
        XCTAssertEqual(choice.update(proposed: [], at: 5)?.key, .split(mile: 1))
        XCTAssertEqual(choice.update(proposed: [], at: 7.9)?.key, .split(mile: 1))
        XCTAssertNil(choice.update(proposed: [], at: 8))
    }

    func testMoreImportantCueInterruptsButAnEqualOneWaits() {
        var choice = CueChoice()
        XCTAssertEqual(choice.update(proposed: [cue(.split(mile: 1), .advisory, at: 0)], at: 0)?.key, .split(mile: 1))
        XCTAssertEqual(choice.update(proposed: [cue(.split(mile: 2), .advisory, at: 1)], at: 1)?.key, .split(mile: 1))
        XCTAssertEqual(choice.update(proposed: [cue(.paceGap, .critical, at: 2)], at: 2)?.key, .paceGap)
        XCTAssertEqual(choice.update(proposed: [], at: 5)?.key, .split(mile: 2))
    }

    func testStaleCueIsSkippedNotShownLate() {
        var choice = CueChoice()
        _ = choice.update(proposed: [cue(.paceGap, .critical, at: 0, show: 30)], at: 0)
        _ = choice.update(proposed: [cue(.split(mile: 1), .advisory, at: 1)], at: 1)
        XCTAssertEqual(choice.update(proposed: [], at: 25)?.key, .paceGap)
        XCTAssertNil(choice.update(proposed: [], at: 30))
        XCTAssertTrue(choice.waiting.isEmpty)
    }

    func testRenderKeepsTextInsideTheSafeZone() {
        let cues = [
            Cue(key: .split(mile: 12), priority: .advisory,
                content: CueContent(heading: .marker(12, .miles), main: .duration(494),
                                    subtitle: [.phrase([.gap(13), .label("VS PLAN")])], tag: "SPLIT"),
                createdAt: 0, expiresAt: 20, minShow: 3),
            Cue(key: .paceGap, priority: .critical,
                content: CueContent(heading: .label("BEHIND PLAN"), main: .gap(48),
                                    subtitle: [.phrase([.label("FINISH"), .duration(6_348)]),
                                               .phrase([.label("NEED"), .pace(473 / DistanceUnit.metersPerMile, .miles)])]),
                createdAt: 0, expiresAt: 30, minShow: 5),
        ]
        for c in cues {
            let frame = CueRenderer.frame(for: c, effort: .hard)
            var texts: [String] = []
            for op in frame.ops {
                guard case .text(let x, let y, let font, _, let align, let s) = op else { continue }
                texts.append(s)
                let width = s.count * font.advance
                let left = align == .center ? x - width / 2 : x
                XCTAssertGreaterThanOrEqual(left, Display.safeMinX, s)
                XCTAssertLessThanOrEqual(left + width, Display.safeMaxX, s)
                XCTAssertGreaterThanOrEqual(y, Display.safeMinY, s)
                XCTAssertLessThanOrEqual(y, Display.safeMaxY, s)
            }
            if c.key == .paceGap {
                XCTAssertEqual(texts, ["BEHIND PLAN", "+0:48", "FINISH 1:45:48", "NEED 7:53 / MI"])
            } else {
                XCTAssertEqual(texts, ["MILE 12", "8:14", "+0:13 VS PLAN", "SPLIT"])
            }
        }
        // Nothing to show: the quiet dot, no text.
        let quiet = CueRenderer.frame(for: nil)
        XCTAssertFalse(quiet.ops.contains { if case .text = $0 { return true } else { return false } })
        XCTAssertTrue(quiet.ops.contains { if case .circf = $0 { return true } else { return false } })
    }
}
