//  SampleData.swift
//  Sample plans and a finished run for SwiftUI previews and tests: the
//  design's City Half Marathon plan, and a short synthetic race run through
//  the live run model into a throwaway store.

import Foundation
import DragonEngine

enum SampleData {
    /// The design's plan: 13.1 mi in 1:45:00, even, with its course, zones and gels.
    static var halfMarathon: SavedPlan {
        SavedPlan(name: "City Half Marathon", preset: .half, distanceMeters: SyntheticProfile.halfMarathon,
                  unit: .miles, targetTime: 6_300, pacing: .even,
                  course: SyntheticProfile.designWalkthrough.course(length: SyntheticProfile.halfMarathon),
                  courseFileName: "city-half.gpx",
                  zones: ZoneInputs(resting: 52, threshold: 172, max: 188),
                  fuelEvery: 45 * 60, display: .balanced)
    }

    /// A 5K in 25:00 on the synthetic course.
    static var parkFiveK: SavedPlan {
        SavedPlan(name: "Park 5K", preset: .fiveK, distanceMeters: 5_000, unit: .kilometers, targetTime: 1_500,
                  pacing: .negativeSplit(percent: 2), course: nil, courseFileName: nil, zones: nil,
                  fuelEvery: nil, display: .coach)
    }

    /// A live run `seconds` into the sample half marathon (not started when 0).
    static func liveRun(seconds: TimeInterval = 600, plan: SavedPlan = halfMarathon) -> LiveRunModel {
        let model = LiveRunModel(plan: plan)
        guard seconds > 0 else { return model }
        model.start(timer: false)
        model.speed = 10
        model.advance(realSeconds: seconds / 10)
        model.pause()
        return model
    }

    /// A finished `plan` race (5K by default), ended and saved in `environment`.
    static func finishedRun(plan: SavedPlan = parkFiveK, in environment: AppEnvironment = .temporary()) -> RunRecord? {
        let model = LiveRunModel(plan: plan)
        model.start(timer: false)
        model.speed = 10
        while !model.isFinished && model.raceTime < plan.targetTime * 2 {
            model.advance(realSeconds: 6)
        }
        return try? model.end(store: environment.runs)
    }

    /// A review of a finished sample race.
    static func review(plan: SavedPlan = parkFiveK) -> ReviewModel? {
        let env = AppEnvironment.temporary()
        guard let record = finishedRun(plan: plan, in: env) else { return nil }
        return try? ReviewModel(record: record, store: env.runs)
    }
}
