//  SyntheticVitalsSourceTests.swift
//  The generator itself is tested in DragonEngine; these cover the app's
//  Timer-driven wrapper around it.

import XCTest
import DragonEngine
@testable import Dragon_Adaptive

final class SyntheticVitalsSourceTests: XCTestCase {
    func testStartStreamsTheGeneratorsSamplesOnTheMainRunLoop() {
        let source = SyntheticVitalsSource(seed: 7)
        var expected = SyntheticVitalsGenerator(seed: 7)
        var received: [VitalsSample] = []

        let got = expectation(description: "samples")
        source.onSample = { sample in
            received.append(sample)
            if received.count == 3 { got.fulfill() }
        }

        source.start()
        XCTAssertTrue(source.isStreaming)
        wait(for: [got], timeout: 5)
        source.stop()
        XCTAssertFalse(source.isStreaming)

        // Same seed, same steps: the wrapper adds timing only, never changes values.
        var replayed: [VitalsSample] = []
        while replayed.count < 3 {
            if let s = expected.advance(by: 1.0 / 20.0) { replayed.append(s) }
        }
        XCTAssertEqual(received.prefix(3).map(\.motion), replayed.map(\.motion))
        XCTAssertEqual(received.prefix(3).map(\.timestamp), replayed.map(\.timestamp))
    }

    func testResetRewindsTheGenerator() {
        let source = SyntheticVitalsSource(seed: 7)
        source.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        source.stop()
        XCTAssertGreaterThan(source.generator.elapsed, 0)

        source.reset()
        XCTAssertEqual(source.generator.elapsed, 0)
    }

    func testAppSharesTheEnginesScenarios() {
        // Compile-level smoke test: the app target links DragonEngine's public API.
        let engine = AdaptiveEngine(scenario: Scenarios.cyclingTri)
        XCTAssertEqual(engine.tick(dt: 0, at: 0).ops.isEmpty, false)
    }
}
