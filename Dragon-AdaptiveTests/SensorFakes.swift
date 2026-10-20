//  SensorFakes.swift
//  Test stand-ins for Core Location and Core Motion behind the provider
//  protocols, and a clock the test moves by hand.

import Foundation
import CoreLocation
@testable import Dragon_Adaptive

final class FakeClock: SensorClock {
    /// Wall-clock date at uptime 0.
    let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
    var uptime: TimeInterval = 1_000
    var now: Date { base.addingTimeInterval(uptime) }
    func date(uptime u: TimeInterval) -> Date { base.addingTimeInterval(u) }
}

final class FakeLocationProvider: LocationProviding {
    var authorization: SensorAuthorization
    var onLocations: (([CLLocation]) -> Void)?
    var onAuthorizationChange: ((SensorAuthorization) -> Void)?
    private(set) var requested = 0
    private(set) var started: [Bool] = []          // the `background` flag of each start
    private(set) var stopped = 0
    var isUpdating = false
    /// What the "system" answers to the request.
    var answer: SensorAuthorization = .allowed

    init(authorization: SensorAuthorization = .allowed) {
        self.authorization = authorization
    }

    func requestWhenInUseAuthorization() {
        requested += 1
        authorization = answer
        onAuthorizationChange?(answer)
    }

    func startRunUpdates(background: Bool) {
        started.append(background)
        isUpdating = true
    }

    func stopUpdates() {
        stopped += 1
        isUpdating = false
    }

    /// Delivers fixes, as Core Location would, while updating.
    func deliver(_ locations: [CLLocation]) {
        if isUpdating { onLocations?(locations) }
    }
}

final class FakeMotionProvider: MotionProviding {
    var isAvailable: Bool
    private var handler: ((DeviceMotionReading) -> Void)?
    private(set) var interval: TimeInterval?

    init(available: Bool = true) { isAvailable = available }

    func start(interval: TimeInterval, handler: @escaping (DeviceMotionReading) -> Void) {
        self.interval = interval
        self.handler = handler
    }

    func stop() { handler = nil }
    var isRunning: Bool { handler != nil }
    func deliver(_ r: DeviceMotionReading) { handler?(r) }
}

final class FakePedometerProvider: PedometerProviding {
    var isCadenceAvailable: Bool
    var authorization: SensorAuthorization
    var answer: SensorAuthorization = .allowed
    private(set) var requested = 0
    private(set) var startDate: Date?
    private var handler: ((PedometerReading) -> Void)?

    init(available: Bool = true, authorization: SensorAuthorization = .allowed) {
        isCadenceAvailable = available
        self.authorization = available ? authorization : .unavailable
    }

    func requestAuthorization(completion: @escaping (SensorAuthorization) -> Void) {
        requested += 1
        authorization = answer
        completion(answer)
    }

    func start(from date: Date, handler: @escaping (PedometerReading) -> Void) {
        startDate = date
        self.handler = handler
    }

    func stop() { handler = nil }
    var isRunning: Bool { handler != nil }
    func deliver(_ r: PedometerReading) { handler?(r) }
}

final class FakeAltimeterProvider: AltimeterProviding {
    var isAvailable: Bool
    private var handler: ((AltimeterReading) -> Void)?

    init(available: Bool = true) { isAvailable = available }

    func start(handler: @escaping (AltimeterReading) -> Void) { self.handler = handler }
    func stop() { handler = nil }
    var isRunning: Bool { handler != nil }
    func deliver(_ r: AltimeterReading) { handler?(r) }
}

/// A full set of fakes on one clock.
struct FakeSensors {
    let clock = FakeClock()
    let location: FakeLocationProvider
    let motion: FakeMotionProvider
    let pedometer: FakePedometerProvider
    let altimeter: FakeAltimeterProvider

    init(location: SensorAuthorization = .allowed, motionAvailable: Bool = true,
         motion: SensorAuthorization = .allowed) {
        self.location = FakeLocationProvider(authorization: location)
        self.motion = FakeMotionProvider(available: motionAvailable)
        pedometer = FakePedometerProvider(available: motionAvailable, authorization: motion)
        altimeter = FakeAltimeterProvider(available: motionAvailable)
    }

    var providers: PhoneSensorRun.Providers {
        PhoneSensorRun.Providers(location: location, motion: motion, pedometer: pedometer,
                                 altimeter: altimeter, clock: clock)
    }

    func run() -> PhoneSensorRun { PhoneSensorRun(providers: providers) }
}

extension CLLocation {
    /// A fix as Core Location makes one, every field settable.
    static func fix(_ lat: Double, _ lon: Double, at date: Date, accuracy: Double = 5, speed: Double = 3.4,
                    speedAccuracy: Double = 0.5, altitude: Double = 30, verticalAccuracy: Double = 4) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), altitude: altitude,
                   horizontalAccuracy: accuracy, verticalAccuracy: verticalAccuracy, course: 0, courseAccuracy: 5,
                   speed: speed, speedAccuracy: speedAccuracy, timestamp: date)
    }
}
