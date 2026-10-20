//  PhoneSensorsUITests.swift
//  A real run on the Phone sensors source in the simulator: the location
//  explanation shows before the system asks, the run starts once location is
//  allowed, GPS fixes come in and the distance advances, the simulator's
//  missing motion sensors are reported (not a failure), and END reaches the
//  review with the run recorded.
//
//  The route is simulated by the test itself (XCUIDevice location), or, run
//  with TEST_RUNNER_DRAGON_EXTERNAL_LOCATION=1 in xcodebuild's environment,
//  by whatever `xcrun simctl location <device> start …` is playing.

import XCTest
import CoreLocation

final class PhoneSensorsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testPhoneSensorsMeasureASimulatedRun() throws {
        let external = ProcessInfo.processInfo.environment["DRAGON_EXTERNAL_LOCATION"] == "1"
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .location)
        app.launchArguments = ["-uiTesting"]
        app.launchEnvironment["DRAGON_RUN_SOURCE"] = "phone"
        app.launch()

        // Home → a 5K plan → START RUN.
        let newRace = app.buttons["newRaceButton"]
        XCTAssertTrue(newRace.waitForExistence(timeout: 10))
        newRace.tap()
        let name = app.textFields["planName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        type("Street 5K\n", into: name, in: app)
        type("25:00\n", into: app.textFields["planTarget"], in: app)
        app.buttons["distance.fiveK"].tap()
        XCTAssertTrue(app.buttons["startRunButton"].isEnabled)
        app.buttons["startRunButton"].tap()

        // Phone sensors: the explanation comes before the system's request.
        XCTAssertTrue(app.buttons["source.phone"].waitForExistence(timeout: 10), app.debugDescription)
        let title = app.staticTexts["permissionTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(title.label, "Location for distance and pace")
        app.buttons["permissionAllow"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow While Using App"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10), "the system's location request")
        allow.tap()

        // The simulator has no motion sensors: said, not asked.
        let ready = app.staticTexts["sensorsReady"]
        XCTAssertTrue(ready.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Motion sensors aren't available on this device: the run uses GPS only."].exists)

        app.buttons["startButton"].tap()
        XCTAssertTrue(app.buttons["pauseButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["speed.10.0"].exists, "a real run has no 10x")

        // Run ~3.5 m/s north for 40 s.
        if !external {
            for i in 0...40 {
                let lat = 37.7749 + Double(i) * 3.5 / 111_195
                XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: lat, longitude: -122.4194))
                Thread.sleep(forTimeInterval: 1)
            }
        } else {
            Thread.sleep(forTimeInterval: 40)
        }

        let sensors = app.staticTexts["liveSensors"]
        XCTAssertTrue(sensors.waitForExistence(timeout: 5))
        XCTAssertTrue(sensors.label.hasPrefix("GPS ±"), sensors.label)
        XCTAssertTrue(sensors.label.contains("no motion sensors on this device"), sensors.label)
        let distance = app.staticTexts["liveDistance"]
        XCTAssertGreaterThan(Double(distance.label) ?? 0, 0.03, "distance (mi): \(distance.label)")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Phone sensors mid-run"
        shot.lifetime = .keepAlways
        add(shot)

        app.buttons["endRunButton"].tap()
        XCTAssertTrue(app.staticTexts["reviewResult"].waitForExistence(timeout: 10))
    }

    /// Taps the field until it has keyboard focus, then types (as RaceFlowUITests).
    private func type(_ text: String, into field: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 {
            field.tap()
            if (field.value(forKey: "hasKeyboardFocus") as? Bool) == true { break }
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 1)
            if (field.value(forKey: "hasKeyboardFocus") as? Bool) == true { break }
        }
        field.typeText(text)
    }
}
