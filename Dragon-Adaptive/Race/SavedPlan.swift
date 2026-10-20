//  SavedPlan.swift
//  A race plan as the runner set it up on the phone: what DragonEngine's
//  RunPlan needs (distance, target, pacing, course, heart rate zones, fuel)
//  plus what only the app cares about (name, unit, display setting, the
//  course file's name, and how cues come onto the glasses: the segue and
//  heads-ups). Codable, kept by PlanStore and reused across runs. Plans
//  saved before the segue fields existed load with the defaults (Fade, Dot
//  pulse).

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
    /// How cues ease on and off the glasses on this race.
    var segue = Segue.default
    /// What warns of a predictable cue (empty: off).
    var headsUp = HeadsUpKind.defaultSetting

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

extension SavedPlan {
    private enum CodingKeys: String, CodingKey {
        case id, name, preset, distanceMeters, unit, targetTime, pacing, course, courseFileName, zones, fuelEvery,
             display, updatedAt, segue, headsUp
    }

    /// Decodes every field; the segue and heads-ups default when the plan
    /// was saved before they existed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        preset = try c.decode(RaceDistance.self, forKey: .preset)
        distanceMeters = try c.decode(Double.self, forKey: .distanceMeters)
        unit = try c.decode(DistanceUnit.self, forKey: .unit)
        targetTime = try c.decode(TimeInterval.self, forKey: .targetTime)
        pacing = try c.decode(PacingStrategy.self, forKey: .pacing)
        course = try c.decodeIfPresent(Course.self, forKey: .course)
        courseFileName = try c.decodeIfPresent(String.self, forKey: .courseFileName)
        zones = try c.decodeIfPresent(ZoneInputs.self, forKey: .zones)
        fuelEvery = try c.decodeIfPresent(TimeInterval.self, forKey: .fuelEvery)
        display = try c.decode(DisplaySetting.self, forKey: .display)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        segue = try c.decodeIfPresent(Segue.self, forKey: .segue) ?? .default
        headsUp = try c.decodeIfPresent(Set<HeadsUpKind>.self, forKey: .headsUp) ?? HeadsUpKind.defaultSetting
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
