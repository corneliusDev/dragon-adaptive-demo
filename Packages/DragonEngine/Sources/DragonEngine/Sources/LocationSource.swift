//  LocationSource.swift
//  GPS input. Today: SyntheticRun or a ReplaySource. Next: CoreLocation in the app.
//  Same idea as VitalsSource — the engine only sees LocationSamples, never
//  where they came from. Metres, seconds and degrees, like CLLocation.

import Foundation

public struct LocationSample: Sendable, Equatable, Codable {
    public let t: TimeInterval              // run time (seconds) when the fix was taken
    public let latitude: Double
    public let longitude: Double
    public let horizontalAccuracy: Double   // metres; the true position is within this radius for ~95% of fixes
    public let speed: Double?               // m/s from the receiver (Doppler), nil when unknown
    public let altitude: Double?            // metres, nil when unknown

    public init(t: TimeInterval, latitude: Double, longitude: Double, horizontalAccuracy: Double,
                speed: Double? = nil, altitude: Double? = nil) {
        self.t = t
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
        self.altitude = altitude
    }
}

/// A live or replayed GPS stream. Sources inside the engine are steppable
/// (they have no clock); the app wraps them in a timer, or adapts CoreLocation.
public protocol LocationSource: AnyObject {
    var onSample: ((LocationSample) -> Void)? { get set }
    func start()
    func stop()
}
