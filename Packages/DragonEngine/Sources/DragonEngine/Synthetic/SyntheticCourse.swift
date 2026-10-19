//  SyntheticCourse.swift
//  Built-in courses for synthetic runs, so profiles don't need GPX files:
//  a straight or gently curving line with an elevation profile made of hills.
//  Points every 10 m; Course smooths the elevation like it does for GPX.

import Foundation

public struct SyntheticHill: Sendable, Equatable, Codable {
    /// Metres along the course where the climb starts.
    public var start: Double
    /// Metres of climbing.
    public var length: Double
    /// Metres gained.
    public var gain: Double
    /// Metres of descent back to the base after the top; nil stays up.
    public var descent: Double?

    public init(start: Double, length: Double, gain: Double, descent: Double? = nil) {
        self.start = start
        self.length = length
        self.gain = gain
        self.descent = descent
    }

    /// Height above the base at a distance: a steady climb, then a steady descent.
    func height(at d: Double) -> Double {
        let top = start + length
        if d <= start { return 0 }
        if d < top { return gain * (d - start) / length }
        guard let descent, descent > 0 else { return gain }
        return gain * max(0, 1 - (d - top) / descent)
    }
}

extension Course {
    public static let syntheticStart = (latitude: 37.7694, longitude: -122.4862)
    private static let syntheticSpacing = 10.0

    /// A synthetic course `length` metres long.
    /// - curving: heading swings ±`curving` degrees over a 3 km wavelength (0 = straight line, due east).
    /// - hills: added on top of `baseElevation`.
    public static func synthetic(length: Double,
                                 hills: [SyntheticHill] = [],
                                 curving: Double = 20,
                                 baseElevation: Double = 15,
                                 start: (latitude: Double, longitude: Double) = Course.syntheticStart) -> Course {
        let spacing = syntheticSpacing
        let steps = Int((length / spacing).rounded(.up))
        var lat = start.latitude, lon = start.longitude
        var track: [TrackPoint] = []
        track.reserveCapacity(steps + 1)

        func elevation(_ d: Double) -> Double {
            baseElevation + hills.reduce(0) { $0 + $1.height(at: d) }
        }

        track.append(TrackPoint(latitude: lat, longitude: lon, elevation: elevation(0)))
        for i in 0..<steps {
            let d0 = Double(i) * spacing
            let step = min(spacing, length - d0)
            let mid = d0 + step / 2
            let heading = (90 + curving * sin(2 * .pi * mid / 3000)) * .pi / 180
            let east = step * sin(heading), north = step * cos(heading)
            let midLat = (lat + north / earthRadius * 90 / .pi) * .pi / 180
            lat += north / earthRadius * 180 / .pi
            lon += east / (earthRadius * cos(midLat)) * 180 / .pi
            track.append(TrackPoint(latitude: lat, longitude: lon, elevation: elevation(d0 + step)))
        }
        return Course(track: track)
    }
}
