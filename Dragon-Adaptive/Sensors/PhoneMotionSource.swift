//  PhoneMotionSource.swift
//  The iPhone's motion sensors as a DragonEngine VitalsSource (source
//  .phone): three streams, each its own VitalsSample.
//
//      motion    device motion at 50 Hz, summarised once a second into the
//                0–100 effort score the synthetic streams use (same scale:
//                MotionBand's light from 6, moderate from 38, hard from 72).
//                The score is the RMS of the user acceleration (gravity
//                removed) over the second, placed linearly between a phone
//                at rest on a moving body and an all-out sprint.
//      cadence   the pedometer's current cadence, steps a minute.
//      altitude  the barometer's relative altitude, metres.
//
//  A reading is dropped, and counted, when it's invalid (NaN, negative or
//  implausible cadence) or stale (older than `maxAge` when it arrives, from
//  before the run, or not newer than the last of its kind). A second of
//  motion with too few readings in it isn't scored. Sensors this phone lacks
//  (all of them in the simulator) simply send nothing; `availability` says
//  which.

import Foundation
import DragonEngine

final class PhoneMotionSource: VitalsSource {
    struct Config: Equatable {
        /// Seconds between device-motion readings (50 Hz).
        var motionInterval: TimeInterval = 1.0 / 50
        /// Seconds of motion per effort score.
        var window: TimeInterval = 1
        /// A window with fewer readings than this isn't scored.
        var minReadingsPerWindow = 10
        /// RMS user acceleration (g) that scores 0: a phone on a body barely moving.
        var restingAcceleration = 0.03
        /// RMS user acceleration (g) that scores 100: an all-out sprint with the
        /// phone in a pocket. Race pace lands around 0.6–0.9 g. To tune in the field.
        var fullEffortAcceleration = 1.2
        /// Seconds; motion and altitude readings older than this when they arrive are stale.
        var maxAge: TimeInterval = 5
        /// Seconds; the pedometer reports every couple of seconds, a little behind.
        var pedometerMaxAge: TimeInterval = 10
        /// Steps a minute above which a cadence reading is nonsense.
        var maxCadence = 260.0

        /// Effort score (0–100) for an RMS user acceleration in g.
        func effort(rms: Double) -> Double {
            let span = fullEffortAcceleration - restingAcceleration
            guard span > 0 else { return 0 }
            return min(100, max(0, (rms - restingAcceleration) / span * 100))
        }
    }

    struct Availability: Equatable {
        var motion: Bool
        var cadence: Bool
        var altitude: Bool
        var any: Bool { motion || cadence || altitude }
    }

    var onSample: ((VitalsSample) -> Void)?
    let motion: MotionProviding
    let pedometer: PedometerProviding
    let altimeter: AltimeterProviding
    let clock: SensorClock
    let config: Config
    /// Set by PhoneSensorRun before start(); readings are dropped without it.
    var timeline: RunTimeline?

    private(set) var dropped = DroppedReadings()
    private(set) var sent = 0
    private(set) var isStarted = false

    /// The motion window being filled: its index (run time ÷ window), Σa², count.
    private var window: (index: Int, sumSquares: Double, count: Int)?
    private var lastMotionAt: TimeInterval?
    private var lastCadenceAt: TimeInterval?
    private var lastAltitudeAt: TimeInterval?

    init(motion: MotionProviding, pedometer: PedometerProviding, altimeter: AltimeterProviding,
         clock: SensorClock, config: Config = Config()) {
        self.motion = motion
        self.pedometer = pedometer
        self.altimeter = altimeter
        self.clock = clock
        self.config = config
    }

    var availability: Availability {
        Availability(motion: motion.isAvailable, cadence: pedometer.isCadenceAvailable, altitude: altimeter.isAvailable)
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        if motion.isAvailable {
            motion.start(interval: config.motionInterval) { [weak self] in self?.receive($0) }
        }
        if pedometer.isCadenceAvailable, let timeline {
            pedometer.start(from: timeline.startDate) { [weak self] in self?.receive($0) }
        }
        if altimeter.isAvailable {
            altimeter.start { [weak self] in self?.receive($0) }
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        motion.stop()
        pedometer.stop()
        altimeter.stop()
        window = nil
    }

    // MARK: Readings

    func receive(_ r: DeviceMotionReading) {
        guard let timeline else { return }
        guard r.timestamp.isFinite, r.x.isFinite, r.y.isFinite, r.z.isFinite else { return dropped.invalid += 1 }
        let t = timeline.runTime(uptime: r.timestamp)
        guard clock.uptime - r.timestamp <= config.maxAge, t >= 0 else { return dropped.stale += 1 }
        if let last = lastMotionAt, t <= last { return dropped.stale += 1 }
        lastMotionAt = t

        let index = Int((t / config.window).rounded(.down))
        if let w = window, index != w.index {
            // A reading from a later second closes the one being filled.
            if w.count >= config.minReadingsPerWindow {
                let rms = (w.sumSquares / Double(w.count)).squareRoot()
                send(VitalsSample(timestamp: Double(w.index + 1) * config.window, heartRate: nil,
                                  motion: config.effort(rms: rms), source: .phone))
            }
            window = nil
        }
        let a2 = r.x * r.x + r.y * r.y + r.z * r.z
        if let w = window {
            window = (w.index, w.sumSquares + a2, w.count + 1)
        } else {
            window = (index, a2, 1)
        }
    }

    func receive(_ r: PedometerReading) {
        guard let timeline, let perSecond = r.cadence else { return }
        let spm = perSecond * 60
        guard spm.isFinite, spm >= 0, spm <= config.maxCadence else { return dropped.invalid += 1 }
        let t = timeline.runTime(date: r.endDate)
        guard clock.now.timeIntervalSince(r.endDate) <= config.pedometerMaxAge, t >= 0 else { return dropped.stale += 1 }
        if let last = lastCadenceAt, t <= last { return dropped.stale += 1 }
        lastCadenceAt = t
        send(VitalsSample(timestamp: t, heartRate: nil, motion: nil, cadence: spm.rounded(), source: .phone))
    }

    func receive(_ r: AltimeterReading) {
        guard let timeline else { return }
        guard r.timestamp.isFinite, r.relativeAltitude.isFinite else { return dropped.invalid += 1 }
        let t = timeline.runTime(uptime: r.timestamp)
        guard clock.uptime - r.timestamp <= config.maxAge, t >= 0 else { return dropped.stale += 1 }
        if let last = lastAltitudeAt, t <= last { return dropped.stale += 1 }
        lastAltitudeAt = t
        send(VitalsSample(timestamp: t, heartRate: nil, motion: nil, altitude: r.relativeAltitude, source: .phone))
    }

    private func send(_ s: VitalsSample) {
        sent += 1
        onSample?(s)
    }
}
