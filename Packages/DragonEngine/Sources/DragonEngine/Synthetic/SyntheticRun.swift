//  SyntheticRun.swift
//  A whole synthetic race from one seed: a virtual runner moves along the
//  plan's course at the profile's pace, and we emit what an iPhone and Apple
//  Watch would have sent — GPS at 1 Hz, HR ~1 Hz, motion ~10 Hz.
//
//  Everything comes from one effort number, so the streams agree:
//      pace   = plan pace × profile factor × grade slowdown × wobble
//      effort = planEffort × (plan pace / pace) × climb cost × heat + fatigue
//  A fade or a hill therefore shows up in GPS speed AND heart rate. HR and
//  motion come from SyntheticVitalsGenerator (same first-order HR lag, jitter
//  and dropouts as the stand-alone synthetic watch), fed this effort.
//
//  Clock-free and steppable: advance(by:) any amount; internally it always
//  steps 1/20 s, so the samples don't depend on how the caller chunks time.

import Foundation

public struct SyntheticRun {
    /// The runner's physiology.
    public struct Athlete: Sendable, Equatable {
        public var restingHR: Double = 55
        public var maxHR: Double = 190
        /// Seconds for HR to close ~63% of the gap to a new effort.
        public var hrTimeConstant: Double = 20
        /// HR at the gun (warmed up).
        public var startHR: Double = 110
        /// Effort (0–100) running the plan's pace on the flat.
        public var planEffort: Double = 80

        public init() {}
    }

    /// How the phone's GPS behaves.
    public struct GPS: Sendable, Equatable {
        /// Position error, metres: each normal fix is off by a distance in this range
        /// (wandering, correlated over ~10 s) and reports an accuracy that covers it.
        public var accuracy: ClosedRange<Double> = 3...8
        /// Accuracy during an occasional bad patch (tree cover, buildings).
        public var spikeAccuracy: Double = 30
        public var spikesPerHour: Double = 9
        public var spikeDuration: ClosedRange<Double> = 3...8
        /// Random outages on top of any the profile scripts; 0 = none.
        public var dropoutsPerHour: Double = 0
        public var dropoutDuration: ClosedRange<Double> = 5...20

        public init() {}
    }

    public static let stepsPerSecond = 20
    /// Spike error is a 2D Gaussian with per-axis sigma = accuracy / this, so ~95% of
    /// spike fixes land within the reported accuracy (sqrt(-2 ln 0.05) ≈ 2.45).
    static let accuracyToSigma = 2.45

    public let profile: SyntheticProfile
    public let plan: RunPlan
    public let seed: UInt64
    public let athlete: Athlete
    public let gps: GPS
    public let course: Course

    /// Run time reached so far (seconds).
    public private(set) var time: TimeInterval = 0
    /// True metres covered along the course.
    public private(set) var distance: Double = 0
    /// Run time the runner crossed the line, once they have.
    public private(set) var finishTime: TimeInterval?
    public var isFinished: Bool { finishTime != nil }

    /// Where the runner really is (GPS reports this plus noise).
    public var truePosition: (latitude: Double, longitude: Double) { course.position(at: distance) }

    private var vitals: SyntheticVitalsGenerator
    private var rng: SeededRNG
    private var step = 0
    private var requested: TimeInterval = 0
    private var sentStartFix = false

    // Slow state, updated once a second.
    private var wobble = 0.0                    // fractional pace wobble
    private var errorRadius: Double             // metres off, within gps.accuracy
    private var errorBearing: Double            // radians, direction of the error
    private var accuracy: Double                // reported; >= errorRadius
    private var errorUp = 0.0
    private var spikeUntil = -1.0
    private var dropoutUntil = -1.0
    private var scriptedOutage: (at: Double, duration: TimeInterval)?

    public init(profile: SyntheticProfile, seed: UInt64 = 42, plan: RunPlan? = nil,
                athlete: Athlete = Athlete(), gps: GPS = GPS()) {
        var plan = plan ?? profile.defaultPlan
        if plan.course == nil {
            plan.course = profile.course(length: plan.distanceMeters)
        }
        self.profile = profile
        self.plan = plan
        self.seed = seed
        self.athlete = athlete
        self.gps = gps
        self.course = plan.course!
        self.rng = SeededRNG(seed: seed)
        self.vitals = SyntheticVitalsGenerator(seed: seed &* 0x2545_F491_4F6C_DD1D &+ 1,
                                               restingHR: athlete.restingHR,
                                               maxHR: athlete.maxHR,
                                               hrTimeConstant: athlete.hrTimeConstant,
                                               startHR: athlete.startHR)
        self.errorRadius = rng.uniform(gps.accuracy)
        self.errorBearing = rng.uniform(0...(2 * .pi))
        self.accuracy = min(errorRadius * 1.1, gps.accuracy.upperBound)
        self.scriptedOutage = profile.gpsOutage
    }

    // MARK: Stepping

    /// Advances run time by dt seconds; returns what the devices sent meanwhile.
    public mutating func advance(by dt: TimeInterval) -> [RunEvent] {
        samples(until: requested + dt)
    }

    /// Advances run time to `t`; returns what the devices sent up to it.
    /// The first call also returns the fix at the start line (t = 0).
    public mutating func samples(until t: TimeInterval) -> [RunEvent] {
        var out: [RunEvent] = []
        if !sentStartFix {
            sentStartFix = true
            out.append(.location(fix()))
        }
        requested = max(requested, t)
        let rate = Double(SyntheticRun.stepsPerSecond)
        while !isFinished, Double(step + 1) / rate <= requested + 1e-9 {
            tick(into: &out)
        }
        return out
    }

    /// Runs to the finish and returns the whole race as a recording.
    public mutating func recordToFinish() -> RunRecording {
        let recorder = RunRecorder(name: "\(profile.name) seed \(seed)", plan: plan)
        // Generous cap: slower than half plan pace means something's broken.
        let limit = plan.targetTime * 2
        while !isFinished && time < limit {
            for event in advance(by: 60) { recorder.record(event) }
        }
        return recorder.recording
    }

    /// A whole race for a profile and seed.
    public static func record(_ profile: SyntheticProfile, seed: UInt64 = 42, plan: RunPlan? = nil) -> RunRecording {
        var run = SyntheticRun(profile: profile, seed: seed, plan: plan)
        return run.recordToFinish()
    }

    // MARK: Model

    /// Seconds per metre right now, and the grade it was run on.
    private func pace(at d: Double, t: TimeInterval) -> (pace: Double, grade: Double) {
        let g = grade(at: d)
        let slowdown = g > 0 ? 1 + 2.0 * g : max(0.85, 1 + 1.2 * g)
        let factor = profile.paceFactor(at: d, t: t, total: plan.distanceMeters)
        return (plan.targetPace(at: d) * factor * slowdown * (1 + wobble), g)
    }

    private func grade(at d: Double) -> Double {
        guard let up = course.elevation(at: d + 10), let down = course.elevation(at: d - 10) else { return 0 }
        return (up - down) / 20
    }

    private func effort(pace: Double, grade g: Double, at d: Double, t: TimeInterval) -> Double {
        let relativeSpeed = plan.targetPace(at: d) / pace
        let climbCost = g > 0 ? 1 + 3.5 * g : max(0.7, 1 + 2.0 * g)
        return athlete.planEffort * relativeSpeed * climbCost * profile.heat(at: t)
            + profile.fatigue(at: d, total: plan.distanceMeters)
    }

    private mutating func tick(into out: inout [RunEvent]) {
        let dt = 1 / Double(SyntheticRun.stepsPerSecond)
        let (p, g) = pace(at: distance, t: time)

        step += 1
        let next = Double(step) / Double(SyntheticRun.stepsPerSecond)
        if distance + dt / p >= plan.distanceMeters {
            finishTime = time + (plan.distanceMeters - distance) * p
            distance = plan.distanceMeters
            time = next
            return
        }
        distance += dt / p
        time = next

        let e = effort(pace: p, grade: g, at: distance, t: time)
        if let sample = vitals.advance(by: dt, exertion: e) {
            // Stamp with the exact run time; the generator's own clock is a running float sum.
            out.append(.vitals(VitalsSample(timestamp: time, heartRate: sample.heartRate, motion: sample.motion)))
        }

        if step % SyntheticRun.stepsPerSecond == 0 {
            updateSlowState()
            if !gpsSilent { out.append(.location(fix(speed: 1 / p))) }
        }
    }

    // MARK: GPS

    /// Once a second: pace wobble, accuracy drift, error random walk, spikes, outages.
    private mutating func updateSlowState() {
        // Pace wobble: ~0.5% with a ~30 s memory.
        let keepWobble = exp(-1.0 / 30)
        wobble = wobble * keepWobble + (1 - keepWobble * keepWobble).squareRoot() * 0.005 * rng.gaussian()

        // Position error: a distance inside gps.accuracy in a slowly turning direction,
        // both correlated over ~10 s like a real receiver. The radius mean-reverts to the
        // middle of the range (sd ≈ a quarter of its width) and is held inside it.
        let keep = exp(-1.0 / 10)
        let range = gps.accuracy
        let mid = (range.lowerBound + range.upperBound) / 2
        let spread = (range.upperBound - range.lowerBound) / 4
        errorRadius = mid + (errorRadius - mid) * keep + (1 - keep * keep).squareRoot() * spread * rng.gaussian()
        errorRadius = min(max(errorRadius, range.lowerBound), range.upperBound)
        errorBearing += 0.3 * rng.gaussian()
        errorUp = errorUp * keep + (1 - keep * keep).squareRoot() * 3 * rng.gaussian()

        // Reported accuracy covers the true error, with a little slack.
        accuracy = min(errorRadius * rng.uniform(1.0...1.25), range.upperBound)

        if time >= spikeUntil, rng.chance(gps.spikesPerHour / 3600) {
            spikeUntil = time + rng.uniform(gps.spikeDuration)
        }
        if time >= dropoutUntil, gps.dropoutsPerHour > 0, rng.chance(gps.dropoutsPerHour / 3600) {
            dropoutUntil = time + rng.uniform(gps.dropoutDuration)
        }
        if let outage = scriptedOutage, distance >= outage.at {
            dropoutUntil = max(dropoutUntil, time + outage.duration)
            scriptedOutage = nil
        }
    }

    private var gpsSilent: Bool { time < dropoutUntil }

    private mutating func fix(speed: Double? = nil) -> LocationSample {
        var east = errorRadius * sin(errorBearing), north = errorRadius * cos(errorBearing)
        var reported = accuracy
        if time < spikeUntil {
            let sigma = gps.spikeAccuracy / SyntheticRun.accuracyToSigma
            east += sigma * rng.gaussian()
            north += sigma * rng.gaussian()
            reported = gps.spikeAccuracy * rng.uniform(0.85...1.0)
        }
        let truth = truePosition
        let lat = truth.latitude + north / Course.earthRadius * 180 / .pi
        let lon = truth.longitude + east / (Course.earthRadius * cos(truth.latitude * .pi / 180)) * 180 / .pi
        let measuredSpeed = speed.map { max(0, $0 + 0.15 * rng.gaussian()) }
        let altitude = course.elevation(at: distance).map { $0 + errorUp }
        return LocationSample(t: time, latitude: lat, longitude: lon, horizontalAccuracy: reported,
                              speed: measuredSpeed, altitude: altitude)
    }
}
