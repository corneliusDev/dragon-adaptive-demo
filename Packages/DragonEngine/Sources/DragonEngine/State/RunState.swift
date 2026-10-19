//  RunState.swift
//  The estimator's answer to "where is the runner, how are they doing, and how
//  much should we trust it": one value per state(at:) call. Metres, seconds,
//  pace in seconds per metre; nil means unknown, never a stale guess.
//  (MovementPhase — running / walking / stopped — arrives in chunk 6.)

import Foundation

/// Something on the course worth knowing about before you reach it.
public enum CourseFeature: Sendable, Equatable {
    case hill(Hill)
    case turn(Turn)
    case aidStation(AidStation)

    /// Metres along the course where it starts.
    public var distance: Double {
        switch self {
        case .hill(let h): return h.startDistance
        case .turn(let t): return t.distance
        case .aidStation(let a): return a.distance
        }
    }

    /// Metres along the course where it's behind you.
    public var endDistance: Double {
        if case .hill(let h) = self { return h.endDistance }
        return distance
    }
}

/// The next course feature and how far away it is (0 while you're on it).
public struct Ahead: Sendable, Equatable {
    public var feature: CourseFeature
    public var meters: Double
}

/// How far to trust the rest of RunState.
public struct DataQuality: Sendable, Equatable {
    /// Reported accuracy (metres) of the latest GPS fix, used or not; nil before the first.
    public var gpsAccuracy: Double?
    /// Seconds since the latest usable GPS fix; nil before the first.
    public var secondsSinceFix: TimeInterval?
    /// Seconds since the Watch last sent heart rate; nil if it never has.
    public var secondsSinceHeartRate: TimeInterval?
    /// Latest usable fix is more than Course.offCourseThreshold from the route.
    public var offCourse = false
    /// No usable 30 s pace: GPS stale, too few good fixes, or not moving.
    public var paceUnknown = true
    /// Distance is dead-reckoned from the last fix because GPS has gone quiet.
    public var distanceEstimated = false
    /// Device the effort / cadence readings came from; nil when none is fresh.
    public var effortSource: VitalsDevice?
    public var cadenceSource: VitalsDevice?
    /// The preferred device was stale, so the other one is being used.
    public var effortFallback = false
    public var cadenceFallback = false

    public var heartRateMissing: Bool {
        (secondsSinceHeartRate ?? .infinity) > SourceSelection.heartRateStaleAfter
    }

    public init() {}
}

public struct RunState: Sendable, Equatable {
    /// Run time (seconds) this state describes.
    public var elapsed: TimeInterval
    /// Metres covered: along the course when one is loaded, else integrated GPS.
    public var distance: Double

    /// Seconds per metre over the last 30 / 60 s.
    public var pace30s: Double?
    public var pace60s: Double?
    /// pace60s as if the last 60 s had been flat (the longer window, because
    /// GAP is compared against plan pace and needs to be steady).
    public var gradeAdjustedPace: Double?

    /// Run time the runner is expected to finish at.
    public var projectedFinish: TimeInterval?
    /// projectedFinish − plan target time: + = behind.
    public var gapToTarget: TimeInterval?
    /// elapsed − plan time at this distance: + = behind the plan right now.
    public var behindPlanNow: TimeInterval?

    /// bpm, nil when the Watch hasn't sent one in the last 5 s.
    public var heartRate: Double?
    /// 1-based zone from the plan's heart rate zones.
    public var heartZone: Int?
    /// bpm gained over the last 5 minutes at a steady pace; nil when pace wasn't
    /// steady or there isn't 5 minutes of heart rate.
    public var heartDrift: Double?
    /// Steps per minute.
    public var cadence: Double?

    /// Rise / run under the runner now (0.05 = 5% uphill).
    public var grade: Double?
    public var ahead: Ahead?
    public var effort: MotionBand
    public var attention: AttentionEvent
    public var quality: DataQuality
}
