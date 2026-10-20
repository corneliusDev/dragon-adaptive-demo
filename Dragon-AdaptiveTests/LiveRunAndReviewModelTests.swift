//  LiveRunAndReviewModelTests.swift
//  The live run model plays a synthetic race made from the chosen plan
//  through RunEngine; END saves the cue log and a record; the review reads
//  them back, counts the cues, lists them with their outcomes and saves the
//  runner's rating into the cue log file.

import XCTest
import DragonEngine
@testable import Dragon_Adaptive

final class LiveRunAndReviewModelTests: XCTestCase {
    private var plan: SavedPlan {
        SavedPlan(name: "Test 5K", preset: .fiveK, distanceMeters: 5_000, unit: .miles, targetTime: 1_500,
                  pacing: .even, course: nil, courseFileName: nil, zones: nil, fuelEvery: nil, display: .balanced)
    }

    /// Runs the model to the finish (and the result's display time after it).
    private func runToFinish(_ model: LiveRunModel) {
        model.start(timer: false)
        model.speed = 10
        var guardrail = 0
        while model.isRunning && guardrail < 10_000 {
            model.advance(realSeconds: 1)
            guardrail += 1
        }
    }

    func testTheRaceIsMadeFromThePlan() throws {
        var p = plan
        p.unit = .kilometers
        p.display = .coach
        let model = LiveRunModel(plan: p)
        XCTAssertEqual(model.engine.plan.distanceMeters, 5_000)
        XCTAssertEqual(model.engine.plan.targetTime, 1_500)
        XCTAssertEqual(model.engine.config.unit, .kilometers)
        XCTAssertEqual(model.engine.displaySetting, .coach)
        XCTAssertEqual(model.engine.log.header.name, "Test 5K")
        // No course in the plan: the synthetic course, as long as the race.
        XCTAssertEqual(model.engine.plan.course?.totalDistance ?? 0, 5_000, accuracy: 1)

        // An imported course is the one the race runs on.
        var withCourse = plan
        let course = Course.synthetic(length: 5_400, hills: [SyntheticHill(start: 2_000, length: 400, gain: 20)])
        withCourse.course = course
        XCTAssertEqual(LiveRunModel(plan: withCourse).engine.plan.course, course)
    }

    func testStartAdvancePauseAndSpeed() {
        let model = LiveRunModel(plan: plan)
        var frames = 0
        model.onFrame = { _ in frames += 1 }
        XCTAssertFalse(model.hasStarted)
        model.start(timer: false)
        XCTAssertTrue(model.hasStarted)
        XCTAssertTrue(model.isRunning)
        XCTAssertEqual(model.raceTime, 0)

        model.advance(realSeconds: 2)                      // 1x
        XCTAssertEqual(model.raceTime, 2, accuracy: 1e-6)
        model.speed = 10
        model.advance(realSeconds: 3)                      // 30 race seconds
        XCTAssertEqual(model.raceTime, 32, accuracy: 1e-6)
        XCTAssertGreaterThan(model.state?.distance ?? 0, 50)
        XCTAssertNotEqual(model.heartText, "")
        XCTAssertGreaterThan(frames, 0)
        XCTAssertEqual(model.frame.signature, model.engine.frame().signature)

        model.pause()
        model.advance(realSeconds: 10)
        XCTAssertEqual(model.raceTime, 32, accuracy: 1e-6, "paused: the race clock stands still")

        // The test hook multiplies the chosen speed.
        let fast = LiveRunModel(plan: plan, timeScale: 6)
        fast.start(timer: false)
        fast.speed = 10
        fast.advance(realSeconds: 1)
        XCTAssertEqual(fast.raceTime, 60, accuracy: 1e-6)
    }

    func testStatusInPlainWords() {
        let model = LiveRunModel(plan: plan)
        model.start(timer: false)
        model.speed = 10
        // Run until a split shows.
        while model.raceTime < 1_400 && !model.status.headline.hasPrefix("Showing: mile") {
            model.advance(realSeconds: 0.1)
        }
        XCTAssertEqual(model.status.headline, "Showing: mile 1 split")
        XCTAssertTrue(model.status.detail.hasPrefix("Effort "), model.status.detail)
        XCTAssertTrue(model.status.detail.contains("room for"), model.status.detail)
        XCTAssertEqual(model.positionText.prefix(6), "MILE 1")
    }

    func testEndAfterTheFinishSavesTheRecordAndLog() throws {
        let env = AppEnvironment.temporary()
        let model = LiveRunModel(plan: plan)
        runToFinish(model)
        XCTAssertTrue(model.isFinished)
        XCTAssertEqual(model.finishTime ?? 0, 1_500, accuracy: 60)
        XCTAssertTrue(model.status.headline.hasPrefix("Finished in") || model.status.headline.hasPrefix("Showing: finish"),
                      model.status.headline)
        XCTAssertEqual(model.positionText, "FINISHED")

        let record = try model.end(store: env.runs)
        XCTAssertEqual(try model.end(store: env.runs), record, "END twice saves once")
        XCTAssertEqual(record.finishTime, model.finishTime)
        XCTAssertEqual(record.splits.map(\.marker), [1, 2, 3])
        XCTAssertEqual(record.splits[0].planTime, 1_500 / 5_000 * DistanceUnit.metersPerMile, accuracy: 0.01)
        XCTAssertEqual(env.runs.load(), [record])
        let log = try env.runs.log(for: record)
        XCTAssertEqual(log.header.name, "Test 5K")
        XCTAssertEqual(log.header.finishTime, model.finishTime)
        XCTAssertFalse(log.appearances.isEmpty)
    }

    func testEndingEarlyIsNotAFinish() throws {
        let env = AppEnvironment.temporary()
        let model = LiveRunModel(plan: plan)
        model.start(timer: false)
        model.speed = 10
        model.advance(realSeconds: 60)                     // 10 minutes
        let record = try model.end(store: env.runs)
        XCTAssertNil(record.finishTime)
        XCTAssertFalse(record.finished)
        XCTAssertEqual(record.endedAt, 600, accuracy: 1e-6)
        XCTAssertTrue(record.resultText.hasPrefix("Ended at "), record.resultText)

        let review = try ReviewModel(record: record, store: env.runs)
        XCTAssertTrue(review.targetLine.hasPrefix("Ended at 10:00 · target 25:00"), review.targetLine)
    }

    func testReviewCountsListsAndSavesTheRating() throws {
        let env = AppEnvironment.temporary()
        let model = LiveRunModel(plan: plan)
        runToFinish(model)
        let record = try model.end(store: env.runs)
        let review = try ReviewModel(record: record, store: env.runs)

        XCTAssertEqual(review.resultText, RaceFormat.clock(record.finishTime!))
        XCTAssertTrue(review.targetLine.hasPrefix("Target 25:00 · "), review.targetLine)
        XCTAssertEqual(review.splitsTitle, "Splits vs plan (8:03)")
        XCTAssertEqual(review.splits.count, 3)
        XCTAssertGreaterThanOrEqual(review.shownCount, 1)
        XCTAssertEqual(review.shownCount, review.summary.total.shown)
        XCTAssertEqual(review.cueRows.count, review.log.appearances.count)
        let split = try XCTUnwrap(review.cueRows.first { $0.title == "Mile 1 split" })
        XCTAssertEqual(split.marker, "1.0")

        // The one question: saved into the log, and into its file.
        XCTAssertNil(review.rating)
        review.rate(.justRight)
        XCTAssertEqual(review.rating, .justRight)
        XCTAssertEqual(review.savedMessage, "Saved: just right")
        XCTAssertEqual(try env.runs.log(for: record).header.rating, .justRight)
        review.rate(.tooMuch)
        XCTAssertEqual(try env.runs.log(for: record).header.rating, .tooMuch)

        // A rating for one cue goes on its appearance.
        review.rate(cue: split.id, .tooLittle)
        XCTAssertEqual(review.cueRows.first { $0.id == split.id }?.rating, .tooLittle)
        XCTAssertEqual(try env.runs.log(for: record).appearances.first { $0.cue.id == split.id }?.rating, .tooLittle)

        // Reopened from the past runs list, the answers are there.
        let reopened = try ReviewModel(record: try XCTUnwrap(HomeModel(environment: env).runs.first), store: env.runs)
        XCTAssertEqual(reopened.rating, .tooMuch)

        HomeModel(environment: env).delete(run: record)
        XCTAssertEqual(env.runs.load(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.runs.logURL(for: record).path))
    }

    func testAttentionReachesTheEngine() {
        let model = LiveRunModel(plan: plan)
        model.start(timer: false)
        model.speed = 10
        model.advance(realSeconds: 30)
        model.receive(.glance)
        model.advance(realSeconds: 0.05)
        XCTAssertEqual(model.state?.attention, .glance)
    }
}
