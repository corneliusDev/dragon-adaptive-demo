//  HysteresisTests.swift

import XCTest
import DragonEngine

final class HysteresisTests: XCTestCase {
    private func make() -> Hysteresis { Hysteresis(start: 15, clear: 8, hold: 20) }

    func testValueFlickeringAcrossTheStartThresholdEverySecondNeverFires() {
        var h = make()
        for t in 0..<600 {
            let value = t % 2 == 0 ? 16.0 : 14.0
            XCTAssertNil(h.update(value, at: TimeInterval(t)), "t=\(t)")
            XCTAssertFalse(h.isOn)
        }
    }

    func testFlickeringBetweenStartAndClearAlsoRestartsTheHold() {
        // Dipping under start (but not under clear) still resets the wait.
        var h = make()
        for t in 0..<300 {
            let value = t % 10 == 9 ? 12.0 : 30.0
            XCTAssertNil(h.update(value, at: TimeInterval(t)), "t=\(t)")
        }
    }

    func testHeldPastTheHoldTimeFiresOnceAndClearsOnlyBelowTheClearThreshold() {
        var h = make()
        var changes: [(TimeInterval, Hysteresis.Change)] = []
        func feed(_ value: Double, from: Int, to: Int) {
            for t in from..<to {
                if let c = h.update(value, at: TimeInterval(t)) { changes.append((TimeInterval(t), c)) }
            }
        }
        feed(20, from: 0, to: 60)               // held: fires at 20 s, once
        XCTAssertEqual(changes.map(\.1), [.fired])
        XCTAssertEqual(changes.first?.0, 20)
        XCTAssertTrue(h.isOn)

        feed(10, from: 60, to: 120)             // under start, over clear: stays on
        feed(14.9, from: 120, to: 130)
        feed(8, from: 130, to: 140)             // at clear is not below it
        XCTAssertEqual(changes.count, 1)
        XCTAssertTrue(h.isOn)

        feed(7.9, from: 140, to: 150)           // below clear: clears, once
        XCTAssertEqual(changes.map(\.1), [.fired, .cleared])
        XCTAssertEqual(changes.last?.0, 140)
        XCTAssertFalse(h.isOn)

        feed(20, from: 150, to: 169)            // needs the full hold again
        XCTAssertEqual(changes.count, 2)
        feed(20, from: 169, to: 171)
        XCTAssertEqual(changes.map(\.1), [.fired, .cleared, .fired])
        XCTAssertEqual(changes.last?.0, 170)
    }

    func testUnknownReadingNeitherStartsNorClears() {
        var h = make()
        for t in 0..<10 { _ = h.update(20, at: TimeInterval(t)) }
        _ = h.update(nil, at: 10)               // gap in the data restarts the wait
        for t in 11..<30 { XCTAssertNil(h.update(20, at: TimeInterval(t))) }
        XCTAssertEqual(h.update(20, at: 31), .fired)
        for t in 32..<100 { XCTAssertNil(h.update(nil, at: TimeInterval(t))) }
        XCTAssertTrue(h.isOn)
    }
}
