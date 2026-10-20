//  RaceFlowUITests.swift
//  The main flow in the simulator: create a 5K plan, run its synthetic race
//  at 10x (the DRAGON_TIME_SCALE hook speeds race time up further so the
//  test takes seconds), end it, and see the review with at least one cue and
//  a saved rating, which is still there when the run is reopened from the
//  past runs list; then the Developer menu opens with the legacy demos.
//  Launched with -uiTesting, so it starts with no plans.

import XCTest

final class RaceFlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testCreatePlanRunAtTenTimesEndAndRate() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launchEnvironment["DRAGON_TIME_SCALE"] = "20"
        app.launch()

        // Home → plan editor.
        let newRace = app.buttons["newRaceButton"]
        XCTAssertTrue(newRace.waitForExistence(timeout: 10))
        newRace.tap()


        let name = app.textFields["planName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), app.debugDescription)
        type("Park 5K\n", into: name, in: app)

        // 25:00 for the default half marathon is 1:54 /mi: refused, with the reason.
        let target = app.textFields["planTarget"]
        type("25:00\n", into: target, in: app)
        let problems = app.descendants(matching: .any)["planProblems"]
        XCTAssertTrue(problems.waitForExistence(timeout: 5))
        XCTAssertTrue(problems.label.contains("faster than 3:00 /mi"), problems.label)
        XCTAssertFalse(app.buttons["startRunButton"].isEnabled)

        // As a 5K it is 8:03 /mi.
        app.buttons["distance.fiveK"].tap()
        XCTAssertFalse(problems.exists)
        let start = app.buttons["startRunButton"]
        XCTAssertTrue(start.isEnabled)
        start.tap()

        // Live run at 10x.
        let speed = app.buttons["speed.10.0"]
        XCTAssertTrue(speed.waitForExistence(timeout: 10))
        speed.tap()
        XCTAssertTrue(app.staticTexts["livePosition"].exists)
        // The engine read-outs sit under the mirror.
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["engineStatus"].waitForExistence(timeout: 5))
        let finished = app.staticTexts["finishedLabel"]
        XCTAssertTrue(finished.waitForExistence(timeout: 120), "the 5K should finish")
        app.buttons["endRunButton"].tap()

        // Review: a result, at least one cue, and the question.
        let result = app.staticTexts["reviewResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        let shown = app.staticTexts["reviewShown"]
        XCTAssertTrue(shown.exists)
        XCTAssertGreaterThanOrEqual(Int(shown.label) ?? 0, 1, "cues shown: \(shown.label)")
        XCTAssertTrue(app.descendants(matching: .any)["cueRow"].firstMatch.exists)

        let justRight = app.buttons["rating.justRight"]
        scrollTo(justRight, in: app)
        justRight.tap()
        XCTAssertTrue(app.staticTexts["ratingSaved"].waitForExistence(timeout: 5))
        XCTAssertTrue(justRight.isSelected)

        // Back home: the run is in the past runs list, and reopening it shows the saved rating.
        app.buttons["reviewDone"].firstMatch.tap()
        let pastRun = app.buttons["run.Park 5K"]
        XCTAssertTrue(pastRun.waitForExistence(timeout: 5))
        scrollTo(pastRun, in: app)
        pastRun.tap()
        let reopened = app.buttons["rating.justRight"]
        XCTAssertTrue(reopened.waitForExistence(timeout: 5))
        scrollTo(reopened, in: app)
        XCTAssertTrue(reopened.isSelected)

        // The old demo controls live in the Developer menu, legacy scenarios included.
        app.buttons["reviewDone"].firstMatch.tap()
        let gear = app.buttons["developerButton"]
        XCTAssertTrue(gear.waitForExistence(timeout: 5))
        gear.tap()
        let sof = app.buttons["OPERATOR / SOF"]
        XCTAssertTrue(sof.waitForExistence(timeout: 5))
        sof.tap()
        XCTAssertTrue(app.buttons["CYCLING / TRI"].exists)
        app.buttons["developerDone"].tap()
        XCTAssertTrue(app.buttons["newRaceButton"].waitForExistence(timeout: 5))
    }

    /// Taps the field until it has keyboard focus (the first tap after a
    /// push can land before the field is ready), then types.
    private func type(_ text: String, into field: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 {
            field.tap()
            if (field.value(forKey: "hasKeyboardFocus") as? Bool) == true { break }
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 1)
            if (field.value(forKey: "hasKeyboardFocus") as? Bool) == true { break }
        }
        field.typeText(text)
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        var tries = 0
        while !element.isHittable && tries < 6 {
            app.swipeUp()
            tries += 1
        }
    }
}
