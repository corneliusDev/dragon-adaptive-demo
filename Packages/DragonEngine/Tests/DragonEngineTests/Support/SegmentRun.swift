//  SegmentRun.swift
//  Test support: a hand-scripted run made of segments (so many seconds at
//  such a flat-equivalent speed and effort) along a straight synthetic course,
//  fed to a StateEstimator as clean 1 Hz GPS with Doppler speed and 10 Hz
//  Watch motion. On a hill the runner slows by GradeModel, as a real runner
//  holding effort would. One state per second.
//
//      let run = segmentRun([.init(seconds: 180, speed: 3.5, effort: 75)])
//      run.rows.map(\.state.phase)

import Foundation
import DragonEngine

struct Segment {
    var seconds: Int
    /// Flat-equivalent m/s; on a grade the runner goes speed ÷ GradeModel factor.
    var speed: Double
    /// Motion effort, 0–100.
    var effort: Double
}

struct SegmentRun {
    struct Row {
        let t: TimeInterval
        /// Metres really covered.
        let distance: Double
        let state: RunState
    }

    let plan: RunPlan
    let rows: [Row]

    /// Rows with run time in [from, to).
    func rows(from: TimeInterval, to: TimeInterval) -> [Row] {
        rows.filter { $0.t >= from && $0.t < to }
    }
}

/// Runs the segments back to back on a `length` m straight course with `hills`.
/// Stops at the finish line if it comes first.
func segmentRun(_ segments: [Segment], length: Double = 10_000, hills: [SyntheticHill] = []) -> SegmentRun {
    let course = Course.synthetic(length: length, hills: hills, curving: 0)
    let plan = RunPlan(distanceMeters: length, targetTime: length / 3.5, course: course)
    var estimator = StateEstimator(plan: plan)
    var rows: [SegmentRun.Row] = []
    var d = 0.0, t = 0.0
    func grade(_ d: Double) -> Double {
        guard let up = course.elevation(at: d + 10), let down = course.elevation(at: d - 10) else { return 0 }
        return (up - down) / 20
    }
    func fix(_ v: Double) {
        let p = course.position(at: d)
        estimator.ingest(LocationSample(t: t, latitude: p.latitude, longitude: p.longitude, horizontalAccuracy: 4,
                                        speed: v, altitude: course.elevation(at: d)))
    }
    fix(segments.first.map { $0.speed } ?? 0)
    outer: for seg in segments {
        for _ in 0..<seg.seconds {
            let v = seg.speed / GradeModel.paceFactor(grade: grade(d))
            for k in 1...10 {
                d = min(length, d + v / 10)
                estimator.ingest(VitalsSample(timestamp: t + Double(k) / 10, heartRate: nil, motion: seg.effort,
                                              source: .watch))
            }
            t += 1
            fix(v)
            rows.append(.init(t: t, distance: d, state: estimator.state(at: t)))
            if d >= length { break outer }
        }
    }
    return SegmentRun(plan: plan, rows: rows)
}
