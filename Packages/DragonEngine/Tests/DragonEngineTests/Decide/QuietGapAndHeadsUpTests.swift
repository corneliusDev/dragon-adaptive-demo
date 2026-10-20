//  QuietGapAndHeadsUpTests.swift
//  Chunk 14's two arbiter rules on hand-made cues: the quiet gap between two
//  cues in a row (safety, critical and answers don't wait it out), and the
//  heads-up a predictable cue gets before it takes the screen — on time when
//  its trigger announced it, the lead late when not, none for heart rate or
//  answers, and a lapsed announcement starting afresh.

import XCTest
import DragonEngine

final class QuietGapAndHeadsUpTests: XCTestCase {
    private func cue(_ key: CueKey, _ priority: Priority, at t: TimeInterval, show: TimeInterval = 3,
                     requested: Bool = false) -> Cue {
        Cue(key: key, priority: priority, content: CueContent(main: .label("X")),
            createdAt: t, expiresAt: t + 30, minShow: show, requested: requested)
    }

    private func arbiter(gap: TimeInterval = 1.5, lead: TimeInterval = 0) -> Arbiter {
        var c = Arbiter.Config()
        c.quietGap = gap
        c.headsUpLead = lead
        return Arbiter(config: c)
    }

    /// Runs the arbiter at `step` from `from` to `to`; returns the run time each key went on screen.
    private func run(_ a: inout Arbiter, proposals: [TimeInterval: [Cue]], from: TimeInterval, to: TimeInterval,
                     step: TimeInterval = 0.1, announce: [TimeInterval: CueKey] = [:]) -> [(t: TimeInterval, key: CueKey)] {
        var shown: [(TimeInterval, CueKey)] = []
        var t = from
        while t <= to + 1e-9 {
            let now = (t * 10).rounded() / 10
            if let key = announce[now] { a.announce(key, at: now) }
            let d = a.decide(proposals[now] ?? [], budget: .relaxed, at: now).decisions
            for x in d where x.reason == .won || { if case .interrupted = x.reason { return true }; return false }() {
                shown.append((now, x.key))
            }
            t += step
        }
        return shown
    }

    // MARK: Quiet gap

    func testTwoCuesInARowAreSeparatedByTheQuietGap() {
        var a = arbiter()
        let shown = run(&a, proposals: [0: [cue(.split(mile: 1), .advisory, at: 0)],
                                        1: [cue(.terrain(at: 2_000), .advisory, at: 1)]], from: 0, to: 8)
        XCTAssertEqual(shown.map(\.key), [.split(mile: 1), .terrain(at: 2_000)])
        // The split is up 0–3; the screen stays dark until 4.5.
        XCTAssertEqual(shown[1].t, 4.5, accuracy: 1e-9)
        // Meanwhile the terrain cue says why it waits.
        var b = arbiter()
        _ = b.decide([cue(.split(mile: 1), .advisory, at: 0)], budget: .steady, at: 0)
        _ = b.decide([cue(.terrain(at: 2_000), .advisory, at: 1)], budget: .steady, at: 1)
        let d = b.decide([], budget: .steady, at: 3.5).decisions
        XCTAssertTrue(d.contains { $0.reason == .finished })
        XCTAssertEqual(d.first { $0.key == .terrain(at: 2_000) }?.reason, .quietGap(until: 5))
        XCTAssertEqual(d.first { $0.key == .terrain(at: 2_000) }?.outcome, .heldBack)
    }

    func testTheGapIsConfigurableAndOffAtZero() {
        var a = arbiter(gap: 0)
        let shown = run(&a, proposals: [0: [cue(.split(mile: 1), .advisory, at: 0)],
                                        1: [cue(.terrain(at: 2_000), .advisory, at: 1)]], from: 0, to: 8)
        XCTAssertEqual(shown[1].t, 3, accuracy: 1e-9)
        var b = arbiter(gap: 3)
        let later = run(&b, proposals: [0: [cue(.split(mile: 1), .advisory, at: 0)],
                                        1: [cue(.terrain(at: 2_000), .advisory, at: 1)]], from: 0, to: 8)
        XCTAssertEqual(later[1].t, 6, accuracy: 1e-9)
    }

    func testSafetyCriticalAndAnswersDontWaitOutTheGap() {
        for (next, why) in [(cue(.kickClock, .safety, at: 1), "safety"), (cue(.fuel(1), .critical, at: 1), "critical"),
                            (cue(.status, .info, at: 1, requested: true), "an answer")] {
            var a = arbiter()
            let shown = run(&a, proposals: [0: [cue(.split(mile: 1), .advisory, at: 0)], 1: [next]], from: 0, to: 8)
            // Critical and safety interrupt the split; the answer waits for it, then shows at once.
            XCTAssertEqual(shown.map(\.key).last, next.key, why)
            XCTAssertLessThanOrEqual(shown.last!.t, 3, why)
        }
    }

    func testNoGapAfterAWithdrawal() {
        // The kick clock comes down at the line and the result shows at once.
        var a = arbiter()
        _ = a.decide([cue(.kickClock, .safety, at: 0, show: 60)], budget: .relaxed, at: 0)
        a.withdraw(.kickClock, at: 10)
        let d = a.decide([cue(.finish, .info, at: 10)], budget: .relaxed, at: 10)
        XCTAssertEqual(d.showing?.key, .finish)
        XCTAssertTrue(d.decisions.contains { $0.key == .kickClock && $0.reason == .withdrawn })
    }

    // MARK: Heads-up

    func testAPredictableCueShowsTheLeadAfterItsHeadsUp() {
        var a = arbiter(lead: 1.5)
        let shown = run(&a, proposals: [10: [cue(.split(mile: 1), .advisory, at: 10)]], from: 9, to: 14)
        XCTAssertEqual(shown.map(\.t), [11.5], accuracy: 1e-9, "not announced: it waits its heads-up")
        var b = arbiter(lead: 1.5)
        _ = b.decide([cue(.split(mile: 1), .advisory, at: 10)], budget: .steady, at: 10)
        XCTAssertEqual(b.headsUp(at: 10)?.key, .split(mile: 1))
        XCTAssertEqual(b.headsUp(at: 10)?.since, 10)
        let d = b.decide([], budget: .steady, at: 11).decisions
        XCTAssertEqual(d.first?.reason, .headsUp(until: 11.5))
        XCTAssertEqual(d.first?.outcome, .heldBack)
    }

    func testAnAnnouncedCueShowsOnArrival() {
        var a = arbiter(lead: 1.5)
        let shown = run(&a, proposals: [10: [cue(.split(mile: 1), .advisory, at: 10)]], from: 8, to: 14,
                        announce: [8.5: .split(mile: 1)])
        XCTAssertEqual(shown.map(\.t), [10], accuracy: 1e-9)
        XCTAssertNil(a.headsUp(at: 10), "the heads-up ends as the cue appears")
    }

    func testALapsedAnnouncementStartsAfresh() {
        var a = arbiter(lead: 1.5)
        // Announced at 5, but the cue comes at 10: well past the lead and tolerance.
        let shown = run(&a, proposals: [10: [cue(.split(mile: 1), .advisory, at: 10)]], from: 4, to: 14,
                        announce: [5: .split(mile: 1)])
        XCTAssertEqual(shown.map(\.t), [11.5], accuracy: 1e-9)
        XCTAssertNil(a.headsUp(at: 7), "lapsed")
    }

    func testSafetyGetsAHeadsUpTooButUnpredictableCuesAndAnswersDont() {
        var a = arbiter(lead: 1.5)
        let kick = run(&a, proposals: [10: [cue(.kickClock, .safety, at: 10, show: 60)]], from: 8, to: 14,
                       announce: [8.5: .kickClock])
        XCTAssertEqual(kick.map(\.t), [10], accuracy: 1e-9)
        for c in [cue(.heartCeiling, .critical, at: 10), cue(.status, .info, at: 10, requested: true),
                  cue(.formFade, .info, at: 10, requested: true)] {
            var b = arbiter(lead: 1.5)
            let shown = run(&b, proposals: [10: [c]], from: 9, to: 12)
            XCTAssertEqual(shown.map(\.t), [10], accuracy: 1e-9, c.key.name)
            XCTAssertTrue(b.announced.isEmpty, c.key.name)
        }
    }

    func testTheHeadsUpRunsSoTheCueShowsAsTheGapEnds() {
        var a = arbiter(lead: 1.5)
        // The split is up 0–3, the gap to 4.5; the terrain cue's heads-up starts at 3 to show at 4.5.
        let shown = run(&a, proposals: [0: [cue(.split(mile: 1), .advisory, at: 0)],
                                        1: [cue(.terrain(at: 2_000), .advisory, at: 1)]], from: 0, to: 8)
        // The split itself had to wait its heads-up (not announced).
        XCTAssertEqual(shown.map(\.t), [1.5, 6], accuracy: 1e-9)
        // Announced ahead (as its trigger would), the split shows on arrival.
        var c = arbiter(lead: 1.5)
        c.announce(.split(mile: 1), at: -1.5)
        let onTime = run(&c, proposals: [0: [cue(.split(mile: 1), .advisory, at: 0)],
                                         1: [cue(.terrain(at: 2_000), .advisory, at: 1)]], from: 0, to: 8)
        XCTAssertEqual(onTime.map(\.t), [0, 4.5], accuracy: 1e-9)
    }
}

private func XCTAssertEqual(_ a: [TimeInterval], _ b: [TimeInterval], accuracy: Double, _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, "\(a) vs \(b) \(message)", file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, "\(a) vs \(b) \(message)", file: file, line: line) }
}
