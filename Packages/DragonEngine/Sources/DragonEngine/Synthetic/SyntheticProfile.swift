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
    /// The design doc's race: a 1:45:00 half at 8:01/mi even, banking a little
    /// early, a +36 m (118 ft) hill around mile 7.6, a fade from mile 10.5 and a
    /// kick in the last 0.25 mi. Finishes around 1:44:29.
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

    public static let walkthroughHill = SyntheticHill(start: 7.6 * DistanceUnit.metersPerMile - 300,
                                                      length: 600, gain: 36, descent: 900)
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

    /// A 1:45:00 half marathon, even pacing, on this profile's course.
    public var defaultPlan: RunPlan {
        RunPlan(distanceMeters: SyntheticProfile.halfMarathon,
                targetTime: 6_300,
                pacing: .even,
                course: course(length: SyntheticProfile.halfMarathon),
                heartRateZones: HeartRateZones(resting: 55, threshold: 172, max: 190))
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
            let fadeFrom = 10.5 * DistanceUnit.metersPerMile
            let kickFrom = total - 0.25 * DistanceUnit.metersPerMile
            let base = 0.9887 + 0.04 * ramp((d - fadeFrom) / 800)
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

    /// Distance and duration of a scripted GPS outage, if any.
    var gpsOutage: (at: Double, duration: TimeInterval)? {
        if case .gpsDropout(let at, let duration) = self { return (at, duration) }
        return nil
    }
}

/// 0 below 0, 1 above 1, linear between.
private func ramp(_ x: Double) -> Double { min(1, max(0, x)) }
