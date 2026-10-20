//  PlanEditorModel.swift
//  The race plan screen's state: what the runner typed and picked, checked
//  and turned into a SavedPlan. Plain Swift (Observation), no SwiftUI, so
//  validation and the course import are unit-tested directly.
//
//  Text fields stay text until saved; `problems` says, in words, what stops
//  the plan from saving (an unparseable time, a pace no runner holds, zones
//  out of order, a course file shorter than the race).

import Foundation
import Observation
import DragonEngine

/// Limits the plan screen checks against. Defaults follow the plan's spec.
struct PlanLimits: Equatable {
    /// Average target pace faster than this (seconds per mile) is rejected: 3:00 /mi.
    var fastestPacePerMile: TimeInterval = 180
    /// Average target pace slower than this (seconds per mile) is rejected: 20:00 /mi.
    var slowestPacePerMile: TimeInterval = 1_200
    /// Negative split percentages allowed.
    var negativeSplitPercent: ClosedRange<Double> = 0.5...10
    /// Heart rates (bpm) accepted for resting, threshold and max.
    var heartRate: ClosedRange<Double> = 30...230
    /// Minutes between fuel reminders.
    var fuelMinutes: ClosedRange<Double> = 10...120
    /// A course file may be this much shorter than the race (GPS tracks
    /// measure a little short) before the plan is rejected.
    var courseShortfall = 0.05
    /// Longest custom race, metres (a 100-miler).
    var longestRace = 161_000.0
}

enum PacingStyle: String, CaseIterable, Identifiable {
    case even, negative, perSplit
    var id: String { rawValue }

    var label: String {
        switch self {
        case .even: return "Even"
        case .negative: return "Negative"
        case .perSplit: return "By split"
        }
    }
}

@Observable
final class PlanEditorModel {
    let limits: PlanLimits
    /// The plan being edited (its id and course), or nil for a new one.
    private let original: SavedPlan?

    var name: String
    var preset: RaceDistance
    /// Custom distance in `unit`.
    var customDistance: String
    var unit: DistanceUnit
    var target: String
    var pacingStyle: PacingStyle
    var negativePercent: String
    /// One time per split, comma separated ("8:05, 8:00, 7:55"); relative, scaled to the target.
    var splitTimes: String
    var resting: String
    var threshold: String
    var maxHeartRate: String
    /// Minutes between gels; empty for none.
    var fuelMinutes: String
    var display: DisplaySetting

    private(set) var course: Course?
    private(set) var courseFileName: String?
    /// The course's hills and aid stations, found once at import.
    private var courseHills: [Hill] = []
    private var courseAidStations = 0
    /// A warning about the course that doesn't stop the plan (no elevation).
    private(set) var courseNotice: String?
    /// Why the last import failed.
    private(set) var importError: String?

    init(plan: SavedPlan? = nil, limits: PlanLimits = PlanLimits()) {
        self.limits = limits
        original = plan
        let p = plan
        name = p?.name ?? ""
        preset = p?.preset ?? .half
        unit = p?.unit ?? .miles
        customDistance = p.map { $0.preset == .custom ? RaceFormat.number($0.distanceMeters / $0.unit.meters) : "" } ?? ""
        target = p.map { RaceFormat.clock($0.targetTime) } ?? ""
        display = p?.display ?? .balanced
        resting = p?.zones.map { String(Int($0.resting)) } ?? ""
        threshold = p?.zones.map { String(Int($0.threshold)) } ?? ""
        maxHeartRate = p?.zones.map { String(Int($0.max)) } ?? ""
        fuelMinutes = p?.fuelEvery.map { RaceFormat.number($0 / 60) } ?? ""
        negativePercent = "2"
        splitTimes = ""
        switch p?.pacing {
        case .negativeSplit(let percent)?:
            pacingStyle = .negative
            negativePercent = RaceFormat.number(percent)
        case .perSplit(let times)?:
            pacingStyle = .perSplit
            splitTimes = times.map { RaceFormat.paceValue(perUnit: $0) }.joined(separator: ", ")
        default:
            pacingStyle = .even
        }
        if let course = p?.course {
            setCourse(course, fileName: p?.courseFileName ?? "course.gpx")
        }
    }

    var isNew: Bool { original == nil }
    /// The saved plan being edited; nil for a new one.
    var planID: UUID? { original?.id }

    // MARK: Parsed values

    /// Race distance in metres; nil when custom and not a number.
    var distanceMeters: Double? {
        if let m = preset.meters { return m }
        guard let v = Double(customDistance.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
              v > 0 else { return nil }
        return v * unit.meters
    }

    var targetTime: TimeInterval? {
        RaceFormat.parseDuration(target).flatMap { $0 > 0 ? $0 : nil }
    }

    /// Average pace, seconds per `unit`.
    var averagePace: TimeInterval? {
        guard let d = distanceMeters, let t = targetTime else { return nil }
        return t / d * unit.meters
    }

    var pacing: PacingStrategy? {
        switch pacingStyle {
        case .even:
            return .even
        case .negative:
            guard let p = Double(negativePercent.replacingOccurrences(of: ",", with: ".")),
                  limits.negativeSplitPercent.contains(p) else { return nil }
            return .negativeSplit(percent: p)
        case .perSplit:
            let times = splitTimes.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
                .map { RaceFormat.parseDuration(String($0)) }
            guard times.count >= 2, times.allSatisfy({ ($0 ?? 0) > 0 }) else { return nil }
            return .perSplit(times.compactMap { $0 })
        }
    }

    var zones: ZoneInputs? {
        guard let r = Double(resting), let t = Double(threshold), let m = Double(maxHeartRate) else { return nil }
        return ZoneInputs(resting: r, threshold: t, max: m)
    }

    private var zonesEntered: Bool { !(resting + threshold + maxHeartRate).trimmingCharacters(in: .whitespaces).isEmpty }

    var fuelEvery: TimeInterval? {
        Double(fuelMinutes.replacingOccurrences(of: ",", with: ".")).map { $0 * 60 }
    }

    // MARK: Words for the screen

    /// "8:01 /mi average", "8:09 then 7:53 /mi", "16 splits, 8:01 /mi average".
    var pacingSummary: String? {
        guard let d = distanceMeters, let t = targetTime, let pacing else { return nil }
        let plan = RunPlan(distanceMeters: d, targetTime: t, pacing: pacing)
        let suffix = RaceFormat.suffix(unit)
        switch pacing {
        case .even:
            return "\(RaceFormat.paceValue(perUnit: t / d * unit.meters)) \(suffix) the whole way"
        case .negativeSplit:
            let first = plan.targetPace(at: 0, per: unit), second = plan.targetPace(at: d, per: unit)
            return "\(RaceFormat.paceValue(perUnit: first)) then \(RaceFormat.paceValue(perUnit: second)) \(suffix)"
        case .perSplit(let times):
            return "\(times.count) splits, \(RaceFormat.paceValue(perUnit: t / d * unit.meters)) \(suffix) average"
        }
    }

    // MARK: Validation

    /// Everything that stops the plan from saving, in words; empty when it can.
    var problems: [String] {
        var out: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { out.append("Give the race a name.") }
        if distanceMeters == nil {
            out.append("Enter the race distance in \(RaceFormat.unitName(unit)).")
        } else if let d = distanceMeters, d > limits.longestRace {
            out.append("That distance is longer than \(RaceFormat.distance(limits.longestRace, unit: unit)).")
        }
        if targetTime == nil { out.append("Enter a target time like 1:45:00 (h:mm:ss) or 25:00 (mm:ss).") }
        if let message = paceProblem { out.append(message) }
        if pacing == nil {
            switch pacingStyle {
            case .negative:
                out.append("Negative split: enter a percentage from \(RaceFormat.number(limits.negativeSplitPercent.lowerBound)) "
                           + "to \(RaceFormat.number(limits.negativeSplitPercent.upperBound)).")
            case .perSplit:
                out.append("By split: enter at least two split times like 8:05, 8:00, 7:55.")
            case .even:
                break
            }
        }
        if let message = zoneProblem { out.append(message) }
        if !fuelMinutes.trimmingCharacters(in: .whitespaces).isEmpty {
            if let f = fuelEvery, limits.fuelMinutes.contains(f / 60) {} else {
                out.append("Fuel: enter minutes between gels, \(Int(limits.fuelMinutes.lowerBound))–"
                           + "\(Int(limits.fuelMinutes.upperBound)), or leave it empty.")
            }
        }
        if let course, let d = distanceMeters, course.totalDistance < d * (1 - limits.courseShortfall) {
            out.append("The course file is \(RaceFormat.distance(course.totalDistance, unit: unit)), "
                       + "shorter than the race's \(RaceFormat.distance(d, unit: unit)).")
        }
        return out
    }

    var canSave: Bool { problems.isEmpty }

    /// Average target pace outside 3:00–20:00 /mi.
    var paceProblem: String? {
        guard let pace = averagePace else { return nil }
        let perMile = pace / unit.meters * DistanceUnit.metersPerMile
        let shown = "\(RaceFormat.paceValue(perUnit: pace)) \(RaceFormat.suffix(unit))"
        func limit(_ perMileLimit: TimeInterval) -> String {
            let mile = "\(RaceFormat.paceValue(perUnit: perMileLimit)) /mi"
            guard unit == .kilometers else { return mile }
            let km = perMileLimit / DistanceUnit.metersPerMile * DistanceUnit.metersPerKilometer
            return "\(mile) (\(RaceFormat.paceValue(perUnit: km)) /km)"
        }
        if perMile < limits.fastestPacePerMile - 0.5 {
            return "Target pace \(shown) is faster than \(limit(limits.fastestPacePerMile)). Check the distance and target time."
        }
        if perMile > limits.slowestPacePerMile + 0.5 {
            return "Target pace \(shown) is slower than \(limit(limits.slowestPacePerMile)). Check the distance and target time."
        }
        return nil
    }

    private var zoneProblem: String? {
        guard zonesEntered else { return nil }
        guard let z = zones else { return "Heart rate: enter resting, threshold and max, or leave all three empty." }
        guard [z.resting, z.threshold, z.max].allSatisfy(limits.heartRate.contains) else {
            return "Heart rate: values must be \(Int(limits.heartRate.lowerBound))–\(Int(limits.heartRate.upperBound)) bpm."
        }
        guard z.resting < z.threshold, z.threshold < z.max else {
            return "Heart rate: resting must be under threshold, and threshold under max."
        }
        return nil
    }

    // MARK: Course

    /// Reads a GPX file through DragonEngine's parser. On failure the course
    /// is left as it was and `importError` says why.
    func importGPX(_ data: Data, fileName: String) {
        do {
            setCourse(try GPXParser.parse(data), fileName: fileName)
            importError = nil
        } catch GPXError.noTrackPoints {
            importError = "\(fileName) has no track points."
        } catch {
            importError = "\(fileName) isn't a GPX file this app can read."
        }
    }

    /// Back to the built-in synthetic course.
    func removeCourse() {
        course = nil
        courseFileName = nil
        courseHills = []
        courseAidStations = 0
        courseNotice = nil
        importError = nil
    }

    /// Sets the race distance to the course's length (as a custom distance).
    func useCourseDistance() {
        guard let course else { return }
        preset = .custom
        customDistance = String(format: "%.2f", course.totalDistance / unit.meters)
    }

    private func setCourse(_ c: Course, fileName: String) {
        course = c
        courseFileName = fileName
        courseNotice = c.hasElevation ? nil : "No elevation in this course: hill warnings are off."
        courseHills = c.hills()
        courseAidStations = c.aidStations().count
    }

    /// What the import found, in the plan's unit: "13.1 mi · 1 hill at mi 7.4 (+125 ft) · 4 aid stations".
    var courseSummary: String? {
        course.map { Self.describe($0, hills: courseHills, aidStations: courseAidStations, unit: unit) }
    }

    static func describe(_ c: Course, hills: [Hill], aidStations aid: Int, unit: DistanceUnit) -> String {
        var parts = [RaceFormat.distance(c.totalDistance, unit: unit)]
        if let biggest = hills.max(by: { $0.gain < $1.gain }) {
            let at = "\(RaceFormat.unitName(unit)) \(RaceFormat.marker(biggest.startDistance, unit: unit))"
            parts.append(hills.count == 1
                ? "1 hill at \(at) (\(RaceFormat.climb(biggest.gain, unit: unit)))"
                : "\(hills.count) hills, biggest at \(at) (\(RaceFormat.climb(biggest.gain, unit: unit)))")
        } else if c.hasElevation {
            parts.append("no hills")
        }
        if aid > 0 { parts.append(aid == 1 ? "1 aid station" : "\(aid) aid stations") }
        return parts.joined(separator: " · ")
    }

    // MARK: Saving

    /// The plan, or nil while there are problems.
    func makePlan() -> SavedPlan? {
        guard canSave, let d = distanceMeters, let t = targetTime, let pacing else { return nil }
        return SavedPlan(id: original?.id ?? UUID(),
                         name: name.trimmingCharacters(in: .whitespaces),
                         preset: preset, distanceMeters: d, unit: unit, targetTime: t, pacing: pacing,
                         course: course, courseFileName: courseFileName,
                         zones: zonesEntered ? zones : nil,
                         fuelEvery: fuelMinutes.trimmingCharacters(in: .whitespaces).isEmpty ? nil : fuelEvery,
                         display: display)
    }

    /// Saves to the store; returns the saved plan, or nil while there are problems.
    @discardableResult
    func save(to store: PlanStore) throws -> SavedPlan? {
        guard let plan = makePlan() else { return nil }
        try store.save(plan)
        return plan
    }
}
