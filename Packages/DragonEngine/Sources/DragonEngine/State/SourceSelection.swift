//  SourceSelection.swift
//  Which device each reading comes from (decided in planning):
//      heart rate  Watch only; stale after 5 s → missing
//      effort      Watch wrist motion when fresh, else iPhone motion (3 s)
//      cadence     iPhone pedometer first, Watch as fallback (5 s)
//      pace/dist   iPhone GPS (course distance when a course is loaded)
//  When the preferred device goes stale we switch to the other one and say so
//  in DataQuality. Readings are never averaged across devices: two sensors
//  measuring different things (wrist swing vs. hip bounce) blend into a number
//  neither of them saw.

import Foundation

/// One device's latest value of a reading, and when it was taken (run time).
public struct SourceReading: Sendable, Equatable {
    public var value: Double
    public var t: TimeInterval
    public var source: VitalsDevice

    public init(value: Double, t: TimeInterval, source: VitalsDevice) {
        self.value = value
        self.t = t
        self.source = source
    }
}

/// The reading chosen, and whether it came from the fallback device.
public struct SelectedReading: Sendable, Equatable {
    public var reading: SourceReading
    public var isFallback: Bool
}

public enum SourceSelection {
    public static let heartRateStaleAfter: TimeInterval = 5
    public static let motionStaleAfter: TimeInterval = 3
    /// Pedometers report every couple of seconds, so cadence gets HR's allowance.
    public static let cadenceStaleAfter: TimeInterval = 5

    /// True when a reading is no older than `staleAfter` at run time `t`.
    public static func isFresh(_ r: SourceReading?, at t: TimeInterval, staleAfter: TimeInterval) -> Bool {
        guard let r else { return false }
        return t - r.t <= staleAfter
    }

    /// Preferred reading if fresh, else the fallback if fresh, else nil.
    public static func pick(preferred: SourceReading?, fallback: SourceReading?,
                            at t: TimeInterval, staleAfter: TimeInterval) -> SelectedReading? {
        if isFresh(preferred, at: t, staleAfter: staleAfter), let p = preferred {
            return SelectedReading(reading: p, isFallback: false)
        }
        if isFresh(fallback, at: t, staleAfter: staleAfter), let f = fallback {
            return SelectedReading(reading: f, isFallback: true)
        }
        return nil
    }

    /// Heart rate: Watch only, never the phone.
    public static func heartRate(watch: SourceReading?, at t: TimeInterval) -> SourceReading? {
        isFresh(watch, at: t, staleAfter: heartRateStaleAfter) ? watch : nil
    }

    /// Effort: Watch wrist motion, falling back to iPhone motion.
    public static func effort(watch: SourceReading?, phone: SourceReading?, at t: TimeInterval) -> SelectedReading? {
        pick(preferred: watch, fallback: phone, at: t, staleAfter: motionStaleAfter)
    }

    /// Cadence: iPhone pedometer, falling back to the Watch.
    public static func cadence(phone: SourceReading?, watch: SourceReading?, at t: TimeInterval) -> SelectedReading? {
        pick(preferred: phone, fallback: watch, at: t, staleAfter: cadenceStaleAfter)
    }
}
