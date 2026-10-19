//  SyntheticRaceSourceTests.swift
//  SyntheticRun itself is tested in DragonEngine; these cover the app's
//  Timer-driven wrapper and the race picker labels.

import XCTest
import DragonEngine
@testable import Dragon_Adaptive

final class SyntheticRaceSourceTests: XCTestCase {
    func testStartStreamsGPSAndVitalsOnTheMainRunLoopAtTheChosenSpeed() {
        let source = SyntheticRaceSource(profile: .onPlan, seed: 3)
        source.speed = 10
        var fixes: [LocationSample] = []
        var vitals: [VitalsSample] = []

        let got = expectation(description: "fixes")
        source.onSample = { fix in
            fixes.append(fix)
            if fixes.count == 5 { got.fulfill() }
        }
        source.onVitals = { vitals.append($0) }

        source.start()
        XCTAssertTrue(source.isStreaming)
        wait(for: [got], timeout: 5)
        source.stop()
        XCTAssertFalse(source.isStreaming)

        // 10x: five 1 Hz fixes need well under a real second of ticks.
        XCTAssertEqual(fixes.prefix(5).map(\.t), [0, 1, 2, 3, 4])
        XCTAssertFalse(vitals.isEmpty)
        XCTAssertGreaterThan(source.run.distance, 10)

        // The wrapper adds timing only: same seed, same samples.
        var expected = SyntheticRun(profile: .onPlan, seed: 3)
        let replayed = expected.samples(until: source.run.time)
        let delivered = replayed.compactMap { if case .location(let f) = $0 { return f } else { return nil } }
        XCTAssertEqual(Array(fixes.prefix(delivered.count)), delivered)
    }

    func testResetGoesBackToTheStartWithTheNewProfile() {
        let source = SyntheticRaceSource(profile: .onPlan, seed: 3)
        source.step(by: 120)
        XCTAssertGreaterThan(source.run.distance, 300)

        source.reset(profile: .hilly)
        XCTAssertEqual(source.run.distance, 0)
        XCTAssertEqual(source.profile, .hilly)
    }

    func testEveryProfileHasAPickerLabel() {
        XCTAssertEqual(Set(SyntheticProfile.all.map(\.displayName)).count, SyntheticProfile.all.count)
        XCTAssertEqual(SyntheticProfile.slowFade(from: 9 * DistanceUnit.metersPerMile).displayName, "Slow fade from mi 9")
    }
}
