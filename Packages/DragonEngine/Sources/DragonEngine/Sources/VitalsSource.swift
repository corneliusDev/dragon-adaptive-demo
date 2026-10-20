//  VitalsSource.swift
//  Motion + heart-rate input: the synthetic stream, the iPhone's motion
//  sensors (motion, pedometer cadence, barometric altitude) and, next, the Watch.
//  Same idea as AttentionSource — the engine never knows where samples
//  come from, so swapping in the real watch is a one-line change in HUDController.
//  Each sample does say which device it came from, because the state estimator
//  prefers a different device for each reading (see SourceSelection).

import Foundation

/// The device a vitals sample came from.
public enum VitalsDevice: String, Sendable, Codable, CaseIterable {
    case watch
    case phone
    /// The stand-alone synthetic watch; plays the Watch's role.
    case synthetic

    /// True for the Watch and anything standing in for it.
    public var isWatch: Bool { self != .phone }
}

public struct VitalsSample: Sendable, Equatable, Codable {
    public let timestamp: TimeInterval   // source run time (seconds) when the sample was taken
    public let heartRate: Double?        // bpm; nil when this sample carries no HR reading
    public let motion: Double?           // 0–100 exertion; nil when this sample carries no motion reading
    public let cadence: Double?          // steps per minute; nil when this sample carries no cadence
    /// Metres from the barometer, relative to wherever it started (only
    /// differences mean anything); nil when this sample carries no altitude.
    public let altitude: Double?
    public let source: VitalsDevice

    public init(timestamp: TimeInterval, heartRate: Double?, motion: Double?,
                cadence: Double? = nil, altitude: Double? = nil, source: VitalsDevice = .watch) {
        self.timestamp = timestamp
        self.heartRate = heartRate
        self.motion = motion
        self.cadence = cadence
        self.altitude = altitude
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp, heartRate, motion, cadence, altitude, source
    }

    // Recordings made before samples carried a source decode as Watch samples.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(timestamp: try c.decode(TimeInterval.self, forKey: .timestamp),
                  heartRate: try c.decodeIfPresent(Double.self, forKey: .heartRate),
                  motion: try c.decodeIfPresent(Double.self, forKey: .motion),
                  cadence: try c.decodeIfPresent(Double.self, forKey: .cadence),
                  altitude: try c.decodeIfPresent(Double.self, forKey: .altitude),
                  source: try c.decodeIfPresent(VitalsDevice.self, forKey: .source) ?? .watch)
    }
}

public protocol VitalsSource: AnyObject {
    var onSample: ((VitalsSample) -> Void)? { get set }
    func start()
    func stop()
}
