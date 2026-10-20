//  WorkoutManager.swift
//  The Watch's running workout and what it sends to the phone.
//
//      workout   HKWorkoutSession + HKLiveWorkoutBuilder, activity .running,
//                location .outdoor. Mirrored to the phone at the start
//                (startMirroringToCompanionDevice); the builder's heart
//                rate goes to the phone as each reading comes in (~1–5 s).
//      motion    WristMotionMonitor's effort score, once a second.
//      state     each workout state change (running, paused, ended…), so
//                the phone knows; ending here ends the phone's run.
//      commands  from the phone (startWorkout / endWorkout), by either
//                route, de-duplicated by WatchMessageFilter.
//
//  Every message is a DragonEngine WatchMessage (v1), numbered by one
//  WatchMessageSequencer per workout, sent by PhoneLink.
//
//  DEBUG synthetic heart rate (simulator demos, where HealthKit has no real
//  heart): SyntheticVitalsGenerator's heart rate and motion, sent through
//  the same PhoneLink as real readings, with no HealthKit session.

import Foundation
import HealthKit
import DragonEngine

final class WorkoutManager: NSObject, ObservableObject {
    static let shared = WorkoutManager()

    @Published private(set) var state: WatchSessionState?
    @Published private(set) var heartRate: Double?
    @Published private(set) var effort: Double?
    @Published private(set) var startDate: Date?
    @Published private(set) var endDate: Date?
    @Published private(set) var linkText = "iPhone not reachable"
    @Published private(set) var sent = 0
    @Published private(set) var notSent = 0
    @Published private(set) var lastError: String?
    /// Send the synthetic heart rate instead of HealthKit's (DEBUG builds only).
    @Published var syntheticHR = false

    let store = HKHealthStore()
    let link = PhoneLink()
    let motion = WristMotionMonitor()

    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var sequencer = WatchMessageSequencer(session: UUID().uuidString)
    private var commands = WatchMessageFilter()
    private var syntheticTimer: Timer?
    private var generator = SyntheticVitalsGenerator(seed: 7)
    private var lastSyntheticEffortAt = Date.distantPast
    private var activated = false

    var isActive: Bool { state == .starting || state == .running || state == .paused }

    func activate() {
        guard !activated else { return }
        activated = true
        link.onReceive = { [weak self] data in self?.received(data) }
        link.onChange = { [weak self] in self?.refreshLink() }
        link.activate()
        motion.onEffort = { [weak self] score, at in self?.sendEffort(score, at: at) }
        let args = ProcessInfo.processInfo.arguments
        #if DEBUG
        if args.contains("-syntheticHR") { syntheticHR = true }
        #endif
        if args.contains("-autostart") {
            DispatchQueue.main.async { self.start() }
        }
    }

    func requestAuthorization(completion: @escaping (Bool) -> Void = { _ in }) {
        guard HKHealthStore.isHealthDataAvailable() else { return completion(false) }
        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        let read: Set<HKObjectType> = [HKQuantityType(.heartRate), HKObjectType.workoutType()]
        store.requestAuthorization(toShare: share, read: read) { ok, error in
            if let error { NSLog("[Workout] authorization: %@", error.localizedDescription) }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    // MARK: Start / end

    /// Starts a running workout (from the button, a phone command, or startWatchApp).
    func start(configuration: HKWorkoutConfiguration? = nil) {
        activate()
        guard !isActive else { return }
        sequencer = WatchMessageSequencer(session: UUID().uuidString)
        heartRate = nil
        effort = nil
        endDate = nil
        lastError = nil
        startDate = Date()
        setState(.starting)
        #if DEBUG
        if syntheticHR { return startSynthetic() }
        #endif
        let config = configuration ?? {
            let c = HKWorkoutConfiguration()
            c.activityType = .running
            c.locationType = .outdoor
            return c
        }()
        requestAuthorization { [weak self] _ in self?.startSession(config) }
    }

    private func startSession(_ config: HKWorkoutConfiguration) {
        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder
            link.mirrored = session
            let start = Date()
            startDate = start
            session.startActivity(with: start)
            builder.beginCollection(withStart: start) { _, error in
                if let error { NSLog("[Workout] beginCollection: %@", error.localizedDescription) }
            }
            session.startMirroringToCompanionDevice { [weak self] ok, error in
                DispatchQueue.main.async {
                    self?.link.isMirroring = ok
                    if let error { NSLog("[Workout] mirroring: %@", error.localizedDescription) }
                    self?.refreshLink()
                }
            }
            motion.start()
        } catch {
            lastError = error.localizedDescription
            setState(.failed)
        }
    }

    func end() {
        guard isActive else { return }
        motion.stop()
        if let session {
            session.end()   // the delegate sends .ended and finishes the workout
        } else {
            stopSynthetic()
            endDate = Date()
            setState(.ended)
        }
    }

    // MARK: Sending

    private func send(_ body: WatchMessage.Body, important: Bool = false) {
        let m = sequencer.message(body, sentAt: Date().timeIntervalSince1970)
        let route = link.send(m.encoded(), queueIfUnreachable: important)
        if route == .none { notSent += 1 } else { sent += 1 }
    }

    private func setState(_ s: WatchSessionState) {
        state = s
        send(.state(s, at: Date().timeIntervalSince1970), important: true)
    }

    private func sendHeartRate(_ bpm: Double, at: Date) {
        heartRate = bpm
        send(.heartRate(bpm: bpm, at: at.timeIntervalSince1970))
    }

    private func sendEffort(_ score: Double, at: Date) {
        guard isActive else { return }
        effort = score
        send(.effort(score: score, at: at.timeIntervalSince1970))
    }

    private func refreshLink() {
        linkText = link.statusText
    }

    /// A command from the phone.
    private func received(_ data: Data) {
        guard let m = try? WatchMessage.decode(data) else { return }
        guard case .command(let c) = commands.accept(m, sampleTime: 0, now: 0) else { return }
        NSLog("[PhoneLink] received command %@ · seq %d", c.rawValue, m.sequence)
        switch c {
        case .startWorkout: start()
        case .endWorkout: end()
        }
    }

    // MARK: Synthetic heart rate (DEBUG)

    private func startSynthetic() {
        generator.reset()
        lastSyntheticEffortAt = .distantPast
        setState(.running)
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.syntheticTick() }
        RunLoop.main.add(t, forMode: .common)
        syntheticTimer = t
    }

    private func stopSynthetic() {
        syntheticTimer?.invalidate()
        syntheticTimer = nil
    }

    private func syntheticTick() {
        guard let s = generator.advance(by: 0.1) else { return }
        let now = Date()
        if let hr = s.heartRate { sendHeartRate(hr, at: now) }
        // The generator's motion is 10 Hz; send it as the once-a-second score.
        if let m = s.motion, now.timeIntervalSince(lastSyntheticEffortAt) >= 1 {
            lastSyntheticEffortAt = now
            sendEffort(m, at: now)
        }
    }
}

// MARK: HKWorkoutSessionDelegate

extension WorkoutManager: HKWorkoutSessionDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState, date: Date) {
        DispatchQueue.main.async {
            switch toState {
            case .running: self.setState(.running)
            case .paused: self.setState(.paused)
            case .stopped, .ended:
                guard self.state != .ended else { return }
                self.motion.stop()
                self.endDate = date
                self.setState(.ended)
                self.finish(workoutSession, at: date)
            default: break
            }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.lastError = error.localizedDescription
            self.motion.stop()
            self.setState(.failed)
        }
    }

    /// The phone sent something over the mirrored workout.
    func workoutSession(_ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        DispatchQueue.main.async {
            for d in data { self.received(d) }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?) {
        DispatchQueue.main.async {
            self.link.isMirroring = false
            self.refreshLink()
        }
    }

    private func finish(_ session: HKWorkoutSession, at date: Date) {
        guard let builder else { return }
        builder.endCollection(withEnd: date) { _, _ in
            builder.finishWorkout { _, error in
                if let error { NSLog("[Workout] finish: %@", error.localizedDescription) }
            }
        }
        self.session = nil
        self.builder = nil
        link.mirrored = nil
        link.isMirroring = false
        refreshLink()
    }
}

// MARK: HKLiveWorkoutBuilderDelegate

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let hrType = HKQuantityType(.heartRate)
        guard collectedTypes.contains(hrType), let stats = workoutBuilder.statistics(for: hrType),
              let q = stats.mostRecentQuantity() else { return }
        let bpm = q.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        let at = stats.mostRecentQuantityDateInterval()?.end ?? Date()
        DispatchQueue.main.async { self.sendHeartRate(bpm, at: at) }
    }
}
