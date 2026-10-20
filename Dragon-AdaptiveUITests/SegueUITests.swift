//  SegueUITests.swift
//  Chunk 14 part B in the simulator: the plan editor's segue section. Make a
//  plan, pick Slide, PREVIEW it (the in-editor mirror plays it, labelled),
//  STOP, save; reopen the plan from home and Slide is still the one picked.
//  Launched with -uiTesting, so it starts with no plans.

import XCTest

final class SegueUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testPickSlidePreviewStopSaveAndReopen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()

        let newRace = app.buttons["newRaceButton"]
        XCTAssertTrue(newRace.waitForExistence(timeout: 10))
        newRace.tap()

        let name = app.textFields["planName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        type("Slide 5K\n", into: name, in: app)
        type("25:00\n", into: app.textFields["planTarget"], in: app)
        app.buttons["distance.fiveK"].tap()

        // Fade is the default; pick Slide.
        let slide = app.buttons["segue.slide"]
        scrollTo(slide, in: app)
        XCTAssertTrue(app.buttons["segue.fade"].isSelected, "a new plan starts on Fade")
        slide.tap()
        XCTAssertTrue(slide.isSelected)

        // PREVIEW: the mirror plays it, labelled with the style.
        let preview = app.buttons["preview.segue"]
        scrollTo(preview, in: app)
        preview.tap()
        let label = app.staticTexts["seguePreviewLabel"]
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        XCTAssertTrue(label.label.contains("SLIDE"), label.label)
        XCTAssertTrue(app.descendants(matching: .any)["seguePreviewMirror"].exists)

        // STOP.
        let stop = app.buttons["seguePreviewStop"]
        XCTAssertTrue(stop.exists)
        stop.tap()
        XCTAssertTrue(label.waitForNonExistence(timeout: 5))
        XCTAssertFalse(stop.exists)

        // Save, and back home.
        app.buttons["savePlanButton"].tap()
        let card = app.buttons["plan.Slide 5K"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))

        // Reopen: Slide is still picked.
        card.tap()
        let reopened = app.buttons["segue.slide"]
        XCTAssertTrue(reopened.waitForExistence(timeout: 5))
        scrollTo(reopened, in: app)
        XCTAssertTrue(reopened.isSelected, "the plan kept Slide")
        XCTAssertFalse(app.buttons["segue.fade"].isSelected)
    }

    /// Taps the field until it has keyboard focus, then types.
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
        while !element.isHittable && tries < 8 {
            app.swipeUp()
            tries += 1
        }
    }
}
