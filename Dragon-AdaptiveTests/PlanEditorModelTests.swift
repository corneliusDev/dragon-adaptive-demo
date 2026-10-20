//  PlanEditorModelTests.swift
//  The race plan screen's model: validation (pace limits, times, zones,
//  pacing, fuel, course length), GPX import through DragonEngine's parser
//  (a file with no elevation turns hill warnings off), and saving plans.

import XCTest
import DragonEngine
@testable import Dragon_Adaptive

final class PlanEditorModelTests: XCTestCase {
    private func model(_ preset: RaceDistance = .half, target: String = "1:45:00",
                       unit: DistanceUnit = .miles) -> PlanEditorModel {
        let m = PlanEditorModel()
        m.name = "City Half"
        m.preset = preset
        m.unit = unit
        m.target = target
        return m
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "gpx"),
                                "\(name).gpx missing from the test bundle")
        return try Data(contentsOf: url)
    }

    // MARK: Pace limits

    func testAPlanAtNormalPaceSaves() {
        let m = model()
        XCTAssertEqual(m.problems, [])
        XCTAssertNil(m.paceProblem)
        let plan = try? XCTUnwrap(m.makePlan())
        XCTAssertEqual(plan?.distanceMeters, 21_097.5)
        XCTAssertEqual(plan?.targetTime, 6_300)
        XCTAssertEqual(plan?.pacing, .even)
        XCTAssertEqual(m.pacingSummary, "8:01 /mi the whole way")
    }

    func testTargetPaceFasterThanThreeMinutesAMileIsRejected() {
        // 5K in 9:00 is 2:54 /mi.
        let m = model(.fiveK, target: "9:00")
        XCTAssertEqual(m.paceProblem, "Target pace 2:54 /mi is faster than 3:00 /mi. Check the distance and target time.")
        XCTAssertTrue(m.problems.contains(m.paceProblem!))
        XCTAssertFalse(m.canSave)
        XCTAssertNil(m.makePlan())
    }

    func testTargetPaceSlowerThanTwentyMinutesAMileIsRejected() {
        // Marathon in 9:00:00 is 20:36 /mi.
        let m = model(.marathon, target: "9:00:00")
        XCTAssertEqual(m.paceProblem, "Target pace 20:36 /mi is slower than 20:00 /mi. Check the distance and target time.")
        XCTAssertFalse(m.canSave)
    }

    func testPaceLimitsThemselvesAreAllowed() {
        // Exactly 3:00 /mi and 20:00 /mi over a 10-mile custom race.
        let m = model(.custom, target: "30:00")
        m.customDistance = "10"
        XCTAssertNil(m.paceProblem)
        m.target = "3:20:00"
        XCTAssertNil(m.paceProblem)
        XCTAssertTrue(m.canSave)
        m.target = "3:20:30"
        XCTAssertNotNil(m.paceProblem)
        m.target = "29:50"
        XCTAssertNotNil(m.paceProblem)
    }

    func testPaceMessageInKilometresGivesBothUnits() {
        // 10K in 15:00 is 1:30 /km (2:25 /mi).
        let m = model(.tenK, target: "15:00", unit: .kilometers)
        XCTAssertEqual(m.paceProblem,
                       "Target pace 1:30 /km is faster than 3:00 /mi (1:52 /km). Check the distance and target time.")
    }

    // MARK: Other checks

    func testMissingOrMalformedFieldsSayWhat() {
        let m = PlanEditorModel()
        m.target = "1:75:00"
        m.preset = .custom
        XCTAssertEqual(m.problems, [
            "Give the race a name.",
            "Enter the race distance in mi.",
            "Enter a target time like 1:45:00 (h:mm:ss) or 25:00 (mm:ss).",
        ])
        XCTAssertFalse(m.canSave)
    }

    func testHeartRateZonesFuelAndPacing() {
        let m = model()
        m.resting = "52"
        XCTAssertTrue(m.problems.contains("Heart rate: enter resting, threshold and max, or leave all three empty."))
        m.threshold = "190"
        m.maxHeartRate = "188"
        XCTAssertTrue(m.problems.contains("Heart rate: resting must be under threshold, and threshold under max."))
        m.threshold = "172"
        XCTAssertEqual(m.problems, [])

        m.fuelMinutes = "2"
        XCTAssertTrue(m.problems.contains("Fuel: enter minutes between gels, 10–120, or leave it empty."))
        m.fuelMinutes = "45"

        m.pacingStyle = .negative
        m.negativePercent = "25"
        XCTAssertTrue(m.problems.contains("Negative split: enter a percentage from 0.5 to 10."))
        m.negativePercent = "2"
        XCTAssertEqual(m.pacingSummary, "8:05 then 7:56 /mi")

        m.pacingStyle = .perSplit
        m.splitTimes = "8:05"
        XCTAssertTrue(m.problems.contains("By split: enter at least two split times like 8:05, 8:00, 7:55."))
        m.splitTimes = "8:05, 8:00, 7:55"

        let plan = try? XCTUnwrap(m.makePlan())
        XCTAssertEqual(plan?.zones, ZoneInputs(resting: 52, threshold: 172, max: 188))
        XCTAssertEqual(plan?.fuelEvery, 2_700)
        XCTAssertEqual(plan?.pacing, .perSplit([485, 480, 475]))
        XCTAssertEqual(plan?.runPlan.heartRateZones, HeartRateZones.reserve(resting: 52, threshold: 172, max: 188))
    }

    // MARK: Course import

    func testGPXWithoutElevationShowsHillWarningsOff() throws {
        let m = model(.fiveK, target: "25:00")
        m.importGPX(try fixture("flat-no-elevation"), fileName: "flat-no-elevation.gpx")
        XCTAssertNil(m.importError)
        XCTAssertEqual(m.courseFileName, "flat-no-elevation.gpx")
        XCTAssertEqual(m.course?.hasElevation, false)
        XCTAssertEqual(m.courseNotice, "No elevation in this course: hill warnings are off.")
        XCTAssertEqual(m.courseSummary, "3.2 mi · 1 aid station")
        // A notice, not a problem: the plan still saves, with the course.
        XCTAssertEqual(m.problems, [])
        XCTAssertEqual(m.makePlan()?.course?.hasElevation, false)

        m.removeCourse()
        XCTAssertNil(m.courseNotice)
        XCTAssertNil(m.course)
    }

    func testGPXWithElevationHasNoNoticeAndDescribesHills() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "SampleCourse", withExtension: "gpx"))
        let m = model(.custom, target: "40:00")
        m.importGPX(try Data(contentsOf: url), fileName: "SampleCourse.gpx")
        XCTAssertNil(m.courseNotice)
        XCTAssertEqual(m.course?.hasElevation, true)
        XCTAssertNotNil(m.courseSummary)
        m.useCourseDistance()
        XCTAssertEqual(m.distanceMeters ?? 0, m.course!.totalDistance, accuracy: 10)
        XCTAssertNil(m.paceProblem)
    }

    func testCourseShorterThanTheRaceIsAProblem() throws {
        let m = model(.tenK, target: "50:00")
        m.importGPX(try fixture("flat-no-elevation"), fileName: "flat.gpx")
        XCTAssertTrue(m.problems.contains("The course file is 3.2 mi, shorter than the race's 6.2 mi."))
    }

    func testABadFileLeavesTheCourseAlone() {
        let m = model()
        m.importGPX(Data("not xml".utf8), fileName: "notes.txt")
        XCTAssertEqual(m.importError, "notes.txt isn't a GPX file this app can read.")
        XCTAssertNil(m.course)
        m.importGPX(Data("<gpx></gpx>".utf8), fileName: "empty.gpx")
        XCTAssertEqual(m.importError, "empty.gpx has no track points.")
    }

    // MARK: Saving

    func testPlansSaveLoadEditAndDelete() throws {
        let env = AppEnvironment.temporary()
        let m = model()
        m.fuelMinutes = "45"
        m.display = .coach
        m.importGPX(try fixture("flat-no-elevation"), fileName: "flat.gpx")
        m.preset = .custom
        m.customDistance = "3.2"
        m.target = "28:00"
        let saved = try XCTUnwrap(try m.save(to: env.plans))
        XCTAssertEqual(env.plans.load(), [saved])

        // Editing keeps the id and the course; the list holds one plan.
        let edit = PlanEditorModel(plan: saved)
        XCTAssertFalse(edit.isNew)
        XCTAssertEqual(edit.target, "28:00")
        XCTAssertEqual(edit.customDistance, "3.2")
        XCTAssertEqual(edit.fuelMinutes, "45")
        XCTAssertEqual(edit.courseFileName, "flat.gpx")
        edit.name = "Park loop"
        let renamed = try XCTUnwrap(try edit.save(to: env.plans))
        XCTAssertEqual(renamed.id, saved.id)
        XCTAssertEqual(env.plans.load().map(\.name), ["Park loop"])
        XCTAssertEqual(env.plans.load().first?.course, saved.course)

        let home = HomeModel(environment: env)
        home.duplicate(renamed)
        XCTAssertEqual(Set(home.plans.map(\.name)), ["Park loop", "Park loop copy"])
        home.delete(plan: renamed)
        XCTAssertEqual(home.plans.map(\.name), ["Park loop copy"])
    }
}
