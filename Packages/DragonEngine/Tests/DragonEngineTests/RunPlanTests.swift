//  RunPlanTests.swift

import XCTest
import DragonEngine

final class RunPlanTests: XCTestCase {
    private let half = 21097.5
    private let target: TimeInterval = 6300   // 1:45:00

    func testEvenHalfMarathonPace() {
        let plan = RunPlan(distanceMeters: half, targetTime: target)
        // 8:00.6 per mile
        XCTAssertEqual(plan.targetSecondsPerMile(at: 0), 480.6, accuracy: 0.1)
        XCTAssertEqual(plan.targetSecondsPerMile(at: 15000), 480.6, accuracy: 0.1)
        XCTAssertEqual(plan.targetSecondsPerKilometer(at: 5000), 6300 / 21.0975, accuracy: 1e-9)
        XCTAssertEqual(plan.planTime(at: half), 6300)
        XCTAssertEqual(plan.planTime(at: 0), 0)
        XCTAssertEqual(plan.planTime(at: half / 2), 3150, accuracy: 1e-9)
    }

    func testNegativeSplitSumsToTargetAndSecondHalfIsFaster() {
        let plan = RunPlan(distanceMeters: half, targetTime: target, pacing: .negativeSplit(percent: 3))
        XCTAssertEqual(plan.planTime(at: half), target, accuracy: 1)
        XCTAssertEqual(plan.planTime(at: half - 0.001), target, accuracy: 1)

        let first = plan.targetPace(at: 1000), second = plan.targetPace(at: 20000)
        XCTAssertEqual(second / first, 0.97, accuracy: 1e-9)

        // First half takes longer than half the target.
        XCTAssertGreaterThan(plan.planTime(at: half / 2), target / 2)
        // Integrating pace by hand gives the same finish.
        let byHand = half / 2 * first + half / 2 * second
        XCTAssertEqual(byHand, target, accuracy: 1)
    }

    func testPerSplitSumsToTarget() {
        // 13 "mile" splits plus a short last one, deliberately not summing to 6300.
        let splits: [TimeInterval] = [490, 485, 482, 480, 480, 478, 478, 476, 475, 475, 470, 468, 465, 60]
        let plan = RunPlan(distanceMeters: half, targetTime: target, pacing: .perSplit(splits))
        XCTAssertEqual(plan.planTime(at: half), target, accuracy: 1)
        XCTAssertEqual(plan.planTime(at: half - 0.01), target, accuracy: 1)

        // Pace changes split to split, and time only ever increases.
        XCTAssertGreaterThan(plan.targetPace(at: 10), plan.targetPace(at: half * 12.5 / 14))
        var last = -1.0
        for d in stride(from: 0.0, through: half, by: 250) {
            let t = plan.planTime(at: d)
            XCTAssertGreaterThan(t, last)
            last = t
        }
    }

    func testPerSplitThatAlreadySumsIsUsedAsIs() {
        let plan = RunPlan(distanceMeters: 3000, targetTime: 900, pacing: .perSplit([310, 300, 290]))
        XCTAssertEqual(plan.planTime(at: 1000), 310, accuracy: 1e-9)
        XCTAssertEqual(plan.planTime(at: 2000), 610, accuracy: 1e-9)
        XCTAssertEqual(plan.planTime(at: 3000), 900)
        XCTAssertEqual(plan.targetPace(at: 2500), 0.29, accuracy: 1e-12)
    }

    func testPlanTimeClampsOutsideTheRace() {
        let plan = RunPlan(distanceMeters: 5000, targetTime: 1500)
        XCTAssertEqual(plan.planTime(at: -10), 0)
        XCTAssertEqual(plan.planTime(at: 6000), 1500)
    }

    func testHeartRateZones() {
        let zones = HeartRateZones(resting: 50, threshold: 170, max: 190)
        XCTAssertEqual(zones.zoneCount, 5)
        XCTAssertEqual(zones.zone(for: 120), 1)
        XCTAssertEqual(zones.zone(for: 148), 2)   // 85% = 144.5
        XCTAssertEqual(zones.zone(for: 155), 3)   // 89% = 151.3
        XCTAssertEqual(zones.zone(for: 165), 4)   // 94% = 159.8
        XCTAssertEqual(zones.zone(for: 175), 5)

        let plan = RunPlan(distanceMeters: half, targetTime: target, heartRateZones: zones, fuelEvery: 2700)
        XCTAssertEqual(plan.heartRateZones?.zone(for: 175), 5)
        XCTAssertEqual(plan.fuelEvery, 2700)
    }
}
