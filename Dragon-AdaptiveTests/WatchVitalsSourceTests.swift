//  WatchVitalsSourceTests.swift
//  The phone's Watch link with a fake transport: messages that arrive late,
//  twice or out of order; versions this build doesn't speak; starting and
//  ending the Watch workout with the run; a Bluetooth gap reaching the
//  engine as missing heart rate; the link's routes; the heart-source choice;
//  and "Fill from Health".

import XCTest
import DragonEngine
@testable import Dragon_Adaptive

final class WatchVitalsSourceTests: XCTestCase {
    private var clock: FakeClock!
    private var transport: FakeWatchTransport!
    private var control: FakeWatchControl!
    private var source: WatchVitalsSource!
    private var maker: WatchMessageMaker!
    private var samples: [VitalsSample] = []
    /// Uptime of run time 0.
    private var start: TimeInterval = 0

    override func setUp() {
        clock = FakeClock()
        transport = FakeWatchTransport()
        control = FakeWatchControl()
        source = WatchVitalsSource(transport: transport, control: control, clock: clock)
        maker = WatchMessageMaker(clock: clock)
        samples = []
        source.onSample = { [unowned self] in samples.append($0) }
        start = clock.uptime
        source.timeline = RunTimeline(startingOn: clock)
        source.start()
    }

    /// Moves the phone's clock to run time `t`.
    private func at(_ t: TimeInterval) { clock.uptime = start + t }

    func testReadingsArriveAsWatchSamplesInRunTime() {
        at(10.4)
        transport.deliver(maker.hr(152, uptime: start + 10))
        transport.deliver(maker.effort(47, uptime: start + 10))
        XCTAssertEqual(samples, [VitalsSample(timestamp: 10, heartRate: 152, motion: nil, source: .watch),
                                 VitalsSample(timestamp: 10, heartRate: nil, motion: 47, source: .watch)])
        XCTAssertEqual(source.lastHeartRate?.bpm, 152)
        XCTAssertEqual(source.lastDelay ?? -1, 0.4, accuracy: 1e-6)
        XCTAssertTrue(source.summary.contains("Watch HR 152"), source.summary)
    }

    func testDelayedDuplicatedAndOutOfOrderMessages() {
        let first = maker.hr(150, uptime: start + 20)
        let second = maker.hr(151, uptime: start + 21)
        let third = maker.hr(153, uptime: start + 22)

        // `second` arrives first, 2 s late; then by the other route too.
        at(23)
        transport.deliver(second, route: .connectivity)
        transport.deliver(second, route: .mirroring)
        // `first` turns up after it: older than what's been applied.
        transport.deliver(first)
        // `third`, delayed 3.5 s: still fresh enough.
        at(25.5)
        transport.deliver(third)

        XCTAssertEqual(samples.map(\.timestamp), [21, 22])
        XCTAssertEqual(samples.compactMap(\.heartRate), [151, 153])
        let c = source.filter.counts
        XCTAssertEqual(c.received, 4)
        XCTAssertEqual(c.dropped(.duplicate), 1)
        XCTAssertEqual(c.dropped(.outOfOrder), 1)
        XCTAssertEqual(source.byRoute[.mirroring], 1)
    }

    func testStaleByRunTimeIsDropped() {
        at(40)
        transport.deliver(maker.hr(150, uptime: start + 32))   // 8 s old
        XCTAssertTrue(samples.isEmpty)
        XCTAssertEqual(source.filter.counts.dropped(.stale), 1)
        // A fresh one after it still applies.
        transport.deliver(maker.hr(151, uptime: start + 39.5))
        XCTAssertEqual(samples.map(\.timestamp), [39.5])
    }

    func testStalenessCountsRunTimeNotTheWatchClockAcrossAPause() {
        // Paused 60 s at run time 10; a reading taken just after resuming is
        // fresh in run time even though a minute of wall clock went by.
        at(10)
        var timeline = source.timeline!
        timeline.pause(on: clock)
        clock.uptime += 60
        timeline.resume(on: clock)
        source.timeline = timeline
        clock.uptime += 1
        transport.deliver(maker.hr(149, uptime: clock.uptime - 0.5))
        XCTAssertEqual(samples.first?.timestamp ?? -1, 10.5, accuracy: 1e-6)
    }

    func testOtherVersionsAndGarbageAreRejectedCleanly() {
        at(5)
        transport.deliver(Data(#"{"v":2,"session":"w","seq":1,"sentAt":1,"kind":"hr","value":150,"at":1}"#.utf8))
        transport.deliver(Data(#"{"v":0,"session":"w","seq":1,"sentAt":1,"kind":"hr","value":150,"at":1}"#.utf8))
        transport.deliver(Data("garbage".utf8))
        XCTAssertTrue(samples.isEmpty)
        XCTAssertEqual(source.rejected, [.unsupportedVersion(2), .unsupportedVersion(0), .malformed])
        // The link keeps working after them.
        transport.deliver(maker.hr(150, uptime: start + 4.8))
        XCTAssertEqual(samples.count, 1)
    }

    func testStartAsksForTheWorkoutOnceAndStopEndsIt() {
        XCTAssertEqual(control.starts, 1)
        source.pause()
        source.start()
        XCTAssertEqual(control.starts, 1, "resuming doesn't start a second workout")
        source.stop()
        XCTAssertEqual(control.ends, 1)
        source.stop()
        XCTAssertEqual(control.ends, 1)
    }

    func testPausedIgnoresMessages() {
        source.pause()
        at(3)
        transport.deliver(maker.hr(150, uptime: start + 3))
        XCTAssertTrue(samples.isEmpty)
    }

    func testWorkoutEndedOnTheWatchEndsTheRunAndIsNotEndedAgain() {
        var ended = 0
        source.onEndedRemotely = { ended += 1 }
        at(2)
        transport.deliver(maker.state(.running, uptime: start + 1.8))
        XCTAssertEqual(source.sessionState, .running)
        XCTAssertEqual(ended, 0)
        at(600)
        transport.deliver(maker.state(.ended, uptime: start + 599.7))
        XCTAssertEqual(ended, 1)
        source.stop()
        XCTAssertEqual(control.ends, 0, "the Watch ended it; nothing to ask")
    }

    func testCouldNotStartTheWatchIsSaid() {
        let control = FakeWatchControl()
        control.answer = false
        let s = WatchVitalsSource(transport: FakeWatchTransport(), control: control, clock: clock)
        s.timeline = RunTimeline(startingOn: clock)
        s.start()
        XCTAssertTrue(s.startFailed)
        XCTAssertTrue(s.summary.contains("couldn't start"), s.summary)
    }
}

/// The Watch in a phone-sensor run: through PhoneSensorRun, the pacer and the engine.
final class WatchPhoneRunTests: XCTestCase {
    func testHeartRateReachesTheEngineAndABluetoothGapIsMissing() throws {
        let fakes = FakeSensors()
        let transport = FakeWatchTransport()
        let control = FakeWatchControl()
        let watch = WatchVitalsSource(transport: transport, control: control, clock: fakes.clock)
        let sensors = PhoneSensorRun(providers: fakes.providers, heart: watch)
        XCTAssertEqual(sensors.heartSource, .watch)
        let model = LiveRunModel(plan: SampleData.parkFiveK, feed: .phone(sensors))
        XCTAssertEqual(model.heartSource, .watch)
        var maker = WatchMessageMaker(clock: fakes.clock)
        let start = fakes.clock.uptime
        model.start(timer: false)
        XCTAssertTrue(model.hasStarted)
        XCTAssertEqual(control.starts, 1, "START starts the Watch workout")

        var queued: [WatchMessage] = []
        /// Heart rate on the screen at each whole second (nil: missing).
        var heart: [Int: Double] = [:]
        for tick in 1...(70 * 20) {
            let t = Double(tick) * 0.05
            fakes.clock.uptime = start + t
            if tick % 20 == 10 {   // a reading taken each second, arriving half a second later
                let m = maker.hr(150, uptime: start + t - 0.5)
                if (20.0..<40.0).contains(t) {
                    queued.append(m)   // out of range: held on the Watch
                } else {
                    if t > 40, !queued.isEmpty {
                        for q in queued { transport.deliver(q, route: .mirroring) }   // the burst back in range
                        queued = []
                    }
                    transport.deliver(m, route: .mirroring)
                }
            }
            model.advance(realSeconds: 0.05)
            if tick % 20 == 0, let bpm = model.state?.heartRate { heart[tick / 20] = bpm }
        }
        // Engine time runs 2 s behind the sensors (the pacer's lag).
        XCTAssertEqual(heart[15], 150, "flowing before the gap")
        XCTAssertNil(heart[30], "missing during the gap")
        XCTAssertNil(heart[40], "still missing until the link is back")
        XCTAssertEqual(heart[60], 150, "back after the gap")
        // Missing from 5 s after the last reading before the gap (taken at
        // 19 s; the engine runs 2 s behind) until the burst at 40.5 s. Of the
        // burst's 20 readings (taken 20–39 s), only the 4 under 5 s old are
        // fresh enough to use; the other 16 are dropped as stale, so the gap
        // stays a gap.
        let missing = (10...69).filter { heart[$0] == nil }
        XCTAssertEqual(missing.first, 27)
        XCTAssertEqual(missing.last, 40)
        XCTAssertEqual(watch.filter.counts.dropped(.stale), 16)
        XCTAssertTrue(model.state?.quality.heartRateMissing == false)

        try model.end(store: AppEnvironment.temporary().runs)
        XCTAssertEqual(control.ends, 1, "END ends the Watch workout")
    }

    func testEndingOnTheWatchAsksTheScreenToEndTheRun() {
        let fakes = FakeSensors()
        let transport = FakeWatchTransport()
        let control = FakeWatchControl()
        let sensors = PhoneSensorRun(providers: fakes.providers,
                                     heart: WatchVitalsSource(transport: transport, control: control, clock: fakes.clock))
        let model = LiveRunModel(plan: SampleData.parkFiveK, feed: .phone(sensors))
        var maker = WatchMessageMaker(clock: fakes.clock)
        model.start(timer: false)
        fakes.clock.uptime += 30
        XCTAssertFalse(model.endedOnWatch)
        transport.deliver(maker.state(.ended, uptime: fakes.clock.uptime - 0.2))
        XCTAssertTrue(model.endedOnWatch)
    }

    func testSyntheticWatchFeedRunsOnRunTime() {
        let clock = FakeClock()
        let feed = SyntheticWatchFeed(clock: clock)
        var got: [VitalsSample] = []
        feed.onSample = { got.append($0) }
        feed.timeline = RunTimeline(startingOn: clock)
        clock.uptime += 30
        feed.tick()
        XCTAssertGreaterThan(got.filter { $0.heartRate != nil }.count, 20)
        XCTAssertTrue(got.allSatisfy { $0.source == .synthetic && $0.timestamp <= 30 + 1e-9 })
        XCTAssertEqual(got.last?.timestamp ?? 0, 30, accuracy: 0.11)
    }
}

final class WatchLinkTests: XCTestCase {
    private func link(mirroring: Bool, connectivity: Bool, health: FakeHealthStore = FakeHealthStore())
        -> (WatchLink, FakeWatchTransport, FakeWatchTransport) {
        let wc = FakeWatchTransport(reachable: connectivity)
        let mirror = FakeWatchTransport(reachable: mirroring)
        return (WatchLink(connectivity: wc, mirroring: mirror, health: health), wc, mirror)
    }

    func testSendPrefersTheMirroredWorkout() {
        let (l, wc, mirror) = link(mirroring: true, connectivity: true)
        XCTAssertTrue(l.send(Data("x".utf8)))
        XCTAssertEqual(mirror.sent.count, 1)
        XCTAssertEqual(wc.sent.count, 0)
        XCTAssertEqual(l.statusText, "Mirrored workout")

        let (l2, wc2, mirror2) = link(mirroring: false, connectivity: true)
        XCTAssertTrue(l2.send(Data("x".utf8)))
        XCTAssertEqual(wc2.sent.count, 1)
        XCTAssertEqual(mirror2.sent.count, 0)
        XCTAssertEqual(l2.statusText, "Watch app reachable")

        let (l3, _, _) = link(mirroring: false, connectivity: false)
        XCTAssertFalse(l3.send(Data("x".utf8)))
        XCTAssertEqual(l3.statusText, "Watch not reachable")
    }

    func testStartUsesHealthThenFallsBackToACommand() {
        let health = FakeHealthStore()
        let (l, wc, _) = link(mirroring: false, connectivity: true, health: health)
        var ok: Bool?
        l.startWorkout { ok = $0 }
        XCTAssertEqual(health.authorizationRequests, 1)
        XCTAssertEqual(health.watchAppRequests, 1)
        XCTAssertEqual(ok, true)
        XCTAssertTrue(wc.sent.isEmpty, "Health started it; no command needed")

        health.watchAppStarts = false
        l.startWorkout { ok = $0 }
        XCTAssertEqual(ok, true)
        XCTAssertEqual(wc.sentMessages.map(\.body), [.command(.startWorkout)])
    }

    func testEndGoesByEveryRouteThatsUp() {
        let (l, wc, mirror) = link(mirroring: true, connectivity: true)
        l.endWorkout()
        XCTAssertEqual(mirror.sentMessages.map(\.body), [.command(.endWorkout)])
        XCTAssertEqual(wc.sentMessages.map(\.body), [.command(.endWorkout)])
        XCTAssertEqual(mirror.sentMessages.first, wc.sentMessages.first, "the same message: the Watch drops the copy")
    }

    func testEveryArrivalIsLoggedAndHandedOn() {
        let (l, wc, mirror) = link(mirroring: true, connectivity: true)
        var handed: [WatchRoute] = []
        l.onReceive = { _, route in handed.append(route) }
        var seq = WatchMessageSequencer(session: "w")
        wc.deliver(seq.message(.heartRate(bpm: 150, at: 1), sentAt: 1))
        mirror.deliver(seq.message(.effort(score: 40, at: 2), sentAt: 2), route: .mirroring)
        wc.deliver(Data(#"{"v":3}"#.utf8))
        XCTAssertEqual(handed, [.connectivity, .mirroring, .connectivity])
        XCTAssertEqual(l.received, 3)
        XCTAssertEqual(l.receipts.map(\.text), ["rejected: unsupportedVersion(3)", "effort 40 · seq 1", "hr 150 · seq 0"])
    }

    func testActivateSetsUpTheMirroringHandler() {
        let (l, _, mirror) = link(mirroring: false, connectivity: false)
        l.activate()
        XCTAssertEqual(mirror.activated, 1)
    }
}

final class HeartSourceChoiceTests: XCTestCase {
    func testPickingTheHeartSourceRebuildsTheRunAndIsRemembered() {
        let env = AppEnvironment.temporary()
        env.runSource.source = .phone
        let fakes = FakeSensors()
        var built: [HeartSource] = []
        let setup = LiveRunSetup(environment: env, heartSensors: { heart in
            built.append(heart)
            let feed: RunVitalsFeed?
            switch heart {
            case .none: feed = nil
            case .watch: feed = WatchVitalsSource(transport: FakeWatchTransport(), control: FakeWatchControl(), clock: fakes.clock)
            case .synthetic: feed = SyntheticWatchFeed(clock: fakes.clock)
            }
            return PhoneSensorRun(providers: fakes.providers, heart: feed)
        })
        XCTAssertEqual(env.heartSource.source, HeartSource.none)
        let first = setup.model(for: SampleData.parkFiveK)
        XCTAssertEqual(first.heartSource, HeartSource.none)

        let watch = setup.switchHeart(of: first, to: HeartSource.watch)
        XCTAssertEqual(watch.heartSource, .watch)
        XCTAssertEqual(env.heartSource.source, .watch)
        let synthetic = setup.switchHeart(of: watch, to: HeartSource.synthetic)
        XCTAssertEqual(synthetic.heartSource, .synthetic)
        XCTAssertEqual(built, [.none, .watch, .synthetic])

        // Once a real run has started, the choice is remembered but the run is left alone.
        synthetic.start(timer: false)
        XCTAssertTrue(synthetic.hasStarted)
        XCTAssertTrue(setup.switchHeart(of: synthetic, to: HeartSource.none) === synthetic)
        XCTAssertEqual(env.heartSource.source, HeartSource.none)
    }

    func testUITestEnvironmentPicksTheHeartSource() {
        let none = AppEnvironment.make(arguments: ["-uiTesting"], environment: [:])
        XCTAssertEqual(none.heartSource.source, HeartSource.none)
        let watch = AppEnvironment.make(arguments: ["-uiTesting"], environment: ["DRAGON_HEART_SOURCE": "watch"])
        XCTAssertEqual(watch.heartSource.source, .watch)
    }
}

final class HealthZonesTests: XCTestCase {
    func testDesignRunnerFromHealth() {
        // Rest 52, a recorded 188 peak: the design's runner, threshold 172.
        let e = try? HealthZoneEstimate.make(from: HealthHeartRates(resting: 52, recordedMax: 188, age: 40)).get()
        XCTAssertEqual(e?.resting, 52)
        XCTAssertEqual(e?.max, 188)
        XCTAssertEqual(e?.threshold, 172)
        XCTAssertEqual(e?.maxSource, "highest recorded")
    }

    func testMaxFromAgeWhenNothingHigherIsRecorded() {
        // Tanaka: 208 − 0.7 × 30 = 187, above a recorded 171.
        let e = try? HealthZoneEstimate.make(from: HealthHeartRates(resting: 60, recordedMax: 171, age: 30)).get()
        XCTAssertEqual(e?.max, 187)
        XCTAssertEqual(e?.maxSource, "predicted from age")
        let ageOnly = try? HealthZoneEstimate.make(from: HealthHeartRates(resting: 60, recordedMax: nil, age: 30)).get()
        XCTAssertEqual(ageOnly?.max, 187)
    }

    func testMissingNumbersSayWhy() {
        XCTAssertEqual(HealthZoneEstimate.make(from: HealthHeartRates(resting: nil, recordedMax: 190, age: 30)),
                       .failure(.noResting))
        XCTAssertEqual(HealthZoneEstimate.make(from: HealthHeartRates(resting: 55, recordedMax: nil, age: nil)),
                       .failure(.noMax))
        XCTAssertEqual(HealthZoneEstimate.make(from: HealthHeartRates(resting: 80, recordedMax: 85, age: nil)),
                       .failure(.outOfOrder))
    }

    func testFillFromHealthFillsTheEditorAndTheNumbersSave() {
        let health = FakeHealthStore()
        health.rates = HealthHeartRates(resting: 52, recordedMax: 188, age: 41)
        let model = PlanEditorModel(plan: SampleData.parkFiveK)
        var done = false
        model.fillFromHealth(health) { done = true }
        XCTAssertTrue(done)
        XCTAssertEqual(health.authorizationRequests, 1)
        XCTAssertEqual(health.lookBack, 365)
        XCTAssertEqual([model.resting, model.threshold, model.maxHeartRate], ["52", "172", "188"])
        XCTAssertTrue(model.zonesFromHealth)
        XCTAssertTrue(model.healthNote?.contains("From Health") ?? false)
        XCTAssertEqual(model.zones, ZoneInputs(resting: 52, threshold: 172, max: 188))
        XCTAssertTrue(model.problems.isEmpty, "\(model.problems)")
    }

    func testFillFromHealthWithNothingLeavesTheFieldsAndSaysWhy() {
        let health = FakeHealthStore()
        let model = PlanEditorModel()
        model.fillFromHealth(health)
        XCTAssertEqual(model.resting, "")
        XCTAssertFalse(model.zonesFromHealth)
        XCTAssertTrue(model.healthNote?.contains("no resting heart rate") ?? false)

        health.isAvailable = false
        model.fillFromHealth(health)
        XCTAssertTrue(model.healthNote?.contains("isn't available") ?? false)
    }
}
