//  PhoneSensorRun.swift
//  A real run's inputs from the phone in a pocket: CoreLocationSource and
//  PhoneMotionSource on one RunTimeline, merged into RunEvents. The live run
//  model hands them to a RunPacer, which feeds RunEngine and the recording.
//
//  Heart rate and wrist motion come from a RunVitalsFeed on the same
//  timeline (the Watch, the synthetic Watch, or none: HeartSource).
//
//  Pausing stops the sensors and the run clock; resuming starts both again,
//  with the pause left out of run time.

import Foundation
import DragonEngine

final class PhoneSensorRun {
    struct Providers {
        var location: LocationProviding
        var motion: MotionProviding
        var pedometer: PedometerProviding
        var altimeter: AltimeterProviding
        var clock: SensorClock

        static func system() -> Providers {
            Providers(location: SystemLocationProvider(), motion: SystemMotionProvider(),
                      pedometer: SystemPedometerProvider(), altimeter: SystemAltimeterProvider(),
                      clock: SystemSensorClock())
        }
    }

    /// Every input, in run time, as it arrives.
    var onEvent: ((RunEvent) -> Void)?

    let providers: Providers
    let location: CoreLocationSource
    let motion: PhoneMotionSource
    /// Heart rate and wrist motion (the Watch, or its synthetic stand-in); nil for none.
    private(set) var heart: RunVitalsFeed?
    /// Which of the heart sources `heart` is.
    var heartSource: HeartSource {
        switch heart {
        case nil: return .none
        case is WatchVitalsSource: return .watch
        default: return .synthetic
        }
    }
    /// The feed's end ended the run (the Watch workout was ended on the Watch).
    var onEndedRemotely: (() -> Void)? {
        didSet { heart?.onEndedRemotely = onEndedRemotely }
    }
    private(set) var timeline: RunTimeline?
    private(set) var isRunning = false

    init(providers: Providers, heart: RunVitalsFeed? = nil, location: CoreLocationSource.Config = .init(),
         motion: PhoneMotionSource.Config = .init()) {
        self.providers = providers
        self.heart = heart
        self.location = CoreLocationSource(provider: providers.location, clock: providers.clock, config: location)
        self.motion = PhoneMotionSource(motion: providers.motion, pedometer: providers.pedometer,
                                        altimeter: providers.altimeter, clock: providers.clock, config: motion)
        self.location.onSample = { [weak self] in self?.onEvent?(.location($0)) }
        self.motion.onSample = { [weak self] in self?.onEvent?(.vitals($0)) }
        self.heart?.onSample = { [weak self] in self?.onEvent?(.vitals($0)) }
    }

    static func system(heart: HeartSource = .none) -> PhoneSensorRun {
        let providers = Providers.system()
        let feed: RunVitalsFeed?
        switch heart {
        case .watch:
            feed = WatchVitalsSource(transport: WatchLink.shared, control: WatchLink.shared, clock: providers.clock)
        case .synthetic:
            feed = SyntheticWatchFeed(clock: providers.clock)
        case .none:
            feed = nil
        }
        return PhoneSensorRun(providers: providers, heart: feed)
    }

    /// Run time now (0 before the start; it stands still while paused).
    var runTime: TimeInterval { timeline?.runTime(on: providers.clock) ?? 0 }

    /// The gun: run time 0 is now.
    func start() {
        guard timeline == nil else { return resume() }
        let timeline = RunTimeline(startingOn: providers.clock)
        self.timeline = timeline
        location.timeline = timeline
        motion.timeline = timeline
        heart?.timeline = timeline
        startSensors()
    }

    func pause() {
        guard isRunning else { return }
        timeline?.pause(on: providers.clock)
        location.stop()
        motion.stop()
        heart?.pause()
        isRunning = false
    }

    func resume() {
        guard timeline != nil, !isRunning else { return }
        timeline?.resume(on: providers.clock)
        location.timeline = timeline
        motion.timeline = timeline
        heart?.timeline = timeline
        startSensors()
    }

    func stop() {
        location.stop()
        motion.stop()
        heart?.stop()
        isRunning = false
    }

    private func startSensors() {
        isRunning = true
        location.start()
        motion.start()
        heart?.start()
    }

    /// "GPS ±5 m · 312 fixes · motion, cadence, altitude": what's coming in.
    var summary: String {
        let gps: String
        if let last = location.last {
            gps = "GPS ±\(Int(last.horizontalAccuracy.rounded())) m · \(location.sent) fix\(location.sent == 1 ? "" : "es")"
        } else {
            gps = isRunning ? "Waiting for GPS" : "GPS off"
        }
        let a = motion.availability
        let streams = [a.motion ? "motion" : nil, a.cadence ? "cadence" : nil, a.altitude ? "altitude" : nil].compactMap { $0 }
        let phone = streams.isEmpty ? "no motion sensors on this device" : streams.joined(separator: ", ")
        guard let heart else { return "\(gps) · \(phone)" }
        return "\(gps) · \(phone) · \(heart.summary)"
    }
}
