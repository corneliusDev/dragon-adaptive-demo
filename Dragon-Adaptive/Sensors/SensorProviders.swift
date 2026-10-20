//  SensorProviders.swift
//  Thin protocols over Core Location and Core Motion, so the adapters
//  (CoreLocationSource, PhoneMotionSource) can be tested with fakes. The
//  system implementations are in SystemSensorProviders.swift; they do no
//  mapping or filtering, only hand the readings on.
//
//  Locations stay CLLocation (easy to make in a test). Core Motion's data
//  types can't be made outside the framework, so the motion providers hand
//  over plain readings with the fields the adapter uses.
//
//  Also here: the clocks the readings are timed by, and RunTimeline, which
//  turns a device timestamp into run time (seconds since the run started,
//  less any time paused): what the engine works in.

import Foundation
import CoreLocation

/// Whether the app may use a sensor.
enum SensorAuthorization: Equatable {
    case notDetermined
    case allowed
    case denied
    /// Blocked by parental controls or a device policy; the runner can't change it.
    case restricted
    /// The hardware isn't there (motion sensors in the simulator).
    case unavailable
}

// MARK: Location

protocol LocationProviding: AnyObject {
    var authorization: SensorAuthorization { get }
    /// Every batch of fixes, as Core Location delivers them.
    var onLocations: (([CLLocation]) -> Void)? { get set }
    var onAuthorizationChange: ((SensorAuthorization) -> Void)? { get set }
    /// Shows the system's "while using the app" request (once).
    func requestWhenInUseAuthorization()
    /// Starts fixes for a run: fitness activity, best accuracy, every fix, no
    /// automatic pauses; with `background`, also with the screen locked (and
    /// the location indicator showing).
    func startRunUpdates(background: Bool)
    func stopUpdates()
}

// MARK: Motion

/// One device-motion reading: acceleration the user gave the phone (gravity
/// removed), in g, and when (seconds since boot, as Core Motion times it).
struct DeviceMotionReading: Equatable {
    var timestamp: TimeInterval
    var x: Double
    var y: Double
    var z: Double
}

protocol MotionProviding: AnyObject {
    var isAvailable: Bool { get }
    /// Delivers readings every `interval` seconds on the main queue until stop().
    func start(interval: TimeInterval, handler: @escaping (DeviceMotionReading) -> Void)
    func stop()
}

/// One pedometer update: the stretch it covers ends at `endDate`;
/// `cadence` is steps per second (Core Motion's unit), nil when not known.
struct PedometerReading: Equatable {
    var endDate: Date
    var cadence: Double?
}

protocol PedometerProviding: AnyObject {
    var isCadenceAvailable: Bool { get }
    /// Motion & Fitness permission (the pedometer and altimeter need it).
    var authorization: SensorAuthorization { get }
    /// Shows the system's Motion & Fitness request (once) and reports the answer.
    func requestAuthorization(completion: @escaping (SensorAuthorization) -> Void)
    func start(from date: Date, handler: @escaping (PedometerReading) -> Void)
    func stop()
}

/// One barometer update: metres from where it started, and when (seconds since boot).
struct AltimeterReading: Equatable {
    var timestamp: TimeInterval
    var relativeAltitude: Double
}

protocol AltimeterProviding: AnyObject {
    var isAvailable: Bool { get }
    func start(handler: @escaping (AltimeterReading) -> Void)
    func stop()
}

// MARK: Clocks

/// The two clocks device readings are timed by.
protocol SensorClock: AnyObject {
    /// Wall clock: Core Location's and the pedometer's timestamps.
    var now: Date { get }
    /// Seconds since boot: Core Motion's timestamps.
    var uptime: TimeInterval { get }
}

final class SystemSensorClock: SensorClock {
    var now: Date { Date() }
    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// Turns device timestamps into run time: seconds since the run started,
/// less the time spent paused.
struct RunTimeline: Equatable {
    let startDate: Date
    let startUptime: TimeInterval
    /// Seconds paused so far (not counting a pause still on).
    private(set) var paused: TimeInterval = 0
    /// Uptime the current pause began; nil while running.
    private(set) var pausedAt: TimeInterval?

    init(startDate: Date, startUptime: TimeInterval) {
        self.startDate = startDate
        self.startUptime = startUptime
    }

    /// A run starting now on `clock`.
    init(startingOn clock: SensorClock) {
        self.init(startDate: clock.now, startUptime: clock.uptime)
    }

    func runTime(date: Date) -> TimeInterval { date.timeIntervalSince(startDate) - paused }
    func runTime(uptime: TimeInterval) -> TimeInterval { uptime - startUptime - paused }

    /// Run time now; it stands still while paused.
    func runTime(on clock: SensorClock) -> TimeInterval {
        runTime(uptime: pausedAt ?? clock.uptime)
    }

    mutating func pause(on clock: SensorClock) {
        if pausedAt == nil { pausedAt = clock.uptime }
    }

    mutating func resume(on clock: SensorClock) {
        guard let at = pausedAt else { return }
        paused += max(0, clock.uptime - at)
        pausedAt = nil
    }
}

/// Readings an adapter threw away, and why.
struct DroppedReadings: Equatable {
    /// Unusable: negative accuracy, NaN, out of range.
    var invalid = 0
    /// Too old when they arrived, from before the run started, or not newer than the last one.
    var stale = 0
}
