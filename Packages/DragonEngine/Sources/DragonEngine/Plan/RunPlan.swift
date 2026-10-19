//  RunPlan.swift
//  What "on track" means at every point of a race: the plan time and target
//  pace at any distance, from a target finish time and a pacing strategy.
//  Distances in metres, times in seconds, pace in seconds per metre.

import Foundation

public enum PacingStrategy: Sendable, Equatable, Codable {
    /// Same pace the whole way.
    case even
    /// Second half run `percent` faster than the first, e.g. 2 = 2% faster.
    case negativeSplit(percent: Double)
    /// Relative times for equal-length splits (distance / count each).
    /// Scaled so they sum exactly to the target time, so per-mile splits that
    /// already add up are used as-is and rough shapes ("[1, 1, 0.95]") also work.
    case perSplit([TimeInterval])
}

/// Heart rate zones as bpm boundaries. `boundaries[i]` is the top of zone i+1,
/// so four boundaries give five zones.
public struct HeartRateZones: Sendable, Equatable, Codable {
    public var resting: Double
    public var threshold: Double
    public var max: Double
    public var boundaries: [Double]

    public init(resting: Double, threshold: Double, max: Double, boundaries: [Double]) {
        self.resting = resting
        self.threshold = threshold
        self.max = max
        self.boundaries = boundaries.sorted()
    }

    /// Five zones from lactate threshold HR (Friel-style: 85/89/94/100%).
    public init(resting: Double, threshold: Double, max: Double) {
        self.init(resting: resting, threshold: threshold, max: max,
                  boundaries: [0.85, 0.89, 0.94, 1.0].map { $0 * threshold })
    }

    public var zoneCount: Int { boundaries.count + 1 }

    /// 1-based zone for a heart rate.
    public func zone(for bpm: Double) -> Int {
        (boundaries.firstIndex { bpm < $0 } ?? boundaries.count) + 1
    }
}

public struct RunPlan: Sendable {
    public var distanceMeters: Double
    public var targetTime: TimeInterval
    public var pacing: PacingStrategy
    public var course: Course?
    public var heartRateZones: HeartRateZones?
    /// Fuel reminder interval in seconds, if any.
    public var fuelEvery: TimeInterval?

    /// Piecewise-constant pace: each segment runs up to `end` metres at `pace` s/m.
    private let segments: [(end: Double, pace: Double)]

    public init(distanceMeters: Double,
                targetTime: TimeInterval,
                pacing: PacingStrategy = .even,
                course: Course? = nil,
                heartRateZones: HeartRateZones? = nil,
                fuelEvery: TimeInterval? = nil) {
        precondition(distanceMeters > 0 && targetTime > 0, "plan needs a distance and a time")
        self.distanceMeters = distanceMeters
        self.targetTime = targetTime
        self.pacing = pacing
        self.course = course
        self.heartRateZones = heartRateZones
        self.fuelEvery = fuelEvery
        self.segments = RunPlan.segments(distance: distanceMeters, time: targetTime, pacing: pacing)
    }

    private static func segments(distance d: Double, time t: Double, pacing: PacingStrategy) -> [(end: Double, pace: Double)] {
        switch pacing {
        case .even:
            return [(d, t / d)]
        case .negativeSplit(let percent):
            // Half the distance at p1, half at p2 = p1·(1 − f); d/2·(p1 + p2) = t.
            let f = Swift.min(Swift.max(percent / 100, -0.99), 0.99)
            let p1 = 2 * t / (d * (2 - f))
            return [(d / 2, p1), (d, p1 * (1 - f))]
        case .perSplit(let raw):
            let splits = raw.filter { $0 > 0 }
            let sum = splits.reduce(0, +)
            guard !splits.isEmpty, sum > 0 else { return [(d, t / d)] }
            let len = d / Double(splits.count)
            return splits.enumerated().map { i, s in
                let end = i == splits.count - 1 ? d : len * Double(i + 1)
                return (end, (s / sum) * t / len)
            }
        }
    }

    /// Where the plan says you should be, in seconds, at a distance.
    /// Exactly `targetTime` at the finish.
    public func planTime(at distance: Double) -> TimeInterval {
        if distance <= 0 { return 0 }
        if distance >= distanceMeters { return targetTime }
        if segments.count == 1 { return targetTime * (distance / distanceMeters) }
        var time = 0.0
        var start = 0.0
        for seg in segments {
            if distance <= seg.end {
                return time + (distance - start) * seg.pace
            }
            time += (seg.end - start) * seg.pace
            start = seg.end
        }
        return targetTime
    }

    /// Target pace in seconds per metre at a distance.
    public func targetPace(at distance: Double) -> Double {
        let d = Swift.min(Swift.max(distance, 0), distanceMeters)
        return (segments.first { d < $0.end } ?? segments[segments.count - 1]).pace
    }

    /// Target pace in seconds per mile or kilometre at a distance.
    public func targetPace(at distance: Double, per unit: DistanceUnit) -> Double {
        targetPace(at: distance) * unit.meters
    }

    public func targetSecondsPerMile(at distance: Double) -> Double {
        targetPace(at: distance, per: .miles)
    }

    public func targetSecondsPerKilometer(at distance: Double) -> Double {
        targetPace(at: distance, per: .kilometers)
    }
}

// Codable/Equatable over the inputs only; the pace segments are derived from them.
extension RunPlan: Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case distanceMeters, targetTime, pacing, course, heartRateZones, fuelEvery
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let distance = try c.decode(Double.self, forKey: .distanceMeters)
        let time = try c.decode(TimeInterval.self, forKey: .targetTime)
        guard distance > 0, time > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .distanceMeters, in: c,
                                                   debugDescription: "plan needs a distance and a time")
        }
        self.init(distanceMeters: distance,
                  targetTime: time,
                  pacing: try c.decode(PacingStrategy.self, forKey: .pacing),
                  course: try c.decodeIfPresent(Course.self, forKey: .course),
                  heartRateZones: try c.decodeIfPresent(HeartRateZones.self, forKey: .heartRateZones),
                  fuelEvery: try c.decodeIfPresent(TimeInterval.self, forKey: .fuelEvery))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(distanceMeters, forKey: .distanceMeters)
        try c.encode(targetTime, forKey: .targetTime)
        try c.encode(pacing, forKey: .pacing)
        try c.encodeIfPresent(course, forKey: .course)
        try c.encodeIfPresent(heartRateZones, forKey: .heartRateZones)
        try c.encodeIfPresent(fuelEvery, forKey: .fuelEvery)
    }

    public static func == (a: RunPlan, b: RunPlan) -> Bool {
        a.distanceMeters == b.distanceMeters && a.targetTime == b.targetTime && a.pacing == b.pacing
            && a.course == b.course && a.heartRateZones == b.heartRateZones && a.fuelEvery == b.fuelEvery
    }
}
