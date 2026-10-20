//  SystemSensorProviders.swift
//  The real Core Location and Core Motion behind the provider protocols.
//  No mapping or filtering here (that's the adapters' job, tested with
//  fakes): these only configure the managers and hand readings on, on the
//  main queue.

import Foundation
import CoreLocation
import CoreMotion

final class SystemLocationProvider: NSObject, LocationProviding, CLLocationManagerDelegate {
    var onLocations: (([CLLocation]) -> Void)?
    var onAuthorizationChange: ((SensorAuthorization) -> Void)?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
    }

    var authorization: SensorAuthorization {
        SystemLocationProvider.authorization(manager.authorizationStatus)
    }

    static func authorization(_ status: CLAuthorizationStatus) -> SensorAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorizedWhenInUse, .authorizedAlways: return .allowed
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    /// The app declares background location (UIBackgroundModes); turning
    /// allowsBackgroundLocationUpdates on without it would crash.
    static var hasBackgroundLocationMode: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("location") ?? false
    }

    func requestWhenInUseAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func startRunUpdates(background: Bool) {
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        if background && SystemLocationProvider.hasBackgroundLocationMode {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }
        manager.startUpdatingLocation()
    }

    func stopUpdates() {
        manager.stopUpdatingLocation()
        if SystemLocationProvider.hasBackgroundLocationMode {
            manager.allowsBackgroundLocationUpdates = false
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        onLocations?(locations)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown is transient (no fix yet); a denial arrives as an authorization change.
        print("[SystemLocationProvider] \(error.localizedDescription)")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChange?(authorization)
    }
}

final class SystemMotionProvider: MotionProviding {
    private let manager = CMMotionManager()

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start(interval: TimeInterval, handler: @escaping (DeviceMotionReading) -> Void) {
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = interval
        manager.startDeviceMotionUpdates(to: .main) { motion, _ in
            guard let motion else { return }
            let a = motion.userAcceleration
            handler(DeviceMotionReading(timestamp: motion.timestamp, x: a.x, y: a.y, z: a.z))
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }
}

final class SystemPedometerProvider: PedometerProviding {
    private let pedometer = CMPedometer()

    var isCadenceAvailable: Bool { CMPedometer.isCadenceAvailable() }

    var authorization: SensorAuthorization {
        guard CMPedometer.isStepCountingAvailable() || CMPedometer.isCadenceAvailable() else { return .unavailable }
        switch CMPedometer.authorizationStatus() {
        case .notDetermined: return .notDetermined
        case .authorized: return .allowed
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    /// Core Motion asks the first time it's used: a short query does that.
    func requestAuthorization(completion: @escaping (SensorAuthorization) -> Void) {
        guard authorization == .notDetermined else { return completion(authorization) }
        let now = Date()
        pedometer.queryPedometerData(from: now.addingTimeInterval(-60), to: now) { [weak self] _, _ in
            DispatchQueue.main.async { completion(self?.authorization ?? .denied) }
        }
    }

    func start(from date: Date, handler: @escaping (PedometerReading) -> Void) {
        guard CMPedometer.isStepCountingAvailable() else { return }
        pedometer.startUpdates(from: date) { data, _ in
            guard let data else { return }
            let reading = PedometerReading(endDate: data.endDate, cadence: data.currentCadence?.doubleValue)
            DispatchQueue.main.async { handler(reading) }
        }
    }

    func stop() { pedometer.stopUpdates() }
}

final class SystemAltimeterProvider: AltimeterProviding {
    private let altimeter = CMAltimeter()

    var isAvailable: Bool { CMAltimeter.isRelativeAltitudeAvailable() }

    func start(handler: @escaping (AltimeterReading) -> Void) {
        guard isAvailable else { return }
        altimeter.startRelativeAltitudeUpdates(to: .main) { data, _ in
            guard let data else { return }
            handler(AltimeterReading(timestamp: data.timestamp, relativeAltitude: data.relativeAltitude.doubleValue))
        }
    }

    func stop() { altimeter.stopRelativeAltitudeUpdates() }
}
