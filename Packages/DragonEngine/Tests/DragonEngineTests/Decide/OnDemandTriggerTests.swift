//  OnDemandTriggerTests.swift
//  Chunk 9: a glance gets the projected finish, a held look the last three
//  splits and the pace needed, and before the start the target; the budget
//  lets the answer through below its usual priority, but not in a
//  safety-only stretch.

import XCTest
@testable import DragonEngine

final class OnDemandTriggerTests: XCTestCase {
    private let plan = RunPlan(distanceMeters: 21_097.5, targetTime: 6_300)
    private let mile = DistanceUnit.metersPerMile

    private func split(_ n: Int, _ time: TimeInterval) -> SplitTrigger.Split {
        SplitTrigger.Split(marker: n, unit: .miles, crossedAt: 0, time: time, planTime: 481)
    }

    func testAGlanceShowsTheProjectedFinish() {
        let trigger = OnDemandTrigger(plan: plan)
        let s = RunState(elapsed: 2_019, distance: 4.2 * mile, projectedFinish: 6_301, gapToTarget: 1)
        guard let cue = trigger.answer(.glance, state: s, splits: [], at: 2_019) else { return XCTFail() }
        XCTAssertEqual(cue.key, .status)
        XCTAssertEqual(cue.priority, .info)
        XCTAssertEqual(cue.reveal, .glance)
        XCTAssertEqual(cue.minShow, 1.5)
        XCTAssertEqual(cue.expiresAt, 2_020.5)
        XCTAssertEqual(CueFormat.string(cue.content.heading!), "PROJECTED FINISH")
        XCTAssertEqual(CueFormat.string(cue.content.main), "1:45:01")
        XCTAssertEqual(cue.content.subtitle.map { CueFormat.string($0) }, ["+0:01 ON PLAN"])
        XCTAssertEqual(cue.content.tag, "STATUS")
        // Off target by more than the pace-gap threshold, it says which way.
        let behind = RunState(elapsed: 5_066, distance: 10.5 * mile, projectedFinish: 6_348)
        XCTAssertEqual(trigger.answer(.glance, state: behind, splits: [], at: 0)?.content.subtitle
            .map { CueFormat.string($0) }, ["+0:48 BEHIND"])
    }

    func testAHeldLookShowsTheLastThreeSplitsAndThePaceNeeded() {
        let trigger = OnDemandTrigger(plan: plan)
        let s = RunState(elapsed: 5_405, distance: 11.2 * mile, projectedFinish: 6_322)
        let splits = [split(8, 519), split(9, 464), split(10, 478), split(11, 494)]
        guard let cue = trigger.answer(.dwell, state: s, splits: splits, at: 5_405) else { return XCTFail() }
        XCTAssertEqual(cue.key, .detail)
        XCTAssertEqual(cue.reveal, .dwell)
        XCTAssertEqual(cue.minShow, 2.6)
        XCTAssertEqual(CueFormat.string(cue.content.heading!), "LAST 3 SPLITS")
        XCTAssertEqual(cue.content.rows.map { CueFormat.string($0.label) + " " + CueFormat.string($0.value) },
                       ["MILE 9 7:44", "MILE 10 7:58", "MILE 11 8:14"])
        // (6300 − 5405) s over the 1.91 mi left.
        XCTAssertEqual(CueFormat.string(cue.content.main), "NEED 7:49 / MI")
        XCTAssertEqual(CueFormat.string(cue.content.footer!), "PROJ 1:45:22 +0:22")
    }

    func testBeforeTheStartAGlanceShowsTheTarget() {
        let trigger = OnDemandTrigger(plan: plan)
        let s = RunState(elapsed: 0, distance: 0, phase: .stopped)
        guard let cue = trigger.answer(.glance, state: s, splits: [], at: 0) else { return XCTFail() }
        XCTAssertEqual(cue.key, .target)
        XCTAssertEqual(cue.minShow, 4)
        XCTAssertEqual([cue.content.heading, cue.content.main].compactMap { $0 }.map { CueFormat.string($0) },
                       ["TARGET", "1:45:00"])
        XCTAssertEqual(cue.content.subtitle.map { CueFormat.string($0) }, ["8:01 / MI EVEN"])
        XCTAssertEqual(CueFormat.string(cue.content.footer!), "GLANCE FOR STATUS")
    }

    func testIdleAsksNothingAndNoProjectionNoStatus() {
        let trigger = OnDemandTrigger(plan: plan)
        let running = RunState(elapsed: 600, distance: 2_000, projectedFinish: 6_300)
        XCTAssertNil(trigger.answer(.idle, state: running, splits: [], at: 600))
        XCTAssertNil(trigger.answer(.glance, state: RunState(elapsed: 600, distance: 2_000), splits: [], at: 600))
    }

    func testTheAnswerGetsThroughARaceBudgetButNotASafetyOnlyOne() {
        let answer = OnDemandTrigger(plan: plan).answer(.glance, state: RunState(elapsed: 600, distance: 2_000,
                                                                                 projectedFinish: 6_300),
                                                         splits: [], at: 600)!
        var capacity = Capacity(raceDistance: plan.distanceMeters)
        capacity.note(AttentionSample(t: 600, event: .glance))
        let racing = capacity.budget(for: RunState(elapsed: 600, distance: 2_000, effortScore: 80), at: 600)
        XCTAssertEqual(racing.minPriority, .advisory)
        XCTAssertTrue(racing.answersRequests)
        XCTAssertTrue(racing.admits(answer))
        var arbiter = Arbiter()
        XCTAssertEqual(arbiter.decide([answer], budget: racing, at: 600).showing?.key, .status)
        // An automatic info cue still isn't let through.
        var auto = answer
        auto.reveal = .auto
        XCTAssertFalse(racing.admits(auto))
        // In a kick, nothing but safety, asked for or not.
        let kick = capacity.budget(for: RunState(elapsed: 600, distance: 2_000, effortScore: 95, phase: .kick), at: 600)
        XCTAssertFalse(kick.answersRequests)
        XCTAssertFalse(kick.admits(answer))
    }

    func testRunEngineAnswersAGlanceWithTheStatusOnTheNextUpdate() {
        var run = SyntheticRun(profile: .onPlan)
        var engine = RunEngine(plan: run.plan)
        var answered: RunEngine.Step?
        while run.time < 700, answered == nil {
            for e in run.advance(by: 1) { engine.ingest(e) }
            if run.time == 600 { engine.ingest(.attention(AttentionSample(t: 600, event: .glance))) }
            let step = engine.update(at: run.time)
            if step.current?.key == .status { answered = step }
        }
        XCTAssertEqual(answered?.state.elapsed, 600)
        XCTAssertEqual(answered?.budget.maxElements, 3)
    }
}
