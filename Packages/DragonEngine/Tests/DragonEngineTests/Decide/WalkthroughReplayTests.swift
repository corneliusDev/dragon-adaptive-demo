//  WalkthroughReplayTests.swift
//  Chunk 9 acceptance: the design page's example race (City Half Marathon,
//  1:45:00 target, 8:01 / mi even) replayed through RunEngine, one row per
//  moment of the walkthrough: what showed (or nothing), the budget, the
//  screen's text and what the other triggers did.
//
//  The synthetic race is the design's where the committed replay tests allow
//  it (SyntheticProfile.walkthroughPace says how). Where its numbers can't be
//  the design's, the kind of cue and the decision are asserted exactly and the
//  number within a tolerance given on that line, with the reason. The
//  tolerances, all in one place:
//
//      where                      design      tolerance  why
//      mile 1 split               8:14 +0:13  ±6 s       ours 8:09 +0:08; a slower mile 1 trips the pace gap
//      projection, mile 1–4.2     +0:13 …     ±10 s      ours also counts the hill's cost from the start
//      glance at 4.2 mi           1:45:01     ±10 s      ours 1:44:53 (-0:07): still "ON PLAN"
//      hill notice                7:55 mi     ±0.3 mi    the hill starts at 7.43 mi (centred near 7.6 by the
//                                 1:00:43     ±210 s     committed walkthrough test) and the runner is ahead
//      hill notice distance       0.2 MI      150–250 m  0.2 mi (322 m) is outside the trigger's own window
//      heart rate                 HR 178      ±5 bpm     ours 176
//      behind plan                +0:48       ±35 s      ours +0:19: the cue fires once the gap passes 15 s,
//                                 1:45:48     ±35 s      and the race must still finish 1:44:29 with mile 12
//                                 NEED 7:53   ±35 s/mi   slower than plan (both committed walkthrough tests)
//      held-look splits           7:44 7:58 8:14  ±20 s  ours 7:35 7:51 8:31 (fade timing)
//      held look NEED / PROJ      7:49, +0:22 ±40 s / ±50 s  the design race is behind at 11.2 mi, ours ahead
//      kick clock time left       1:38        ±15 s
//      finish                     1:44:29 -0:31  ±5 s     ours 1:44:33 -0:27 (the estimate's crossing)
//      finish shown at            1:44:29     ±12 s      a crossing noticed by position stands 5 s first
//      kick clock, ahead / behind cue, held look: run time ±120 s, mile ±0.1 (detail ±0.02)
//
//  Budgets the design states that the engine's (committed) capacity table
//  doesn't give, asserted as the engine has them and reported as needing a
//  decision: "1 element · advisory and up" at miles 9.4 and 10.5 (the table
//  says 2 for steady race effort, and the design draws both screens in full,
//  which needs 2), "3 elements" for the held look (2 + 2), and "3 elements"
//  before the gun (3 + the glance's 1).

import XCTest
import DragonEngine

final class WalkthroughReplayTests: XCTestCase {
    private static let mile = DistanceUnit.metersPerMile

    /// One line of the screen: the design's text and how ours must match it.
    struct Line {
        let design: String
        /// Ours, as a whole-line pattern; each capture group is a clock or a
        /// signed m:ss (or a plain number) compared with the design's same group.
        let pattern: String
        let within: Double

        static func same(_ s: String) -> Line { Line(design: s, pattern: NSRegularExpression.escapedPattern(for: s), within: 0) }
    }

    struct Moment {
        let name: String
        /// The design's "mi … · h:mm:ss".
        let mile: Double
        let time: TimeInterval
        let mileWithin: Double
        let timeWithin: TimeInterval
        /// The row the moment is about.
        let row: (CueRace) -> CueRace.Row?
        /// What is on screen there (nil: nothing, the status dot).
        let shows: CueKind?
        let budget: (elements: Int, minPriority: Priority, situation: Capacity.Situation)
        let screen: [Line]
        /// The other triggers' part (the design's "what each trigger proposed").
        let also: (CueRace, CueRace.Row) -> Void
    }

    private static func first(_ kind: CueKind, where ok: @escaping (CueRace.Row) -> Bool = { _ in true })
        -> (CueRace) -> CueRace.Row? {
        { race in race.appearances(kind: kind).first(where: ok) }
    }

    private static func at(mile m: Double) -> (CueRace) -> CueRace.Row? {
        { race in race.rows.first { $0.trueDistance >= m * mile } }
    }

    private static func proposed(_ race: CueRace, _ kind: CueKind, from: TimeInterval, to: TimeInterval) -> [Cue] {
        race.rows.filter { $0.t >= from && $0.t <= to }.flatMap(\.proposed).filter { $0.key.kind == kind }
    }

    private static func shown(_ race: CueRace, _ kind: CueKind, from: TimeInterval, to: TimeInterval) -> [CueRace.Row] {
        race.appearances(kind: kind).filter { $0.t >= from && $0.t <= to }
    }

    static let clock = #"(\d+:\d\d(?::\d\d)?)"#
    static let signed = #"([+-]\d+:\d\d)"#

    static let moments: [Moment] = [
        Moment(name: "1 Before the gun", mile: 0, time: 0, mileWithin: 0, timeWithin: 0,
               row: { $0.rows.first }, shows: .target,
               // Design: 3 elements; the glance that asked adds its 1.
               budget: (4, .info, .standing),
               screen: [.same("TARGET"), .same("1:45:00"),
                        // The renderer's phrase has no "·" (chunk 7's gallery text).
                        Line(design: "8:01 / MI · EVEN", pattern: #"8:01 / MI EVEN"#, within: 0),
                        .same("GLANCE FOR STATUS")],
               also: { race, row in
                   XCTAssertEqual(race.rows.filter { $0.current?.key == .target }.count, 4, "the target for 4 s")
                   XCTAssertFalse(row.proposed.contains { $0.key.kind == .split }, "no marker yet")
               }),
        Moment(name: "2 Mile 1", mile: 1.0, time: 494, mileWithin: 0.02, timeWithin: 10,
               row: first(.split), shows: .split,
               budget: (2, .advisory, .raceEffort),
               screen: [.same("MILE 1"), Line(design: "8:14", pattern: clock, within: 6),
                        Line(design: "+0:13 VS PLAN", pattern: signed + " VS PLAN", within: 6), .same("SPLIT")],
               also: { race, row in
                   XCTAssertEqual(race.rows.filter { $0.current?.key == .split(mile: 1) }.count, 3, "the split for 3 s")
                   // PaceGap held: a few seconds behind is not a problem.
                   XCTAssertTrue(proposed(race, .paceGap, from: 0, to: row.t).isEmpty)
                   XCTAssertEqual(row.state.gapToTarget ?? 99, 13, accuracy: 10)
                   // HeartCeiling: zone 3 is expected.
                   XCTAssertEqual(row.state.heartZone, 3)
                   XCTAssertTrue(proposed(race, .heartCeiling, from: 0, to: row.t).isEmpty)
               }),
        Moment(name: "3 Settled in", mile: 2.4, time: 1_160, mileWithin: 0.01, timeWithin: 15,
               row: at(mile: 2.4), shows: nil,
               budget: (2, .advisory, .raceEffort),
               screen: [],
               also: { race, row in
                   // Nothing to say from the mile 2 split until the glance at 4.2.
                   let quiet = race.rows.filter { $0.trueDistance > 2.05 * mile && $0.trueDistance < 4.15 * mile }
                   XCTAssertTrue(quiet.allSatisfy { $0.current == nil || $0.current?.key == .split(mile: 3)
                       || $0.current?.key == .split(mile: 4) })
                   XCTAssertEqual(row.state.gapToTarget ?? 99, 7, accuracy: 10)
                   XCTAssertEqual(row.state.heartZone, 3)
                   XCTAssertTrue(row.proposed.isEmpty)
               }),
        Moment(name: "4 A glance", mile: 4.2, time: 2_019, mileWithin: 0.02, timeWithin: 30,
               row: first(.status), shows: .status,
               budget: (3, .advisory, .raceEffort),
               screen: [.same("PROJECTED FINISH"), Line(design: "1:45:01", pattern: clock, within: 10),
                        Line(design: "+0:01 ON PLAN", pattern: signed + " ON PLAN", within: 10), .same("STATUS")],
               also: { race, row in
                   XCTAssertTrue(row.budget.answersRequests, "the glance's answer gets through")
                   XCTAssertLessThanOrEqual(race.rows.filter { $0.current?.key == .status }.count, 2, "1.5 s")
                   // Fuel: due at 0:45:00, not yet.
                   XCTAssertTrue(proposed(race, .fuel, from: 0, to: row.t).isEmpty)
               }),
        Moment(name: "5 Fuel", mile: 5.62, time: 2_700, mileWithin: 0.1, timeWithin: 0,
               row: first(.fuel), shows: .fuel,
               budget: (2, .advisory, .raceEffort),
               screen: [.same("GEL NOW"), .same("FUEL 1 OF 2"), .same("FUEL")],
               also: { race, row in
                   // Repeated once in 2 min: not acknowledged.
                   XCTAssertEqual(race.appearances(.fuel(1)).map(\.t), [2_700, 2_820])
                   XCTAssertEqual(race.rows.filter { $0.current?.key == .fuel(1) }.count, 12, "6 s each")
                   XCTAssertFalse(row.proposed.contains { $0.key.kind == .split })
               }),
        Moment(name: "6 Hill ahead", mile: 7.55, time: 3_643, mileWithin: 0.3, timeWithin: 210,
               row: first(.terrain), shows: .terrain,
               budget: (2, .advisory, .raceEffort),
               screen: [Line(design: "HILL 0.2 MI", pattern: #"HILL (0\.\d\d) MI"#, within: 0.11),
                        .same("HOLD EFFORT"), .same("TERRAIN")],
               also: { race, row in
                   let hill = race.plan.course!.hills()[0]
                   let ahead = hill.startDistance - row.state.distance
                   XCTAssertTrue((150...250).contains(ahead), "\(ahead) m before the climb")
                   XCTAssertEqual(race.rows.filter { $0.current?.key.kind == .terrain }.count, 4, "the notice for 4 s")
                   // PaceGap held: nothing to say about pace here.
                   XCTAssertTrue(shown(race, .paceGap, from: row.t - 60, to: row.t + 60).isEmpty)
               }),
        Moment(name: "7 On the climb", mile: 7.95, time: 3_851, mileWithin: 0.01, timeWithin: 210,
               row: at(mile: 7.95), shows: nil,
               budget: (1, .critical, .climbing),
               screen: [],
               also: { race, row in
                   let hill = race.plan.course!.hills()[0]
                   let climb = race.rows.filter { $0.state.distance > hill.startDistance && $0.state.distance < hill.endDistance }
                   XCTAssertTrue(climb.allSatisfy { $0.current == nil }, "quiet on the climb")
                   // PaceGap held (the grade-adjusted pace is on plan); HeartCeiling: zone 4 is expected.
                   XCTAssertEqual(row.state.heartZone, 4)
                   XCTAssertTrue(climb.flatMap(\.proposed).filter { $0.key == .paceGap || $0.key == .heartCeiling }.isEmpty)
                   // Split held: mile 8 falls on the climb and waits for the top.
                   let mile8 = CueKey.split(mile: 8)
                   XCTAssertGreaterThan(8 * mile, hill.startDistance)
                   XCTAssertLessThan(8 * mile, hill.endDistance)
                   guard let split = race.proposals(mile8).first else { return XCTFail("no mile 8 split") }
                   XCTAssertEqual(split.cue.deferUntil, .distance(hill.endDistance), "mile 8 deferred to the crest")
                   // Held back (by the climb's budget first, then its deferral) until it shows.
                   let waiting = race.rows.filter { $0.t >= split.row.t }.prefix { $0.current?.key != mile8 }
                   XCTAssertFalse(waiting.isEmpty)
                   XCTAssertTrue(waiting.allSatisfy { row in
                       row.decisions.filter { $0.key == mile8 }.allSatisfy { $0.outcome == .heldBack }
                   })
                   guard let crest = race.rows.first(where: { $0.state.distance >= hill.endDistance }),
                         let top = race.appearances(mile8).first else { return XCTFail("mile 8 never shown") }
                   XCTAssertGreaterThanOrEqual(top.t, crest.t)
                   XCTAssertLessThanOrEqual(top.t - crest.t, 20)
                   XCTAssertEqual(top.texts.first, "MILE 8")
               }),
        Moment(name: "8 Heart rate high", mile: 9.4, time: 4_532, mileWithin: 0.1, timeWithin: 120,
               row: first(.heartCeiling), shows: .heartCeiling,
               // Design: "1 element · advisory and up" (not a row of its own table).
               budget: (2, .advisory, .raceEffort),
               screen: [.same("!"), Line(design: "HR 178 · Z5", pattern: #"HR (\d+) Z5"#, within: 5),
                        .same("EASE 5 SEC/MI"), .same("HEART")],
               also: { race, row in
                   XCTAssertEqual(row.state.heartZone, 5)
                   XCTAssertGreaterThan(row.trueDistance / race.plan.distanceMeters, 0.7)
                   XCTAssertLessThan(row.trueDistance / race.plan.distanceMeters, 0.75)
                   XCTAssertEqual(race.rows.filter { $0.current?.key == .heartCeiling }.count, 5, "5 s")
                   XCTAssertEqual(race.proposals(.heartCeiling).filter { $0.row.t < race.finishTime - 120 }.count, 1)
                   // PaceGap: nothing to say about pace.
                   XCTAssertTrue(proposed(race, .paceGap, from: row.t - 60, to: row.t + 60).isEmpty)
               }),
        Moment(name: "9 Falling behind", mile: 10.5, time: 5_066, mileWithin: 0.1, timeWithin: 120,
               row: first(.paceGap, where: { $0.texts.first == "BEHIND PLAN" }), shows: .paceGap,
               budget: (2, .advisory, .raceEffort),
               screen: [.same("BEHIND PLAN"), Line(design: "+0:48", pattern: signed, within: 35),
                        Line(design: "FINISH 1:45:48", pattern: "FINISH " + clock, within: 35),
                        Line(design: "NEED 7:53 / MI", pattern: "NEED " + clock + " / MI", within: 35)],
               also: { race, row in
                   XCTAssertEqual(race.rows.filter { $0.current?.key == .paceGap && $0.t >= row.t }.prefix(10).count, 5)
                   // No pace cue for 90 s after.
                   XCTAssertTrue(shown(race, .paceGap, from: row.t + 1, to: row.t + 90).isEmpty)
                   // FormFade held: cadence down ~4%, under the 5% line.
                   XCTAssertTrue(race.proposals(.formFade).isEmpty)
                   let base = race.rows.filter { $0.state.distance > 0.1 * race.plan.distanceMeters
                       && $0.state.distance < 0.5 * race.plan.distanceMeters }.compactMap(\.state.cadence)
                   let now = race.rows.filter { $0.t > row.t - 60 && $0.t <= row.t }.compactMap(\.state.cadence)
                   let drop = 1 - now.reduce(0, +) / Double(now.count) / (base.reduce(0, +) / Double(base.count))
                   XCTAssertGreaterThan(drop, 0.02)
                   XCTAssertLessThan(drop, 0.05)
               }),
        Moment(name: "10 A held look", mile: 11.2, time: 5_405, mileWithin: 0.02, timeWithin: 120,
               row: first(.detail), shows: .detail,
               // Design: "3 elements for 2.6 s"; the steady row's 2 and the held look's 2.
               budget: (4, .advisory, .raceEffort),
               screen: [.same("LAST 3 SPLITS"),
                        Line(design: "MI 9", pattern: "MILE 9", within: 0), Line(design: "7:44", pattern: clock, within: 20),
                        Line(design: "MI 10", pattern: "MILE 10", within: 0), Line(design: "7:58", pattern: clock, within: 20),
                        Line(design: "MI 11", pattern: "MILE 11", within: 0), Line(design: "8:14", pattern: clock, within: 20),
                        Line(design: "NEED 7:49", pattern: "NEED " + clock + " / MI", within: 40),
                        Line(design: "PROJ 1:45:22 · +0:22", pattern: "PROJ " + clock + " " + signed, within: 50)],
               also: { race, row in
                   XCTAssertEqual(race.rows.filter { $0.current?.key == .detail }.count, 3, "2.6 s")
                   // PaceGap held: nothing new to say about pace.
                   XCTAssertTrue(shown(race, .paceGap, from: row.t - 90, to: row.t + 30).isEmpty)
               }),
        Moment(name: "11 Final kick", mile: 12.95, time: 6_202, mileWithin: 0.01, timeWithin: 120,
               row: at(mile: 12.95), shows: .kickClock,
               budget: (0, .safety, .finalStretch),
               // The empty budget draws the reduced kick clock (chunk 7): heading and time;
               // the design's third line, "LEFT · 0.16 MI", is in the cue but not drawn.
               screen: [.same("TO BEAT 1:45:00"), Line(design: "1:38", pattern: clock, within: 15)],
               also: { race, row in
                   XCTAssertEqual(row.state.phase, .kick)
                   XCTAssertEqual(row.current.flatMap { $0.content.subtitle.first }.map {
                       CueFormat.string($0, unit: .miles, now: CueFormat.Now(row.state))
                   }?.hasPrefix("LEFT 0.1"), true)
                   // Only the kick clock from 0.25 mi out; HeartCeiling held (zone 5 is expected in a kick).
                   let kickFrom = race.plan.distanceMeters - 0.25 * mile
                   let stretch = race.rows.filter { $0.trueDistance >= kickFrom && $0.t <= race.finishTime }
                   XCTAssertTrue(stretch.dropFirst().allSatisfy { $0.current?.key == .kickClock })
                   XCTAssertEqual(row.state.heartZone, 5)
                   let dropped = stretch.flatMap(\.decisions).filter { $0.key != .kickClock }
                   XCTAssertTrue(dropped.allSatisfy { $0.reason == .finalStretch }, "\(dropped.map(\.reason))")
               }),
        Moment(name: "12 Finish", mile: 13.11, time: 6_269, mileWithin: 0.01, timeWithin: 12,
               row: first(.finish), shows: .finish,
               budget: (3, .info, .finished),
               screen: [Line(design: "1:44:29", pattern: clock, within: 5),
                        Line(design: "TARGET MET · −0:31", pattern: "TARGET MET " + signed, within: 5), .same("FINISH")],
               also: { race, row in
                   XCTAssertGreaterThan(row.t, race.finishTime)
                   let up = race.rows.filter { $0.current?.key == .finish }
                   XCTAssertEqual(up.count, 10, "the result for 10 s")
                   let after = race.rows.filter { $0.t > up.last!.t }
                   XCTAssertFalse(after.isEmpty)
                   XCTAssertTrue(after.allSatisfy { $0.current == nil && $0.frame.ops.count == 2 }, "then dark")
               }),
    ]

    func testTheDesignWalkthroughReplaysMomentByMoment() {
        let race = cueRace(.designWalkthrough, atGun: true, afterFinish: 20)
        let mile = WalkthroughReplayTests.mile
        for m in WalkthroughReplayTests.moments {
            guard let row = m.row(race) else { XCTFail("\(m.name): never happened"); continue }
            // When and where.
            XCTAssertEqual(row.trueDistance / mile, m.mile, accuracy: max(m.mileWithin, 0.005), "\(m.name): mile")
            XCTAssertEqual(row.t, m.time, accuracy: max(m.timeWithin, 1), "\(m.name): run time")
            // What showed.
            XCTAssertEqual(row.current?.key.kind, m.shows, "\(m.name): on screen")
            if m.shows == nil {
                XCTAssertTrue(row.texts.isEmpty, "\(m.name): \(row.texts)")
                XCTAssertTrue(row.frame.ops.contains { if case .circf = $0 { return true }; return false },
                              "\(m.name): the status dot")
            }
            // The budget.
            XCTAssertEqual(row.budget.maxElements, m.budget.elements, "\(m.name): elements")
            XCTAssertEqual(row.budget.minPriority, m.budget.minPriority, "\(m.name): lowest priority")
            XCTAssertEqual(row.situation, m.budget.situation, "\(m.name): situation")
            // The screen.
            XCTAssertEqual(row.texts.count, m.screen.count, "\(m.name): \(row.texts)")
            for (line, ours) in zip(m.screen, row.texts) {
                check(line, ours, m.name)
            }
            m.also(race, row)
        }
    }

    private func check(_ line: Line, _ ours: String, _ name: String) {
        guard let re = try? NSRegularExpression(pattern: "^" + line.pattern + "$"),
              let match = re.firstMatch(in: ours, range: NSRange(ours.startIndex..., in: ours)) else {
            return XCTFail("\(name): \"\(ours)\" doesn't read like \"\(line.design)\"")
        }
        guard match.numberOfRanges > 1 else { return }
        let designNumbers = WalkthroughReplayTests.numbers(in: line.design)
        for g in 1..<match.numberOfRanges {
            guard let r = Range(match.range(at: g), in: ours) else { continue }
            let value = WalkthroughReplayTests.value(String(ours[r]))
            guard g - 1 < designNumbers.count else { return XCTFail("\(name): no design value for \(ours)") }
            XCTAssertEqual(value, designNumbers[g - 1], accuracy: line.within,
                           "\(name): \"\(ours)\" vs the design's \"\(line.design)\"")
        }
    }

    /// The numbers in the design's text, in order: clocks and signed m:ss as seconds, plain decimals as they are.
    static func numbers(in s: String) -> [Double] {
        let re = try! NSRegularExpression(pattern: #"[+−-]?\d+(?::\d\d)+|\d+\.\d+|\d+"#)
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            Range(m.range, in: s).map { value(String(s[$0])) }
        }
    }

    /// "1:45:01" → 6301, "-0:31" / "−0:31" → -31, "0.16" → 0.16, "178" → 178.
    static func value(_ s: String) -> Double {
        var t = s.replacingOccurrences(of: "−", with: "-")
        var sign = 1.0
        if t.hasPrefix("-") { sign = -1; t.removeFirst() } else if t.hasPrefix("+") { t.removeFirst() }
        guard t.contains(":") else { return sign * (Double(t) ?? .nan) }
        return sign * t.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? .nan) }
    }
}
