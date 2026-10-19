//  Course.swift
//  A race route: track points with cumulative distance along the route
//  (haversine) and smoothed elevation, plus named waypoints. Elevation is
//  optional; a file without it loads with every point's elevation nil.
//  Geometry is done in a local flat (equirectangular) frame, which is well
//  under a metre off at the tens-of-metres scale it's used at.

import Foundation

public struct CoursePoint: Sendable, Equatable, Codable {
    public var latitude: Double
    public var longitude: Double
    /// Metres along the route from the first point.
    public var distance: Double
    /// Smoothed elevation in metres, nil when the file had none.
    public var elevation: Double?
}

public struct Waypoint: Sendable, Equatable, Codable {
    public var name: String
    public var latitude: Double
    public var longitude: Double

    public init(name: String, latitude: Double, longitude: Double) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// A raw point as read from a file, before distance and smoothing.
public struct TrackPoint: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var elevation: Double?

    public init(latitude: Double, longitude: Double, elevation: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.elevation = elevation
    }
}

/// Where a position falls on the course.
public struct CourseLocation: Sendable, Equatable {
    /// Metres along the route of the nearest point on it.
    public var distance: Double
    /// Metres from the position to the route.
    public var offset: Double
    public var offCourse: Bool
}

/// Codable as its processed points (not the raw track), so a decoded course
/// is identical to the one that was encoded.
public struct Course: Sendable, Equatable, Codable {
    public static let earthRadius = 6_371_000.0
    /// Half-width of the distance window used to smooth elevation.
    public static let elevationSmoothingRadius = 25.0
    public static let offCourseThreshold = 50.0

    public let points: [CoursePoint]
    public let waypoints: [Waypoint]
    /// False when the source had no elevation at all.
    public let hasElevation: Bool

    public var totalDistance: Double { points.last?.distance ?? 0 }

    public init(track: [TrackPoint], waypoints: [Waypoint] = []) {
        // Cumulative haversine distance; drop consecutive duplicates.
        var kept: [TrackPoint] = []
        var dist: [Double] = []
        for p in track {
            if let last = kept.last {
                let step = Course.haversine(last.latitude, last.longitude, p.latitude, p.longitude)
                if step < 0.01 { continue }
                dist.append(dist[dist.count - 1] + step)
            } else {
                dist.append(0)
            }
            kept.append(p)
        }

        let elevations = Course.smoothedElevations(kept.map(\.elevation), distances: dist)
        self.points = kept.indices.map {
            CoursePoint(latitude: kept[$0].latitude, longitude: kept[$0].longitude,
                        distance: dist[$0], elevation: elevations?[$0])
        }
        self.waypoints = waypoints
        self.hasElevation = elevations != nil
    }

    // MARK: Elevation

    /// Fills gaps by interpolating along distance, then box-averages over
    /// ±smoothing radius. nil when no point had an elevation.
    private static func smoothedElevations(_ raw: [Double?], distances: [Double]) -> [Double]? {
        let known = raw.indices.compactMap { i in raw[i].map { (distances[i], $0) } }
        guard !known.isEmpty else { return nil }
        let filled = distances.map { d in interpolate(known, at: d) }

        let r = elevationSmoothingRadius
        var out = [Double](repeating: 0, count: filled.count)
        var lo = 0, hi = 0
        var sum = 0.0
        for i in filled.indices {
            while hi < filled.count && distances[hi] <= distances[i] + r { sum += filled[hi]; hi += 1 }
            while distances[lo] < distances[i] - r { sum -= filled[lo]; lo += 1 }
            out[i] = sum / Double(hi - lo)
        }
        return out
    }

    private static func interpolate(_ samples: [(Double, Double)], at d: Double) -> Double {
        if d <= samples[0].0 { return samples[0].1 }
        if d >= samples[samples.count - 1].0 { return samples[samples.count - 1].1 }
        let j = samples.firstIndex { $0.0 >= d }!
        let (d0, e0) = samples[j - 1], (d1, e1) = samples[j]
        return d1 > d0 ? e0 + (e1 - e0) * (d - d0) / (d1 - d0) : e1
    }

    // MARK: Sampling along the route

    /// Index of the segment (points[i] → points[i+1]) containing a distance.
    func segmentIndex(at distance: Double) -> Int {
        guard points.count > 1 else { return 0 }
        var lo = 0, hi = points.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if points[mid].distance <= distance { lo = mid } else { hi = mid }
        }
        return lo
    }

    /// Latitude/longitude at a distance along the route.
    public func position(at distance: Double) -> (latitude: Double, longitude: Double) {
        guard let first = points.first else { return (0, 0) }
        guard points.count > 1 else { return (first.latitude, first.longitude) }
        let d = min(max(distance, 0), totalDistance)
        let i = segmentIndex(at: d)
        let a = points[i], b = points[i + 1]
        let t = (d - a.distance) / (b.distance - a.distance)
        return (a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t)
    }

    /// Smoothed elevation at a distance, nil without elevation data.
    public func elevation(at distance: Double) -> Double? {
        guard hasElevation, let first = points.first else { return nil }
        guard points.count > 1 else { return first.elevation }
        let d = min(max(distance, 0), totalDistance)
        let i = segmentIndex(at: d)
        let a = points[i], b = points[i + 1]
        let t = (d - a.distance) / (b.distance - a.distance)
        return a.elevation! + (b.elevation! - a.elevation!) * t
    }

    // MARK: Locating a position

    /// Nearest point on the route to a position. With `lastDistance`, only
    /// segments from `behind` metres before it to `ahead` metres after it are
    /// searched, so a course that doubles back doesn't jump to the other leg.
    /// Without it, the whole course is searched.
    public func locate(latitude: Double, longitude: Double, near lastDistance: Double? = nil,
                       behind: Double = 100, ahead: Double = 500) -> CourseLocation {
        guard let first = points.first else { return CourseLocation(distance: 0, offset: 0, offCourse: true) }
        guard points.count > 1 else {
            let off = Course.haversine(latitude, longitude, first.latitude, first.longitude)
            return CourseLocation(distance: 0, offset: off, offCourse: off > Course.offCourseThreshold)
        }

        var range = 0..<(points.count - 1)
        if let last = lastDistance {
            let lo = segmentIndex(at: last - behind)
            let hi = segmentIndex(at: last + ahead)
            range = lo..<(hi + 1)
        }

        // Where legs overlap (out-and-back, turnarounds), prefer the candidate
        // nearer the last known distance, and forward progress over going back:
        // a small cost per metre moved along the route, larger when backwards.
        let forwardCost = 0.02, backwardCost = 0.2
        var best = (score: Double.infinity, distance: 0.0, offset: 0.0)
        for i in range {
            let (d, off) = project(latitude, longitude, onSegment: i)
            var score = off
            if let last = lastDistance {
                score += d >= last ? (d - last) * forwardCost : (last - d) * backwardCost
            }
            if score < best.score { best = (score, d, off) }
        }
        return CourseLocation(distance: best.distance, offset: best.offset,
                              offCourse: best.offset > Course.offCourseThreshold)
    }

    /// Projects a position onto segment i; returns (distance along route, metres off it).
    func project(_ lat: Double, _ lon: Double, onSegment i: Int) -> (Double, Double) {
        let a = points[i], b = points[i + 1]
        let (ax, ay) = Course.local(a.latitude, a.longitude, origin: (lat, lon))
        let (bx, by) = Course.local(b.latitude, b.longitude, origin: (lat, lon))
        let dx = bx - ax, dy = by - ay
        let len2 = dx * dx + dy * dy
        let t = len2 > 0 ? min(max(-(ax * dx + ay * dy) / len2, 0), 1) : 0
        let px = ax + dx * t, py = ay + dy * t
        return (a.distance + (b.distance - a.distance) * t, (px * px + py * py).squareRoot())
    }

    // MARK: Geometry helpers

    public static func haversine(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = p2 - p1, dl = (lon2 - lon1) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * earthRadius * asin(min(1, h.squareRoot()))
    }

    /// East/north metres of a position from an origin (equirectangular).
    static func local(_ lat: Double, _ lon: Double, origin: (Double, Double)) -> (Double, Double) {
        let x = (lon - origin.1) * .pi / 180 * cos(origin.0 * .pi / 180) * earthRadius
        let y = (lat - origin.0) * .pi / 180 * earthRadius
        return (x, y)
    }

    /// Compass bearing in degrees (0 = north, 90 = east) from one position to another.
    static func bearing(from a: (latitude: Double, longitude: Double), to b: (latitude: Double, longitude: Double)) -> Double {
        let (x, y) = local(b.latitude, b.longitude, origin: (a.latitude, a.longitude))
        let deg = atan2(x, y) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }
}
