//  SplitTriggerTests.swift

import XCTest
import DragonEngine

final class SplitTriggerTests: XCTestCase {
    private let mile = DistanceUnit.metersPerMile
    /// 5 miles in 40:00, even: 480 s a mile.
    private lazy var plan = RunPlan(distanceMeters: 5 * mile, targetTime: 2_400)

    private func markers(_ cues: [Cue]) -> [CueKey] { cues.map(\.key) }

    func testFiresOncePerMarkerWithSplitTimeAndDifferenceFromPlan() {
        var trigger = SplitTrigger(plan: plan)
        var cues: [Cue] = []
        // 470 s a mile (10 s quicker than plan), one state a second.
        let speed = mile / 470
        for t in 0...2_400 {
            let d = min(plan.distanceMeters, Double(t) * speed)
            cues += trigger.evaluate(state: RunState(elapsed: Double(t), distance: d), at: Double(t))
        }
        // Markers 1–4; mile 5 is the finish, not a split.
        XCTAssertEqual(markers(cues), [.split(mile: 1), .split(mile: 2), .split(mile: 3), .split(mile: 4)])
        for (i, split) in trigger.splits.enumerated() {
            XCTAssertEqual(split.marker, i + 1)
            XCTAssertEqual(split.crossedAt, 470 * Double(i + 1), accuracy: 0.01)
            XCTAssertEqual(split.time, 470, accuracy: 0.01)
            XCTAssertEqual(split.planTime, 480, accuracy: 0.01)
            XCTAssertEqual(split.vsPlan, -10, accuracy: 0.01)
        }
        let first = cues[0]
        XCTAssertEqual(first.priority, .advisory)
        XCTAssertEqual(first.minShow, 3)
        XCTAssertEqual(first.createdAt, 470)
        XCTAssertEqual(first.content.heading, .marker(1, .miles))
        XCTAssertEqual(first.content.tag, "SPLIT")
        XCTAssertEqual(CueFormat.string(first.content.main), "7:50")
        XCTAssertEqual(first.content.subtitle.map(CueFormat.string), ["-0:10 VS PLAN"])
    }

    func testGPSJumpAcrossAMarkerBetweenTwoSamplesFiresOnceWithAnInterpolatedTime() {
        var trigger = SplitTrigger(plan: plan)
        var cues: [Cue] = []
        func at(_ t: Double, _ d: Double) { cues += trigger.evaluate(state: RunState(elapsed: t, distance: d), at: t) }

        at(400, mile - 40)
        at(401, mile + 60)          // jumped 100 m across the marker in one sample
        at(402, mile - 5)           // ...and wandered back over it
        at(403, mile + 3)
        at(404, mile + 70)
        XCTAssertEqual(markers(cues), [.split(mile: 1)])
        // 40 of the 100 m jump were before the marker.
        XCTAssertEqual(trigger.splits[0].crossedAt, 400.4, accuracy: 1e-9)

        // A jump across two markers at once still gives one cue per marker.
        at(1_300, 3 * mile + 20)
        XCTAssertEqual(markers(cues), [.split(mile: 1), .split(mile: 2), .split(mile: 3)])
        XCTAssertEqual(trigger.splits.map(\.marker), [1, 2, 3])
        XCTAssertLessThan(trigger.splits[1].crossedAt, trigger.splits[2].crossedAt)
    }

    func testKilometres() {
        let tenK = RunPlan(distanceMeters: 10_000, targetTime: 3_000)
        var trigger = SplitTrigger(plan: tenK, config: .init(unit: .kilometers))
        var cues: [Cue] = []
        for t in stride(from: 0.0, through: 3_000, by: 2) {
            cues += trigger.evaluate(state: RunState(elapsed: t, distance: t * 10_000 / 3_000), at: t)
        }
        XCTAssertEqual(markers(cues), (1...9).map { .split(kilometer: $0) })
        XCTAssertEqual(CueFormat.string(cues[0].content.heading!), "KM 1")
        XCTAssertEqual(trigger.splits[0].planTime, 300, accuracy: 1e-6)
    }

    func testSplitOnAClimbIsDeferredToTheCrestAndExpiresAfterIt() {
        // A 6% climb across the mile 1 marker; mile 2 is on the flat.
        let hill = SyntheticHill(start: mile - 200, length: 500, gain: 30, descent: 600)
        let hilly = RunPlan(distanceMeters: 5 * mile, targetTime: 2_400,
                            course: .synthetic(length: 5 * mile, hills: [hill]))
        guard let climb = hilly.course!.hills().first else { return XCTFail("no hill on the course") }
        XCTAssertTrue(climb.startDistance < mile && mile < climb.endDistance)

        var trigger = SplitTrigger(plan: hilly)
        var cues: [Cue] = []
        let speed = mile / 480
        for t in 0...1_000 {
            cues += trigger.evaluate(state: RunState(elapsed: Double(t), distance: Double(t) * speed), at: Double(t))
        }
        XCTAssertEqual(markers(cues), [.split(mile: 1), .split(mile: 2)])
        let onClimb = cues[0], onFlat = cues[1]
        XCTAssertEqual(onClimb.deferUntil, .distance(climb.endDistance))
        // Expiry: the rest of the climb at 1.5x plan pace, then the usual 20 s.
        let rest = (climb.endDistance - onClimb.createdAt * speed) * hilly.targetPace(at: mile) * 1.5
        XCTAssertEqual(onClimb.expiresAt, onClimb.createdAt + rest + 20, accuracy: 0.01)
        XCTAssertNil(onFlat.deferUntil)
        XCTAssertEqual(onFlat.expiresAt, onFlat.createdAt + 20)

        // Turned off, the climb's split shows at once like any other.
        var config = SplitTrigger.Config()
        config.deferOnClimbs = false
        var plain = SplitTrigger(plan: hilly, config: config)
        var plainCues: [Cue] = []
        for t in 0...500 {
            plainCues += plain.evaluate(state: RunState(elapsed: Double(t), distance: Double(t) * speed), at: Double(t))
        }
        XCTAssertNil(plainCues.first?.deferUntil)
    }
}
