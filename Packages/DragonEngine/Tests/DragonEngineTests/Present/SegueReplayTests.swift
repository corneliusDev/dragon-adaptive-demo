//  SegueReplayTests.swift
//  Chunk 14 acceptance on replayed races through RunEngine, updated every
//  0.25 s as the app's loop would: every predictable cue (splits, fuel,
//  terrain, the kick clock, the pace gap) gets its heads-up 1.5 s (±0.2 s)
//  before it appears, drawn on the glasses (the dot brightens); heart rate
//  and form fade never get one; two cues in a row are separated by the quiet
//  gap; safety and critical cues cut in under every segue and answers appear
//  at once; every presented frame stays inside the safe zone.

import XCTest
import DragonEngine

final class SegueReplayTests: XCTestCase {
    private let mile = DistanceUnit.metersPerMile
    private let lead = SegueConfig().headsUpLead
    private let tolerance = 0.2

    private func isBrightDot(_ f: HUDFrame) -> Bool {
        f.ops.contains(.circf(x: 270, y: 44, r: 3, color: SegueConfig().headsUpDotColor))
    }

    /// Asserts each predictable cue's heads-up began lead ± tolerance before it
    /// appeared, and was on the glasses; returns the kinds seen.
    @discardableResult
    private func assertHeadsUps(_ race: SegueRace, file: StaticString = #filePath, line: UInt = #line) -> Set<CueKind> {
        var kinds: Set<CueKind> = []
        for a in race.appearances where a.cue.key.kind.isPredictable {
            let name = "\(race.profile.name): \(a.cue.key.name) at \(a.row.t)"
            kinds.insert(a.cue.key.kind)
            // The heads-up running on the step before it appeared.
            guard a.index > 0, let h = race.rows[a.index - 1].headsUp, h.key == a.cue.key else {
                XCTFail("\(name): no heads-up before it", file: file, line: line)
                continue
            }
            XCTAssertEqual(a.row.t - h.since, lead, accuracy: tolerance + 1e-9, name, file: file, line: line)
            // On the glasses from its start to the cue.
            let during = race.rows.filter { $0.t >= h.since && $0.t < a.row.t }
            XCTAssertFalse(during.isEmpty, name, file: file, line: line)
            XCTAssertTrue(during.allSatisfy { isBrightDot($0.presented) }, "\(name): the dot brightened", file: file, line: line)
            // And it started then: just before, no heads-up for it.
            if let before = race.rows.last(where: { $0.t < h.since }) {
                XCTAssertNotEqual(before.headsUp?.key, a.cue.key, "\(name): began at \(h.since)", file: file, line: line)
            }
            XCTAssertTrue(race.rows.contains { $0.t == h.since && $0.headsUpBegan }, name, file: file, line: line)
        }
        return kinds
    }

    func testEveryPredictableCueInTheWalkthroughGetsItsHeadsUpOnTime() {
        let race = segueRace(.designWalkthrough)
        let kinds = assertHeadsUps(race)
        XCTAssertTrue(kinds.isSuperset(of: [.split, .fuel, .terrain, .kickClock, .paceGap]), "\(kinds)")
    }

    func testEveryPredictableCueInTheHillyRaceGetsItsHeadsUpOnTime() {
        let race = segueRace(.hilly)
        let kinds = assertHeadsUps(race)
        XCTAssertTrue(kinds.isSuperset(of: [.split, .terrain, .kickClock]), "\(kinds)")
    }

    func testMostHeadsUpsComeFromTheTriggersHintsSoTheCueIsntHeldBack() {
        // Announced ahead, a cue shows the moment its trigger proposes it.
        for profile in [SyntheticProfile.designWalkthrough, .hilly] {
            let race = segueRace(profile)
            let predictable = race.appearances.filter { $0.cue.key.kind.isPredictable }
            let onArrival = predictable.filter { $0.row.t - $0.cue.createdAt < 0.3 }
            XCTAssertGreaterThanOrEqual(Double(onArrival.count), 0.6 * Double(predictable.count),
                                        "\(profile.name): \(onArrival.count) of \(predictable.count) on arrival")
        }
    }

    func testHeartRateAndFormFadeNeverGetAHeadsUp() {
        let walkthrough = segueRace(.designWalkthrough)
        XCTAssertFalse(walkthrough.appearances.filter { $0.cue.key == .heartCeiling }.isEmpty, "the walkthrough's heart cue")
        let glances = stride(from: 4_200.0, through: 6_000, by: 120).map {
            RunEvent.attention(AttentionSample(t: $0, event: .glance))
        }
        let fade = segueRace(.slowFade(from: 9 * mile), extra: glances)
        XCTAssertFalse(fade.appearances.filter { $0.cue.key == .formFade }.isEmpty, "the form cue")
        for race in [walkthrough, fade] {
            XCTAssertFalse(race.rows.contains { $0.headsUp?.key == .heartCeiling || $0.headsUp?.key == .formFade })
            // They appear the step they win, with nothing warning of them.
            for a in race.appearances where a.cue.key == .heartCeiling || a.cue.key == .formFade {
                XCTAssertEqual(a.row.t - a.cue.createdAt, 0, accuracy: 1e-9, a.cue.key.name)
            }
        }
    }

    func testTwoCuesInARowAreSeparatedByTheQuietGap() {
        let gap = SegueConfig().quietGap
        var checked = 0
        for profile in [SyntheticProfile.designWalkthrough, .hilly] {
            let race = segueRace(profile)
            let departures = race.departures
            for a in race.appearances where !(a.cue.priority >= .critical || a.cue.requested) {
                guard let last = departures.last(where: { $0.t <= a.row.t && $0.key != a.cue.key }) else { continue }
                // Nothing showed in between: the screen was free.
                guard !race.appearances.contains(where: { $0.row.t > last.t && $0.row.t < a.row.t }) else { continue }
                XCTAssertGreaterThanOrEqual(a.row.t - last.t, gap - 1e-9, "\(profile.name): \(a.cue.key.name) at \(a.row.t)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 10)
    }

    func testSafetyAndCriticalCutInAndAnswersAppearAtOnceUnderEverySegue() {
        for segue in Segue.allCases {
            var config = RunEngine.Config()
            config.segue = segue
            let race = segueRace(.designWalkthrough, step: 1, config: config)
            var urgent = 0, answers = 0
            for a in race.appearances where a.cue.priority >= .critical || a.cue.requested {
                // The step it appears, the glasses show it whole: every op of the target, at full level.
                let target = a.row.target.ops.filter { $0.bounds != nil }
                XCTAssertTrue(target.allSatisfy(a.row.presented.ops.contains)
                              && FrameDiff.luma(a.row.presented) == FrameDiff.luma(a.row.target),
                              "\(segue): \(a.cue.key.name) at \(a.row.t)")
                if a.cue.requested { answers += 1 } else { urgent += 1 }
            }
            XCTAssertGreaterThanOrEqual(urgent, 4, "\(segue): pace gap, heart rate, fuel, kick clock")
            XCTAssertGreaterThanOrEqual(answers, 3, "\(segue): the glances and the held look")
            // An advisory split eases in (except instant): the first frame is not the whole target.
            if let s = race.appearances.first(where: { $0.cue.key.kind == .split }) {
                let whole = s.row.target.ops.filter { $0.bounds != nil }.allSatisfy(s.row.presented.ops.contains)
                    && FrameDiff.luma(s.row.presented) == FrameDiff.luma(s.row.target)
                XCTAssertEqual(whole, segue == .instant, "\(segue): split")
            }
        }
    }

    func testThePresentedFramesPlayTheFadeAndStayInsideTheSafeZone() {
        let race = segueRace(.designWalkthrough)
        guard let s = race.appearances.first(where: { $0.cue.key.kind == .split }) else { return XCTFail("no split") }
        // 0.25 s updates: the fade's steps at 0, 0.1, 0.2, 0.3 s are sampled at 0 and 0.25 (level 1/4, 3/4), then whole.
        let main = { (f: HUDFrame) -> UInt8? in
            f.ops.compactMap { op -> UInt8? in if case .text(_, _, .large, let c, _, _) = op { return c } else { return nil } }.first
        }
        let levels = race.rows[s.index...].prefix(3).map { main($0.presented) }
        XCTAssertEqual(levels, [4, 11, 15])
        for row in race.rows {
            for op in row.presented.ops where !op.isInsideSafeZone {
                XCTFail("t=\(row.t): \(op) outside the safe zone")
            }
            for case .text(_, _, let font, _, _, let str) in row.presented.ops where str.count > font.maxChars {
                XCTFail("t=\(row.t): \(str) over font \(font.rawValue)'s limit")
            }
        }
    }

    func testHeadsUpOffMeansNoHeadsUpAndNoWait() {
        var config = RunEngine.Config()
        config.headsUp = []
        let race = segueRace(.hilly, step: 1, config: config)
        XCTAssertFalse(race.rows.contains { $0.headsUp != nil })
        for a in race.appearances where a.cue.key.kind == .terrain {
            XCTAssertEqual(a.row.t - a.cue.createdAt, 0, accuracy: 1e-9, "shows the step it is proposed")
        }
    }
}

/// RunEngine's settings: changed mid-race, the next change uses them; the
/// LED blinks through each heads-up when ledBlink is on, and a heads-up's
/// start is flagged once (where the app sends the Watch tap).
final class RunEngineSegueSettingsTests: XCTestCase {
    func testSettingsChangeMidRaceAndTheLedBlinksThroughEachHeadsUp() {
        var config = RunEngine.Config()
        config.headsUp = [.ledBlink, .watchTap]
        let race = segueRace(.hilly, config: config)
        let heads = race.rows.filter { $0.headsUp != nil }
        XCTAssertFalse(heads.isEmpty)
        XCTAssertTrue(heads.allSatisfy { FrameDiff.led($0.presented) == .blink })
        XCTAssertTrue(race.rows.filter { $0.headsUp == nil }.allSatisfy { FrameDiff.led($0.presented) == .off })
        // No dot pulse: the dot (when drawn) stays dim.
        XCTAssertFalse(race.rows.contains { $0.presented.ops.contains(.circf(x: 270, y: 44, r: 3, color: 15)) })
        // One start per heads-up.
        let starts = race.rows.filter(\.headsUpBegan)
        XCTAssertEqual(starts.count, Set(heads.map { "\($0.headsUp!.key.name)@\($0.headsUp!.since)" }).count)

        var engine = RunEngine(plan: race.engine.plan)
        XCTAssertEqual(engine.segue, .fade)
        XCTAssertEqual(engine.headsUp, [.dotPulse])
        engine.segue = .glow
        engine.headsUp = []
        XCTAssertEqual(engine.arbiter.config.headsUpLead, 0, "off: nothing waits for a heads-up")
        engine.headsUp = [.edgeTick]
        XCTAssertEqual(engine.arbiter.config.headsUpLead, 1.5)
        var tuned = SegueConfig()
        tuned.quietGap = 3
        tuned.headsUpLead = 2
        engine.segueConfig = tuned
        XCTAssertEqual(engine.arbiter.config.quietGap, 3)
        XCTAssertEqual(engine.arbiter.config.headsUpLead, 2)
        XCTAssertEqual(engine.presentation.segue, .glow)
    }
}
