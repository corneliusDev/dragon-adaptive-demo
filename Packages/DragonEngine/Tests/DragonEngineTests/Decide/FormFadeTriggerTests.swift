//  FormFadeTriggerTests.swift
//  Chunk 9: cadence more than 5% under the runner's own baseline with heart
//  rate drifting up, in the last third → an Info cue answering the next glance;
//  it clears when cadence recovers.

import XCTest
import DragonEngine

final class FormFadeTriggerTests: XCTestCase {
    private let plan = RunPlan(distanceMeters: 10_000, targetTime: 3_000)

    /// One state a second at 3.33 m/s: cadence 172 until `fadeAt` metres, then `faded`.
    private func run(_ trigger: inout FormFadeTrigger, to end: Int, fadeAt: Double = 7_000, faded: Double = 160,
                     drift: Double? = 4, recoverAt: Double = .infinity,
                     glances: Set<Int> = []) -> (on: [Double], answers: [(d: Double, cue: Cue)]) {
        var on: [Double] = [], answers: [(d: Double, cue: Cue)] = []
        for i in 0..<end {
            let t = TimeInterval(i), d = t * 10 / 3
            let cadence = d >= fadeAt && d < recoverAt ? faded : 172
            let wasOn = trigger.hysteresis.isOn
            _ = trigger.evaluate(state: RunState(elapsed: t, distance: d, heartDrift: drift, cadence: cadence), at: t)
            if trigger.hysteresis.isOn && !wasOn { on.append(d) }
            if glances.contains(i), let cue = trigger.answer(.glance, at: t) { answers.append((d, cue)) }
        }
        return (on, answers)
    }

    func testCadenceDownSevenPercentWithDriftInTheLastThirdComesOnAndAnswersAGlance() {
        var trigger = FormFadeTrigger(plan: plan)
        let result = run(&trigger, to: 2_500, glances: [2_250, 2_300])
        XCTAssertEqual(result.on.count, 1)
        guard let on = result.on.first else { return }
        XCTAssertGreaterThan(on, 7_000)
        XCTAssertEqual(trigger.baseline ?? 0, 172, accuracy: 0.01)
        XCTAssertEqual(trigger.drop ?? 0, 1 - 160.0 / 172, accuracy: 0.001)
        // The next glance gets it, once per episode.
        XCTAssertEqual(result.answers.count, 1)
        guard let cue = result.answers.first?.cue else { return }
        XCTAssertEqual(cue.key, .formFade)
        XCTAssertEqual(cue.priority, .info)
        XCTAssertEqual(cue.reveal, .glance)
        XCTAssertEqual(cue.minShow, 3)
        XCTAssertEqual(CueFormat.string(cue.content.main), "CADENCE -7%")
        XCTAssertEqual(cue.content.subtitle.map { CueFormat.string($0) }, ["SHORTEN STRIDE"])
        XCTAssertEqual(cue.content.tag, "FORM")
        XCTAssertEqual(cue.content.icon, .gauge)
        // A held look isn't answered with it.
        var other = FormFadeTrigger(plan: plan)
        _ = run(&other, to: 2_500)
        XCTAssertNil(other.answer(.dwell, at: 2_500))
    }

    func testNotBeforeTheLastThirdNotUnderFivePercentAndNotWithoutDrift() {
        var early = FormFadeTrigger(plan: plan)
        XCTAssertTrue(run(&early, to: 1_900, fadeAt: 5_500).on.isEmpty, "before 2/3 of the distance")
        var small = FormFadeTrigger(plan: plan)
        XCTAssertTrue(run(&small, to: 2_900, faded: 165).on.isEmpty, "down 4%")
        var steadyHeart = FormFadeTrigger(plan: plan)
        XCTAssertTrue(run(&steadyHeart, to: 2_900, drift: 0.5).on.isEmpty, "no drift")
        var unknown = FormFadeTrigger(plan: plan)
        XCTAssertTrue(run(&unknown, to: 2_900, drift: nil).on.isEmpty, "drift unknown")
        XCTAssertNil(unknown.answer(.glance, at: 2_900))
    }

    func testClearsWhenCadenceRecovers() {
        var trigger = FormFadeTrigger(plan: plan)
        _ = run(&trigger, to: 2_400, recoverAt: 7_800)
        XCTAssertFalse(trigger.hysteresis.isOn, "cadence back at 172 by 7.8 km")
        XCTAssertFalse(trigger.wantsGlance)
        XCTAssertLessThan(trigger.drop ?? 1, 0.03)
    }

    // MARK: Whole races

    func testSlowFadeFormCueAnswersAGlanceLateInTheRace() {
        let mile = DistanceUnit.metersPerMile
        let glances = stride(from: 4_200.0, through: 6_000, by: 120).map {
            RunEvent.attention(AttentionSample(t: $0, event: .glance))
        }
        let race = cueRace(.slowFade(from: 9 * mile), extra: glances)
        guard let shown = race.appearances(.formFade).first else { return XCTFail("no form cue") }
        XCTAssertGreaterThan(shown.trueDistance, race.plan.distanceMeters * 2 / 3)
        XCTAssertTrue(shown.texts.contains { $0.hasPrefix("CADENCE -") }, "\(shown.texts)")
        XCTAssertEqual(race.appearances(.formFade).count, 1, "once per episode")
        // Without a glance it never shows.
        XCTAssertTrue(cueRace(.slowFade(from: 9 * mile)).appearances(.formFade).isEmpty)
    }

    func testWalkthroughCadenceStaysUnderTheFiveHalfPercentLine() {
        // The design: "Form fade: cadence down 4%, under the 5% line" — held back all race.
        let race = cueRace(.designWalkthrough, atGun: true)
        XCTAssertTrue(race.proposals(.formFade).isEmpty)
    }
}
