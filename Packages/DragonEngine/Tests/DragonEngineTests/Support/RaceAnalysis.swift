//  RaceAnalysis.swift
//  Reading a race back out of its GPS, the way the engine will have to:
//  locate each fix on the course, then fit distance against time locally to
//  find when each mile was crossed.

import Foundation
import DragonEngine

/// (run time, metres along the course) for each usable fix.
func trackedDistances(_ recording: RunRecording, maxAccuracy: Double = 20) -> [(t: TimeInterval, d: Double)] {
    guard let course = recording.plan?.course else { return [] }
    var last: Double?
    var out: [(TimeInterval, Double)] = []
    for fix in recording.locations where fix.horizontalAccuracy <= maxAccuracy {
        let loc = course.locate(latitude: fix.latitude, longitude: fix.longitude, near: last)
        last = loc.distance
        out.append((fix.t, loc.distance))
    }
    return out
}

/// Run time each `every`-metre mark was crossed, from a least-squares line
/// through the ±10 fixes around it.
func crossingTimes(_ recording: RunRecording, every: Double = DistanceUnit.metersPerMile) -> [TimeInterval] {
    let track = trackedDistances(recording)
    guard let end = track.last?.d else { return [] }
    var out: [TimeInterval] = []
    var mark = every
    while mark < end {
        guard let i = track.firstIndex(where: { $0.d >= mark }) else { break }
        let window = track[max(0, i - 10)..<min(track.count, i + 10)]
        let n = Double(window.count)
        let mt = window.map(\.t).reduce(0, +) / n, md = window.map(\.d).reduce(0, +) / n
        let slope = window.map { ($0.t - mt) * ($0.d - md) }.reduce(0, +) / window.map { ($0.t - mt) * ($0.t - mt) }.reduce(0, +)
        out.append(mt + (mark - md) / slope)
        mark += every
    }
    return out
}

/// Seconds for each split between consecutive crossings (the first from t = 0).
func splits(_ crossings: [TimeInterval]) -> [TimeInterval] {
    zip([0] + crossings, crossings).map { $1 - $0 }
}
