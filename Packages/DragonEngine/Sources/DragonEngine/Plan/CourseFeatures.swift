//  CourseFeatures.swift
//  What a runner cares about on a course: distance markers, hills, sharp turns
//  and aid stations, each placed by distance along the route (metres).

import Foundation

public struct CourseMarker: Sendable, Equatable {
    /// 1 for the first mile/kilometre, and so on.
    public var number: Int
    public var distance: Double
    public var unit: DistanceUnit
}

public struct Hill: Sendable, Equatable {
    public var startDistance: Double
    public var endDistance: Double
    /// Metres climbed from start to end.
    public var gain: Double

    public init(startDistance: Double, endDistance: Double, gain: Double) {
        self.startDistance = startDistance
        self.endDistance = endDistance
        self.gain = gain
    }

    public var length: Double { endDistance - startDistance }
    public var averageGrade: Double { length > 0 ? gain / length : 0 }
}

public struct Turn: Sendable, Equatable {
    public var distance: Double
    /// Heading change in degrees; positive = right, negative = left.
    public var angle: Double

    public init(distance: Double, angle: Double) {
        self.distance = distance
        self.angle = angle
    }
}

public struct AidStation: Sendable, Equatable {
    public var name: String
    public var distance: Double
    /// Metres from the waypoint to the route.
    public var offset: Double
}

extension Course {
    // Detection tuning
    public static let hillMinGrade = 0.03
    public static let hillMinLength = 200.0
    public static let turnMinAngle = 60.0
    /// A turn is a heading change across this much route (half before, half after).
    public static let turnWindow = 30.0
    /// Waypoints further than this from the route aren't aid stations.
    public static let aidStationMaxOffset = 100.0

    private static let profileStep = 10.0
    private static let turnStep = 5.0
    /// Length of route used to read the heading at each end of the turn window.
    private static let turnChord = 10.0

    /// A marker at every whole mile or kilometre along the course.
    public func markers(every unit: DistanceUnit) -> [CourseMarker] {
        let count = Int((totalDistance / unit.meters).rounded(.down))
        guard count > 0 else { return [] }
        return (1...count).map { CourseMarker(number: $0, distance: Double($0) * unit.meters, unit: unit) }
    }

    /// Climbs of at least 3% sustained over at least 200 m, from the smoothed
    /// elevation sampled every 10 m. Empty without elevation data.
    public func hills() -> [Hill] {
        guard hasElevation, totalDistance > Course.profileStep else { return [] }
        let step = Course.profileStep
        let n = Int((totalDistance / step).rounded(.down))
        let samples = (0...n).map { elevation(at: Double($0) * step)! }

        var hills: [Hill] = []
        var runStart: Int?
        func close(at end: Int) {
            guard let s = runStart else { return }
            let start = Double(s) * step, finish = Double(end) * step
            if finish - start >= Course.hillMinLength {
                hills.append(Hill(startDistance: start, endDistance: finish, gain: samples[end] - samples[s]))
            }
            runStart = nil
        }
        for i in 0..<n {
            let grade = (samples[i + 1] - samples[i]) / step
            if grade >= Course.hillMinGrade {
                if runStart == nil { runStart = i }
            } else {
                close(at: i)
            }
        }
        close(at: n)
        return hills
    }

    /// Heading changes of at least 60° within 30 m of route, one per turn,
    /// placed where the change peaks.
    public func turns() -> [Turn] {
        let half = Course.turnWindow / 2
        guard totalDistance > Course.turnWindow else { return [] }

        var turns: [Turn] = []
        var peak: Turn?
        var d = half
        while d <= totalDistance - half {
            // Heading over the first and last 10 m of the window around d.
            let into = Course.bearing(from: position(at: d - half), to: position(at: d - half + Course.turnChord))
            let out = Course.bearing(from: position(at: d + half - Course.turnChord), to: position(at: d + half))
            var change = out - into
            if change > 180 { change -= 360 }
            if change < -180 { change += 360 }

            if abs(change) >= Course.turnMinAngle {
                if peak == nil || abs(change) > abs(peak!.angle) { peak = Turn(distance: d, angle: change) }
            } else if let p = peak {
                turns.append(p)
                peak = nil
            }
            d += Course.turnStep
        }
        if let p = peak { turns.append(p) }
        return turns
    }

    /// Waypoints projected onto the nearest point of the whole route, sorted
    /// by distance. Waypoints more than 100 m from the route are skipped.
    public func aidStations() -> [AidStation] {
        waypoints.compactMap { w in
            let loc = locate(latitude: w.latitude, longitude: w.longitude)
            guard loc.offset <= Course.aidStationMaxOffset else { return nil }
            return AidStation(name: w.name, distance: loc.distance, offset: loc.offset)
        }
        .sorted { $0.distance < $1.distance }
    }
}
