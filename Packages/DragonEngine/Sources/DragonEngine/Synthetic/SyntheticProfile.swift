//  SyntheticProfile.swift
//  What kind of race a SyntheticRun simulates: which course, how the runner's
//  pace departs from the plan, and anything that makes the same pace cost more
//  (heat, fatigue). The run turns pace + grade into effort, so every profile
//  shows up consistently in GPS, heart rate and motion.

import Foundation

public enum SyntheticProfile: Sendable, Equatable, Codable {
    /// Runs the plan, give or take normal pace wobble.
    case onPlan
    /// On plan until `from` metres, then slows (and works harder doing it).
    case slowFade(from: Double)
    /// Hot day: heart rate drifts up at the same pace, and pace eases off.
    case tooHot
    /// A course with several hills; slower and harder on the climbs.
    case hilly
    /// On plan, but GPS sends nothing for `for` seconds once the runner reaches `at` metres.
    case gpsDropout(at: Double, for: TimeInterval)
    /// The design doc's race: a 1:45:00 half at 8:01/mi even. A slow first mile
    /// in the crowd, then banking time, a +38 m (125 ft) climb from mile 7.43
    /// to 8.05, a push after it with heart rate into zone 5 around mile 9.3, a
    /// sharp fade to mile 10.5 that puts the projection behind the target, a
    /// partial recovery and a kick in the last 0.25 mi. Finishes around 1:44:29.
    /// The runner glances before the gun and at mile 4.2, holds a look at mile
    /// 11.2, and takes a gel every 45 minutes. See `walkthroughPace`.
    case designWalkthrough
    /// slowFade that recovers: on plan until `from`, 5% slow until `recoverAt`,
    /// then 2% quick for 2.5× the fade's length (making the time back), then on
    /// plan again. Not in `all`; the pace-gap trigger tests use it to see a cue clear.
    case slowFadeRecovery(from: Double, recoverAt: Double)

    public static let halfMarathon = 21_097.5

    /// One of each, with typical parameters (for pickers and tests).
    public static let all: [SyntheticProfile] = [
        .onPlan,
        .slowFade(from: 9 * DistanceUnit.metersPerMile),
        .tooHot,
        .hilly,
        .gpsDropout(at: 5_000, for: 60),
        .designWalkthrough,
    ]

    public var name: String {
        switch self {
        case .onPlan: return "onPlan"
        case .slowFade(let from): return "slowFade(from: \(Int(from)))"
        case .tooHot: return "tooHot"
        case .hilly: return "hilly"
        case .gpsDropout(let at, let duration): return "gpsDropout(at: \(Int(at)), for: \(Int(duration)))"
        case .designWalkthrough: return "designWalkthrough"
        case .slowFadeRecovery(let from, let recoverAt):
            return "slowFadeRecovery(from: \(Int(from)), recoverAt: \(Int(recoverAt)))"
        }
    }

    // MARK: Course and plan

    /// The walkthrough's one climb: 3.8% from mile 7.43 to 8.05, so the mile 8
    /// marker falls near its top (the design holds that split to the crest),
    /// centred near mile 7.6 like the design's course profile.
    public static let walkthroughHill = SyntheticHill(start: 11_960, length: 1_000, gain: 38, descent: 900)

    /// The walkthrough's pace before grade and the kick (× plan pace), as (mile, factor),
    /// linear between points. Shaped after the design page's race where the
    /// replay tests allow it: a slow first mile in the crowd (8:09; the design's
    /// 8:14 would trip the pace-gap cue), near plan to mile 4.2 (the glance there
    /// reads "on plan"), then time banked at 2.9% quick, easing on the climb, so
    /// that the 7% fade from mile 9.85 puts the projected finish behind the
    /// target at mile 10.5 while the runner still finishes 0:31 under it. The
    /// banking is quick enough for one "ahead of plan" cue around mile 5.3.
    /// Mile 12 stays slower than plan (the fade never quite recovers) and the
    /// kick from 0.25 mi out is about 7% quicker than what came before it.
    public static let walkthroughPace: [(Double, Double)] = [
        (0, 1.018), (0.95, 1.018), (1.1, 0.986), (4.2, 0.986), (4.4, 0.971), (7.35, 0.971), (7.45, 0.995),
        (8.0, 0.995), (8.1, 0.971), (9.75, 0.971), (10.0, 1.072), (10.65, 1.072), (10.9, 1.0), (11.0, 1.028),
        (13.2, 1.028),
    ]

    /// bpm added to the heart rate the walkthrough runner's effort calls for, as
    /// (mile, bpm), so it follows the design page: ~150 early, drifting up, 165+ on
    /// the climb, a jump into zone 5 (~180) at mile 9.27 — steep enough to spend
    /// less than the heart-rate trigger's 30 s in zone 4 on the way — zone 4 late
    /// in the race and 180+ in the kick (the walkthrough's zones: rest 52, max 188).
    public static let walkthroughHeart: [(Double, Double)] = [
        (0, -12), (5, -11), (7.4, -8), (8.0, -5), (8.6, -9), (9.25, -9), (9.27, 16), (9.5, 12), (9.65, 12),
        (10.0, 14), (10.65, 15), (10.9, 4), (12.8, 3), (13.2, 8),
    ]

    /// Where the walkthrough runner asks the glasses something: a glance before
    /// the gun (mile 0, run time 0), a glance at mile 4.2, a held look at 11.2.
    public static let walkthroughAttention: [(mile: Double, event: AttentionEvent)] = [
        (0, .glance), (4.2, .glance), (11.2, .dwell),
    ]

    /// The design's heart rate zones (Apple Health: rest 52, threshold 172, max
    /// 188), by heart rate reserve.
    public static let walkthroughZones = HeartRateZones.reserve(resting: 52, threshold: 172, max: 188)
    public static let hillyHills = [
        SyntheticHill(start: 2_000, length: 500, gain: 30, descent: 800),
        SyntheticHill(start: 6_000, length: 700, gain: 40, descent: 800),
        SyntheticHill(start: 11_000, length: 400, gain: 25, descent: 800),
        SyntheticHill(start: 16_000, length: 600, gain: 35, descent: 800),
    ]

    public func course(length: Double) -> Course {
        switch self {
        case .hilly: return .synthetic(length: length, hills: SyntheticProfile.hillyHills)
        case .designWalkthrough: return .synthetic(length: length, hills: [SyntheticProfile.walkthroughHill])
        default: return .synthetic(length: length)
        }
    }

    /// The synthetic athlete's zones (SyntheticRun.Athlete: rest 55, max 190).
    /// Its race effort on the flat sits around 163 bpm, so a threshold of 176
    /// puts that in zone 3 (156.6–165.4) and heat or a long climb in zone 4.
    public static let athleteZones = HeartRateZones(resting: 55, threshold: 176, max: 190)

    /// A 1:45:00 half marathon, even pacing, on this profile's course. The
    /// walkthrough also has the design's zones and a gel every 45 minutes.
    public var defaultPlan: RunPlan {
        let walkthrough = self == .designWalkthrough
        return RunPlan(distanceMeters: SyntheticProfile.halfMarathon,
                       targetTime: 6_300,
                       pacing: .even,
                       course: course(length: SyntheticProfile.halfMarathon),
                       heartRateZones: walkthrough ? SyntheticProfile.walkthroughZones : SyntheticProfile.athleteZones,
                       fuelEvery: walkthrough ? 2_700 : nil)
    }

    // MARK: Behaviour

    /// Multiplier on the plan's target pace at a distance and run time, before
    /// grade (>1 = slower). `total` is the race distance.
    func paceFactor(at d: Double, t: TimeInterval, total: Double) -> Double {
        switch self {
        case .onPlan, .hilly, .gpsDropout:
            return 1
        case .slowFade(let from):
            let past = d - from
            return 1 + 0.045 * ramp(past / 400) + 0.035 * max(0, past) / 5_000
        case .tooHot:
            return 1 + 0.03 * ramp(t / 3_600)
        case .designWalkthrough:
            let kickFrom = total - 0.25 * DistanceUnit.metersPerMile
            let base = interpolate(SyntheticProfile.walkthroughPace, at: d / DistanceUnit.metersPerMile)
            return base + (0.95 - base) * ramp((d - kickFrom) / 50)
        case .slowFadeRecovery(let from, let recoverAt):
            let recovered = recoverAt + 2.5 * (recoverAt - from)
            let slow = 0.05 * ramp((d - from) / 400) * (1 - ramp((d - recoverAt) / 400))
            let quick = 0.02 * ramp((d - recoverAt) / 400) * (1 - ramp((d - recovered) / 400))
            return 1 + slow - quick
        }
    }

    /// Extra effort (0–100 points) at the same pace: fatigue as a fade sets in.
    func fatigue(at d: Double, total: Double) -> Double {
        switch self {
        case .slowFade(let from):
            return 8 * ramp((d - from) / 1_600)
        case .designWalkthrough:
            return 6 * ramp((d - 10.5 * DistanceUnit.metersPerMile) / 1_600)
        case .slowFadeRecovery(let from, let recoverAt):
            return 6 * ramp((d - from) / 1_600) * (1 - ramp((d - recoverAt) / 1_600))
        default:
            return 0
        }
    }

    /// Multiplier on effort from conditions (heat).
    func heat(at t: TimeInterval) -> Double {
        self == .tooHot ? 1 + 0.08 * ramp(t / 2_400) : 1
    }

    /// bpm on top of what effort calls for (0 except in the walkthrough).
    func heartOffset(at d: Double) -> Double {
        self == .designWalkthrough
            ? interpolate(SyntheticProfile.walkthroughHeart, at: d / DistanceUnit.metersPerMile) : 0
    }

    /// Fraction cadence has dropped as form goes (0.05 = 5% fewer steps a
    /// minute), on top of what the pace itself does to cadence.
    func cadenceFade(at d: Double) -> Double {
        switch self {
        case .slowFade(let from):
            return 0.07 * ramp((d - from) / 1_600)
        case .slowFadeRecovery(let from, let recoverAt):
            return 0.07 * ramp((d - from) / 1_600) * (1 - ramp((d - recoverAt) / 800))
        case .designWalkthrough:
            // Down ~4% with the fade at mile 10.5: under the form-fade line.
            return 0.02 * ramp((d - 10 * DistanceUnit.metersPerMile) / 800)
        default:
            return 0
        }
    }

    /// Attention events the runner sends, by metres along the course.
    var attention: [(distance: Double, event: AttentionEvent)] {
        guard self == .designWalkthrough else { return [] }
        return SyntheticProfile.walkthroughAttention.map { ($0.mile * DistanceUnit.metersPerMile, $0.event) }
    }

    /// Distance and duration of a scripted GPS outage, if any.
    var gpsOutage: (at: Double, duration: TimeInterval)? {
        if case .gpsDropout(let at, let duration) = self { return (at, duration) }
        return nil
    }
}

/// 0 below 0, 1 above 1, linear between.
private func ramp(_ x: Double) -> Double { min(1, max(0, x)) }

/// Linear between the table's points (sorted by x), flat beyond its ends.
private func interpolate(_ table: [(Double, Double)], at x: Double) -> Double {
    guard let first = table.first, let last = table.last else { return 0 }
    if x <= first.0 { return first.1 }
    if x >= last.0 { return last.1 }
    let i = table.firstIndex { $0.0 > x }!
    let (x0, y0) = table[i - 1], (x1, y1) = table[i]
    return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
}
