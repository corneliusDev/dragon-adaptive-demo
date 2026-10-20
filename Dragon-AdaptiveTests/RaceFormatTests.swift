//  RaceFormatTests.swift
//  The phone screens' numbers: paces, times and distances in miles and
//  kilometres, including times over an hour, and parsing what the runner types.

import XCTest
import DragonEngine
@testable import Dragon_Adaptive

final class RaceFormatTests: XCTestCase {
    func testClockUnderAndOverAnHour() {
        XCTAssertEqual(RaceFormat.clock(0), "0:00")
        XCTAssertEqual(RaceFormat.clock(59.9), "0:59")
        XCTAssertEqual(RaceFormat.clock(1_500), "25:00")
        XCTAssertEqual(RaceFormat.clock(3_599), "59:59")
        XCTAssertEqual(RaceFormat.clock(3_600), "1:00:00")
        XCTAssertEqual(RaceFormat.clock(6_269.4), "1:44:29")
        XCTAssertEqual(RaceFormat.clock(36_005), "10:00:05")
        XCTAssertEqual(RaceFormat.clock(-3), "0:00")
    }

    func testGapIsSignedAndKeepsHours() {
        XCTAssertEqual(RaceFormat.gap(48), "+0:48")
        XCTAssertEqual(RaceFormat.gap(-31), "-0:31")
        XCTAssertEqual(RaceFormat.gap(0.4), "+0:00")
        XCTAssertEqual(RaceFormat.gap(-605), "-10:05")
        XCTAssertEqual(RaceFormat.gap(3_723), "+1:02:03")
    }

    func testParseDuration() {
        XCTAssertEqual(RaceFormat.parseDuration("1:45:00"), 6_300)
        XCTAssertEqual(RaceFormat.parseDuration(" 25:00 "), 1_500)
        XCTAssertEqual(RaceFormat.parseDuration("3:30:15"), 12_615)
        XCTAssertEqual(RaceFormat.parseDuration("90"), 90)
        XCTAssertEqual(RaceFormat.parseDuration("8:01"), 481)
        XCTAssertNil(RaceFormat.parseDuration(""))
        XCTAssertNil(RaceFormat.parseDuration("1:75:00"))
        XCTAssertNil(RaceFormat.parseDuration("1:45:00:00"))
        XCTAssertNil(RaceFormat.parseDuration("abc"))
        XCTAssertNil(RaceFormat.parseDuration("1::00"))
    }

    func testPacesPerMileAndKilometre() {
        let half = 6_300 / SyntheticProfile.halfMarathon        // s/m
        XCTAssertEqual(RaceFormat.pace(half, unit: .miles), "8:01 /mi")
        XCTAssertEqual(RaceFormat.pace(half, unit: .kilometers), "4:59 /km")
        XCTAssertEqual(RaceFormat.pace(180 / DistanceUnit.metersPerMile, unit: .miles), "3:00 /mi")
        XCTAssertEqual(RaceFormat.pace(1_200 / DistanceUnit.metersPerMile, unit: .miles), "20:00 /mi")
        XCTAssertEqual(RaceFormat.pace(nil, unit: .miles), "—")
        XCTAssertEqual(RaceFormat.paceValue(perUnit: 481), "8:01")
        XCTAssertEqual(RaceFormat.paceValue(perUnit: 59.6), "1:00")
    }

    func testDistancesInMilesAndKilometres() {
        XCTAssertEqual(RaceFormat.distance(SyntheticProfile.halfMarathon, unit: .miles), "13.1 mi")
        XCTAssertEqual(RaceFormat.distance(SyntheticProfile.halfMarathon, unit: .kilometers), "21.1 km")
        XCTAssertEqual(RaceFormat.distance(42_195, unit: .miles), "26.2 mi")
        XCTAssertEqual(RaceFormat.distance(5_000, unit: .kilometers), "5 km")
        XCTAssertEqual(RaceFormat.distance(5_000, unit: .miles), "3.1 mi")
        XCTAssertEqual(RaceFormat.distanceValue(10.5 * DistanceUnit.metersPerMile, unit: .miles), "10.50")
        XCTAssertEqual(RaceFormat.distanceValue(16_898, unit: .kilometers), "16.90")
        XCTAssertEqual(RaceFormat.marker(5.63 * DistanceUnit.metersPerMile, unit: .miles), "5.6")
        XCTAssertEqual(RaceFormat.climb(36, unit: .miles), "+118 ft")
        XCTAssertEqual(RaceFormat.climb(36, unit: .kilometers), "+36 m")
    }

    func testResultAgainstTarget() {
        XCTAssertEqual(RaceFormat.result(finish: 6_269, target: 6_300), "Target 1:45:00 · beat it by 0:31")
        XCTAssertEqual(RaceFormat.result(finish: 1_512, target: 1_500), "Target 25:00 · missed it by 0:12")
        XCTAssertEqual(RaceFormat.result(finish: 13_000, target: 9_000), "Target 2:30:00 · missed it by 1:06:40")
        XCTAssertEqual(RaceFormat.result(finish: 1_500.2, target: 1_500), "Target 25:00 · right on it")
    }

    func testCueWords() {
        XCTAssertEqual(RaceFormat.cueTitle(.split(mile: 3)), "Mile 3 split")
        XCTAssertEqual(RaceFormat.cueTitle(.split(kilometer: 4)), "Km 4 split")
        XCTAssertEqual(RaceFormat.cueTitle(.paceGap, content: CueContent(heading: .label("AHEAD OF PLAN"), main: .gap(-20))),
                       "Ahead of plan")
        XCTAssertEqual(RaceFormat.cueTitle(.paceGap, content: CueContent(heading: .label("BEHIND PLAN"), main: .gap(20))),
                       "Behind plan")
        XCTAssertEqual(RaceFormat.cueTitle(.terrain(at: 100), content: CueContent(main: .label("TURN"), icon: .arrow)),
                       "Turn ahead")
        XCTAssertEqual(RaceFormat.cueTitle(.terrain(at: 100), content: CueContent(main: .label("HILL"), icon: .hill)),
                       "Hill ahead")
        XCTAssertEqual(RaceFormat.rating(.tooLittle), "Missed something")
        XCTAssertEqual(RaceFormat.outcome(CueOutcome(measure: .heartRate, shownAt: 0, at: 60, atShow: 176, after: 171)),
                       "HR 176 → 171, better")
        XCTAssertEqual(RaceFormat.outcome(CueOutcome(measure: .paceOffset, shownAt: 0, at: 60, atShow: 0.047, after: 0.045)),
                       "pace +4.7% → +4.5%, not better")
    }
}
