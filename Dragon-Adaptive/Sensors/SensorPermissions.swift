//  SensorPermissions.swift
//  What the phone-sensor run may use, and the screens that explain each
//  request before the system asks. Location is required (it's the distance
//  and pace); Motion & Fitness is optional (effort, cadence, hills). A run
//  without location isn't possible: the live run then says why and how to
//  turn it on, and offers synthetic data, so the app stays usable.
//
//  prepare() lines up the explanation for the first permission not asked
//  yet; allow() asks the system for it, skip() leaves it for now. Plain
//  Swift (Observation), tested with fake providers.

import Foundation
import Observation

@Observable
final class SensorPermissions {
    enum Prompt: Equatable {
        case location
        case motion
    }

    /// The words on an explanation screen.
    struct Explanation: Equatable {
        var title: String
        var body: String
        var allow: String
    }

    static let locationExplanation = Explanation(
        title: "Location for distance and pace",
        body: "Dragon uses the iPhone's GPS while a run is on to measure distance and pace, place you on the course and project your finish. It keeps going with the screen locked (you'll see the location indicator) and stops when you end the run. The route is saved in the run's recording on this iPhone.",
        allow: "ALLOW LOCATION")

    static let motionExplanation = Explanation(
        title: "Motion & Fitness for effort and cadence",
        body: "Dragon reads the iPhone's motion sensors, step counter and barometer while a run is on to gauge your effort, your cadence and the hills. Without it the run uses GPS only.",
        allow: "ALLOW MOTION")

    private(set) var location: SensorAuthorization
    private(set) var motion: SensorAuthorization
    /// The explanation showing; nil when nothing needs asking.
    private(set) var prompt: Prompt?

    @ObservationIgnored private let locationProvider: LocationProviding
    @ObservationIgnored private let pedometer: PedometerProviding
    @ObservationIgnored private let motionProvider: MotionProviding
    @ObservationIgnored private var skipped: Set<Prompt> = []

    init(location: LocationProviding, pedometer: PedometerProviding, motion: MotionProviding) {
        locationProvider = location
        self.pedometer = pedometer
        motionProvider = motion
        self.location = location.authorization
        self.motion = SensorPermissions.motionState(pedometer: pedometer, motion: motion)
        let previous = location.onAuthorizationChange
        location.onAuthorizationChange = { [weak self] status in
            previous?(status)
            self?.locationChanged(status)
        }
    }

    convenience init(_ providers: PhoneSensorRun.Providers) {
        self.init(location: providers.location, pedometer: providers.pedometer, motion: providers.motion)
    }

    /// Phone sensors can run: location is allowed.
    var canRun: Bool { location == .allowed }

    var explanation: Explanation? {
        switch prompt {
        case .location: return SensorPermissions.locationExplanation
        case .motion: return SensorPermissions.motionExplanation
        case nil: return nil
        }
    }

    /// Why phone sensors can't run, and what to do; nil when they can (or haven't been asked).
    var locationProblem: String? {
        switch location {
        case .denied:
            return "Location is off for Dragon, so the phone can't measure the run. Turn it on in Settings › Dragon › Location (While Using the App), or run with synthetic data."
        case .restricted:
            return "Location is restricted on this iPhone, so the phone can't measure the run. Run with synthetic data instead."
        case .unavailable:
            return "This device has no location service. Run with synthetic data instead."
        case .notDetermined, .allowed:
            return nil
        }
    }

    /// How the run's motion will go, when it isn't simply on.
    var motionNote: String? {
        switch motion {
        case .allowed: return nil
        case .notDetermined: return "Motion & Fitness not asked yet: effort and cadence come from GPS alone until it is."
        case .denied, .restricted: return "Motion & Fitness is off: the run uses GPS only (no effort, cadence or barometer from the phone)."
        case .unavailable: return "Motion sensors aren't available on this device: the run uses GPS only."
        }
    }

    /// Reads the statuses again and lines up the next explanation.
    func prepare() {
        refresh()
        prompt = next()
    }

    /// Asks the system for the permission being explained.
    func allow() {
        switch prompt {
        case .location:
            locationProvider.requestWhenInUseAuthorization()
            // The answer arrives through onAuthorizationChange.
        case .motion:
            pedometer.requestAuthorization { [weak self] _ in
                guard let self else { return }
                self.refresh()
                self.prompt = self.next()
            }
        case nil:
            break
        }
    }

    /// Not now: moves on without asking.
    func skip() {
        if let prompt { skipped.insert(prompt) }
        prompt = next()
    }

    // MARK: Private

    private func refresh() {
        location = locationProvider.authorization
        motion = SensorPermissions.motionState(pedometer: pedometer, motion: motionProvider)
    }

    private func next() -> Prompt? {
        if location == .notDetermined && !skipped.contains(.location) { return .location }
        // Motion only after location is settled: one request at a time.
        if location == .notDetermined { return nil }
        if motion == .notDetermined && !skipped.contains(.motion) { return .motion }
        return nil
    }

    private func locationChanged(_ status: SensorAuthorization) {
        location = status
        if prompt == .location && status != .notDetermined { prompt = next() }
    }

    /// Motion & Fitness, or unavailable when the phone has none of the sensors.
    private static func motionState(pedometer: PedometerProviding, motion: MotionProviding) -> SensorAuthorization {
        guard pedometer.isCadenceAvailable || motion.isAvailable else { return .unavailable }
        // Device motion needs no permission; the pedometer and barometer do.
        guard pedometer.isCadenceAvailable else { return .allowed }
        return pedometer.authorization
    }
}
