//  RaceFormat.swift
//  Engine values (metres, seconds, seconds per metre) as the phone screens
//  show them, in miles or kilometres, and the reverse for what the runner
//  types ("1:45:00", "8:01"). UI-side only: the engine never formats.

import Foundation
import DragonEngine

enum RaceFormat {
    // MARK: Times

    /// 1:44:29, or 25:00 under an hour; rounded down to the second.
    static func clock(_ seconds: TimeInterval) -> String {
        RunStateFormat.clock(max(0, seconds))
    }

    /// Signed difference, rounded to the second: +0:48 behind, -0:31 ahead,
    /// +1:02:03 over an hour.
    static func gap(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let sign = total < 0 ? "-" : "+"
        let a = abs(total)
        return a >= 3600
            ? String(format: "%@%d:%02d:%02d", sign, a / 3600, a / 60 % 60, a % 60)
            : String(format: "%@%d:%02d", sign, a / 60, a % 60)
    }

    /// "1:45:00", "45:00" or "25" (seconds) back to seconds; h:mm:ss or m:ss.
    /// nil for anything else (empty, letters, minutes or seconds over 59).
    static func parseDuration(_ text: String) -> TimeInterval? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var values: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy(\.isNumber), let v = Int(p) else { return nil }
            values.append(v)
        }
        // Every field after the first is a sexagesimal one.
        guard values.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        return TimeInterval(values.reduce(0) { $0 * 60 + $1 })
    }

    // MARK: Paces

    /// Seconds per metre as "8:01 /mi" or "4:59 /km"; "—" when unknown.
    static func pace(_ secondsPerMeter: Double?, unit: DistanceUnit) -> String {
        let value = RunStateFormat.pace(secondsPerMeter, unit: unit)
        return value == "—" ? value : "\(value) \(suffix(unit))"
    }

    /// Seconds per mile or kilometre as "8:01".
    static func paceValue(perUnit seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func suffix(_ unit: DistanceUnit) -> String { unit == .miles ? "/mi" : "/km" }

    // MARK: Distances

    static func unitName(_ unit: DistanceUnit) -> String { unit == .miles ? "mi" : "km" }

    /// A race distance: "13.1 mi", "21.1 km", "5 km", "3.1 mi". One decimal,
    /// dropped when it is a whole number.
    static func distance(_ meters: Double, unit: DistanceUnit) -> String {
        "\(number(meters / unit.meters)) \(unitName(unit))"
    }

    /// Distance covered, for the live screen: "10.50".
    static func distanceValue(_ meters: Double, unit: DistanceUnit) -> String {
        String(format: "%.2f", max(0, meters) / unit.meters)
    }

    /// Where along the race: "5.6" (one decimal, in the unit).
    static func marker(_ meters: Double, unit: DistanceUnit) -> String {
        String(format: "%.1f", max(0, meters) / unit.meters)
    }

    /// One decimal, without a trailing ".0".
    static func number(_ x: Double) -> String {
        let r = (x * 10).rounded() / 10
        return r == r.rounded() ? String(format: "%.0f", r) : String(format: "%.1f", r)
    }

    /// Metres climbed as "+118 ft" (miles) or "+36 m" (kilometres).
    static func climb(_ meters: Double, unit: DistanceUnit) -> String {
        unit == .miles ? String(format: "+%.0f ft", meters / 0.3048) : String(format: "+%.0f m", meters)
    }

    // MARK: Results

    /// "Target 1:45:00 · beat it by 0:31", "… missed it by 0:12", "… right on it".
    static func result(finish: TimeInterval, target: TimeInterval) -> String {
        let diff = Int((finish - target).rounded())
        let verdict: String
        if diff < 0 {
            verdict = "beat it by \(clock(TimeInterval(-diff)))"
        } else if diff > 0 {
            verdict = "missed it by \(clock(TimeInterval(diff)))"
        } else {
            verdict = "right on it"
        }
        return "Target \(clock(target)) · \(verdict)"
    }

    // MARK: Cues

    /// A cue in plain words: "Mile 3 split", "Behind plan", "Hill ahead", "Fuel".
    static func cueTitle(_ key: CueKey, content: CueContent? = nil) -> String {
        switch key {
        case .split(let n, let unit): return "\(unit == .miles ? "Mile" : "Km") \(n) split"
        case .paceGap:
            if case .label(let words)? = content?.heading, words.hasPrefix("AHEAD") { return "Ahead of plan" }
            return "Behind plan"
        case .status: return "Status"
        case .detail: return "Split table"
        case .target: return "Target"
        case .heartCeiling: return "Heart rate"
        case .terrain: return content?.icon == .arrow ? "Turn ahead" : "Hill ahead"
        case .fuel: return "Fuel"
        case .formFade: return "Form fade"
        case .kickClock: return "Kick clock"
        case .finish: return "Finish"
        case .scripted(let id): return id.capitalized
        }
    }

    /// What the runner did about a cue that showed, in words.
    static func response(_ r: CueResponse?) -> String {
        switch r {
        case .glanced?: return "seen"
        case .heldLook?: return "looked closer"
        case .ignored?: return "not looked at"
        case .dismissed?: return "dismissed"
        case nil: return "up at the end"
        }
    }

    /// Whether a cue helped, short: "pace +4.7% → +3.1%, better", "HR 176 → 171, better".
    static func outcome(_ o: CueOutcome) -> String {
        func value(_ v: Double?) -> String {
            guard let v else { return "—" }
            return o.measure == .paceOffset ? String(format: "%+.1f%%", v * 100) : "\(Int(v.rounded()))"
        }
        let name = o.measure == .paceOffset ? "pace" : "HR"
        guard o.after != nil else { return "\(name) \(value(o.atShow)), no reading after" }
        let verdict = o.improved.map { $0 ? "better" : "not better" } ?? "unknown"
        return "\(name) \(value(o.atShow)) → \(value(o.after)), \(verdict)"
    }

    /// "too much / just right / missed something"
    static func rating(_ r: CueRating) -> String {
        switch r {
        case .tooMuch: return "Too much"
        case .justRight: return "Just right"
        case .tooLittle: return "Missed something"
        }
    }
}
