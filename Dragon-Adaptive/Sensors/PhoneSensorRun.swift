//  PhoneSensorRun.swift
//  A real run's inputs from the phone in a pocket: CoreLocationSource and
//  PhoneMotionSource on one RunTimeline, merged into RunEvents. The live run
//  model hands them to a RunPacer, which feeds RunEngine and the recording.
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
    private(set) var timeline: RunTimeline?
    private(set) var isRunning = false

    init(providers: Providers, location: CoreLocationSource.Config = .init(), motion: PhoneMotionSource.Config = .init()) {
        self.providers = providers
        self.location = CoreLocationSource(provider: providers.location, clock: providers.clock, config: location)
        self.motion = PhoneMotionSource(motion: providers.motion, pedometer: providers.pedometer,
                                        altimeter: providers.altimeter, clock: providers.clock, config: motion)
        self.location.onSample = { [weak self] in self?.onEvent?(.location($0)) }
        self.motion.onSample = { [weak self] in self?.onEvent?(.vitals($0)) }
    }

    static func system() -> PhoneSensorRun { PhoneSensorRun(providers: .system()) }

    /// Run time now (0 before the start; it stands still while paused).
    var runTime: TimeInterval { timeline?.runTime(on: providers.clock) ?? 0 }

    /// The gun: run time 0 is now.
    func start() {
        guard timeline == nil else { return resume() }
        let timeline = RunTimeline(startingOn: providers.clock)
        self.timeline = timeline
        location.timeline = timeline
        motion.timeline = timeline
        startSensors()
    }

    func pause() {
        guard isRunning else { return }
        timeline?.pause(on: providers.clock)
        location.stop()
        motion.stop()
        isRunning = false
    }

    func resume() {
        guard timeline != nil, !isRunning else { return }
        timeline?.resume(on: providers.clock)
        location.timeline = timeline
        motion.timeline = timeline
        startSensors()
    }

    func stop() {
        location.stop()
        motion.stop()
        isRunning = false
    }

    private func startSensors() {
        isRunning = true
        location.start()
        motion.start()
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
        return "\(gps) · \(phone)"
    }
}
