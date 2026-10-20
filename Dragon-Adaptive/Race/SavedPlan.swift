//  SavedPlan.swift
//  A race plan as the runner set it up on the phone: what DragonEngine's
//  RunPlan needs (distance, target, pacing, course, heart rate zones, fuel)
//  plus what only the app cares about (name, unit, display setting, the
//  course file's name). Codable, kept by PlanStore and reused across runs.

import Foundation
import DragonEngine

/// The distance presets on the plan screen, plus custom.
enum RaceDistance: String, Codable, CaseIterable, Identifiable {
    case fiveK, tenK, half, marathon, custom

    var id: String { rawValue }

    /// Metres; nil for custom.
    var meters: Double? {
        switch self {
        case .fiveK: return 5_000
        case .tenK: return 10_000
        case .half: return 21_097.5
        case .marathon: return 42_195
        case .custom: return nil
        }
    }

    var label: String {
        switch self {
        case .fiveK: return "5K"
        case .tenK: return "10K"
        case .half: return "Half"
        case .marathon: return "Marathon"
        case .custom: return "Custom"
        }
    }
}

/// Heart rate numbers as typed (chunk 12 reads them from Apple Health).
struct ZoneInputs: Codable, Equatable {
    var resting: Double
    var threshold: Double
    var max: Double

    /// Five zones by heart rate reserve, like the design's runner.
    var zones: HeartRateZones { .reserve(resting: resting, threshold: threshold, max: max) }
}

struct SavedPlan: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var preset: RaceDistance
    var distanceMeters: Double
    /// Miles or kilometres, for the plan screen, splits and the glasses.
    var unit: DistanceUnit
    var targetTime: TimeInterval
    var pacing: PacingStrategy
    var course: Course?
    /// The imported file's name ("city-half.gpx"); nil with no course.
    var courseFileName: String?
    var zones: ZoneInputs?
    /// Seconds between fuel reminders; nil for none.
    var fuelEvery: TimeInterval?
    var display: DisplaySetting
    /// App clock, for sorting the list; never handed to the engine.
    var updatedAt = Date()

    /// The engine's plan.
    var runPlan: RunPlan {
        RunPlan(distanceMeters: distanceMeters, targetTime: targetTime, pacing: pacing, course: course,
                heartRateZones: zones?.zones, fuelEvery: fuelEvery)
    }

    /// Average target pace, seconds per mile or kilometre.
    var averagePace: TimeInterval { targetTime / distanceMeters * unit.meters }

    /// "13.1 mi · 1:45:00 · 8:01 /mi"
    var summary: String {
        "\(RaceFormat.distance(distanceMeters, unit: unit)) · \(RaceFormat.clock(targetTime)) · "
            + "\(RaceFormat.paceValue(perUnit: averagePace)) \(RaceFormat.suffix(unit))"
    }
}

/// Plans saved as one JSON file (plans.json) in a folder; newest first.
struct PlanStore {
    let directory: URL
    private var file: URL { directory.appendingPathComponent("plans.json") }

    func load() -> [SavedPlan] {
        guard let data = try? Data(contentsOf: file),
              let plans = try? JSONDecoder().decode([SavedPlan].self, from: data) else { return [] }
        return plans.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Adds the plan, or replaces the one with its id.
    func save(_ plan: SavedPlan) throws {
        var plans = load()
        if let i = plans.firstIndex(where: { $0.id == plan.id }) {
            plans[i] = plan
        } else {
            plans.append(plan)
        }
        try write(plans)
    }

    func delete(_ id: UUID) throws {
        try write(load().filter { $0.id != id })
    }

    func plan(_ id: UUID) -> SavedPlan? { load().first { $0.id == id } }

    private func write(_ plans: [SavedPlan]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(plans).write(to: file, options: .atomic)
    }
}
