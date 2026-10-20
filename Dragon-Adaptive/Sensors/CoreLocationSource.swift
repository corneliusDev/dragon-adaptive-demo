//  CoreLocationSource.swift
//  The iPhone's GPS as a DragonEngine LocationSource: Core Location fixes
//  (through a LocationProviding) mapped to LocationSamples in run time.
//
//  A fix is dropped, and counted, when it's
//      invalid  negative or NaN horizontal accuracy, or a coordinate that
//               isn't one (NaN, out of range)
//      stale    older than `maxAge` when it arrives (Core Location hands out
//               a cached fix first), taken before the run started, or not
//               newer than the last fix sent
//  Speed and altitude are passed on only when Core Location vouches for
//  them (non-negative speed and speed accuracy; non-negative vertical
//  accuracy). Accuracy itself is left to the estimator, which ignores fixes
//  worse than its own limit.

import Foundation
import CoreLocation
import DragonEngine

final class CoreLocationSource: LocationSource {
    struct Config: Equatable {
        /// Seconds; a fix older than this when it arrives is stale.
        var maxAge: TimeInterval = 10
        /// Keep updating with the screen locked (background location).
        var background = true
    }

    var onSample: ((LocationSample) -> Void)?
    let provider: LocationProviding
    let clock: SensorClock
    let config: Config
    /// Set by PhoneSensorRun before start(); fixes are dropped without it.
    var timeline: RunTimeline?

    private(set) var dropped = DroppedReadings()
    private(set) var sent = 0
    private(set) var last: LocationSample?
    private(set) var isStarted = false

    init(provider: LocationProviding, clock: SensorClock, config: Config = Config()) {
        self.provider = provider
        self.clock = clock
        self.config = config
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        provider.onLocations = { [weak self] in self?.receive($0) }
        provider.startRunUpdates(background: config.background)
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        provider.stopUpdates()
        provider.onLocations = nil
    }

    func receive(_ locations: [CLLocation]) {
        guard let timeline else { return }
        for location in locations {
            switch CoreLocationSource.map(location, timeline: timeline, now: clock.now, after: last?.t, config: config) {
            case .sample(let s):
                last = s
                sent += 1
                onSample?(s)
            case .invalid:
                dropped.invalid += 1
            case .stale:
                dropped.stale += 1
            }
        }
    }

    enum Mapped: Equatable {
        case sample(LocationSample)
        case invalid
        case stale
    }

    /// One fix in run time, or why not. `after`: run time of the last fix sent.
    static func map(_ location: CLLocation, timeline: RunTimeline, now: Date, after: TimeInterval?,
                    config: Config = Config()) -> Mapped {
        let c = location.coordinate
        let accuracy = location.horizontalAccuracy
        guard accuracy.isFinite, accuracy >= 0,
              c.latitude.isFinite, c.longitude.isFinite, CLLocationCoordinate2DIsValid(c)
        else { return .invalid }
        let age = now.timeIntervalSince(location.timestamp)
        let t = timeline.runTime(date: location.timestamp)
        guard age <= config.maxAge, t >= 0 else { return .stale }
        if let after, t <= after { return .stale }

        let speedOK = location.speed.isFinite && location.speed >= 0
            && location.speedAccuracy.isFinite && location.speedAccuracy >= 0
        let altitudeOK = location.altitude.isFinite && location.verticalAccuracy.isFinite && location.verticalAccuracy >= 0
        return .sample(LocationSample(t: t, latitude: c.latitude, longitude: c.longitude, horizontalAccuracy: accuracy,
                                      speed: speedOK ? location.speed : nil,
                                      altitude: altitudeOK ? location.altitude : nil))
    }
}
