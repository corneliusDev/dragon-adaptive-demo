//  VitalsSource.swift
//  Motion + heart-rate input. Today: synthetic stream. Next: Apple Watch.
//  Same idea as AttentionSource — the engine never knows where samples
//  come from, so swapping in the real watch is a one-line change in HUDController.

import Foundation

public struct VitalsSample: Sendable, Equatable, Codable {
    public let timestamp: TimeInterval   // source run time (seconds) when the sample was taken
    public let heartRate: Double?        // bpm; nil when this sample carries no HR reading
    public let motion: Double?           // 0–100 exertion; nil when this sample carries no motion reading

    public init(timestamp: TimeInterval, heartRate: Double?, motion: Double?) {
        self.timestamp = timestamp
        self.heartRate = heartRate
        self.motion = motion
    }
}

public protocol VitalsSource: AnyObject {
    var onSample: ((VitalsSample) -> Void)? { get set }
    func start()
    func stop()
}
