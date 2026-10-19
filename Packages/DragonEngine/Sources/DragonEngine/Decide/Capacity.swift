//  Capacity.swift
//  Stage 3 of the pipeline (Estimate → Trigger → Capacity → Arbiter → Render):
//  how much the runner can take in right now, as a Budget. The design's table,
//  first matching row wins:
//
//      Final 400 m of the race             nothing except safety ("only the kick clock")
//      Surge, final kick, technical turn   nothing except safety
//      Hard effort or climbing             1 element  · critical and up
//      Standing, or easy and steady        3 elements · info and up
//      Steady at race effort               2 elements · advisory and up
//
//  then, on top of the row:
//      display setting      Minimal −1 element, Balanced 0, Coach +1
//      runner glanced       +1 element for 1.5 s
//      runner held a look   +2 elements for 2.6 s
//      GPS / heart rate     unreliable → cues that need it are held back
//
//  The setting and attention only move maxElements, never below 0, and never
//  the row's minPriority: Coach during a kick is one element, still safety only.
//  The final stretch is decided by position (metres left to the plan's finish),
//  not by the runner speeding up: MovementPhase.kick is the separate "kicking"
//  signal, and in the final stretch the budget is safety only either way.
//  "Technical turn" is a sharp turn (Course.turns) within 50 m ahead. Effort
//  comes from RunState.effortScore with its own thresholds rather than the
//  MotionBand: a runner racing a half marathon sits around 80, which the band
//  already calls hard.
//
//  A value like the triggers: the attention windows are its only state, and it
//  never reads the clock.

import Foundation

/// How chatty the glasses should be, set before the run.
public enum DisplaySetting: String, Sendable, Equatable, CaseIterable {
    case minimal, balanced, coach

    /// Elements added to (or taken from) every budget.
    public var shift: Int {
        switch self {
        case .minimal: return -1
        case .balanced: return 0
        case .coach: return 1
        }
    }
}

public struct CapacityConfig: Sendable, Equatable {
    /// Effort score (0–100) under which steady running counts as easy (MotionBand's light/moderate line).
    public var easyEffort = 38.0
    /// Effort score at and above which the runner is working hard. The synthetic
    /// runner races at ~80 on the flat and ~86 on a 6% climb.
    public var hardEffort = 88.0
    /// Metres before the finish where the final stretch starts: safety only from
    /// there to the line, whatever the runner does (design: "Final 400 m: only
    /// the kick clock").
    public var finalStretch = 400.0
    /// Metres ahead within which a sharp turn closes the budget.
    public var technicalTurnAhead = 50.0
    /// Seconds a glance / a held look adds room for, and how much.
    public var glanceWindow: TimeInterval = 1.5
    public var glanceBonus = 1
    public var dwellWindow: TimeInterval = 2.6
    public var dwellBonus = 2
    /// GPS counts as unreliable with no fix in this many seconds, or one this inaccurate (metres).
    public var gpsStaleAfter: TimeInterval = 5
    public var gpsMaxAccuracy = 20.0

    /// The table's rows.
    public var relaxed = Budget.relaxed
    public var steady = Budget.steady
    public var strained = Budget.strained
    public var safetyOnly = Budget.safetyOnly

    public init() {}
}

/// Glance and held-look bonuses as windows in run time. Each event opens its
/// own window; overlapping windows give the bigger bonus. An idle event does
/// not shut a window: the glasses' gesture source sends idle 1.5 s after every
/// wave, held look or not.
public struct AttentionWindow: Sendable, Equatable {
    public private(set) var glanceUntil: TimeInterval?
    public private(set) var dwellUntil: TimeInterval?

    public init() {}

    public mutating func note(_ event: AttentionEvent, at t: TimeInterval, config: CapacityConfig) {
        switch event {
        case .glance: glanceUntil = max(glanceUntil ?? t, t + config.glanceWindow)
        case .dwell: dwellUntil = max(dwellUntil ?? t, t + config.dwellWindow)
        case .idle: break
        }
    }

    /// Elements added at run time `t`.
    public func bonus(at t: TimeInterval, config: CapacityConfig) -> Int {
        var b = 0
        if let until = glanceUntil, t <= until { b = max(b, config.glanceBonus) }
        if let until = dwellUntil, t <= until { b = max(b, config.dwellBonus) }
        return b
    }
}

public struct Capacity: Sendable {
    /// Which row of the table applies.
    public enum Situation: String, Sendable, Equatable {
        case standing, easy, raceEffort, hardEffort, climbing, surge, kick, technicalTurn, finalStretch

        /// Words for the debug overlay.
        public var label: String {
            switch self {
            case .standing: return "standing"
            case .easy: return "easy and steady"
            case .raceEffort: return "steady at race effort"
            case .hardEffort: return "hard effort"
            case .climbing: return "climbing"
            case .surge: return "surge"
            case .kick: return "final kick"
            case .technicalTurn: return "technical turn"
            case .finalStretch: return "final stretch"
            }
        }
    }

    public let config: CapacityConfig
    public var setting: DisplaySetting
    /// Race length in metres (the plan's finish), or nil for a run with no
    /// finish, which then has no final stretch.
    public let raceDistance: Double?
    public private(set) var attention = AttentionWindow()

    public init(config: CapacityConfig = CapacityConfig(), setting: DisplaySetting = .balanced,
                raceDistance: Double? = nil) {
        self.config = config
        self.setting = setting
        self.raceDistance = raceDistance
    }

    /// Whether `distance` (metres covered) is in the race's final stretch.
    public func inFinalStretch(_ distance: Double) -> Bool {
        guard let total = raceDistance else { return false }
        return total - distance <= config.finalStretch
    }

    /// An attention event from the glasses, at its run time.
    public mutating func note(_ sample: AttentionSample) {
        attention.note(sample.event, at: sample.t, config: config)
    }

    /// The row for this state. `effort` overrides state.effortScore (the app's slider).
    public func situation(for s: RunState, effort: Double? = nil) -> Situation {
        if inFinalStretch(s.distance) { return .finalStretch }
        if case .turn? = s.ahead?.feature, let m = s.ahead?.meters, m <= config.technicalTurnAhead {
            return .technicalTurn
        }
        switch s.phase {
        case .kick: return .kick
        case .surging: return .surge
        case .stopped: return .standing
        case .climbing, .steady: break
        }
        let score = effort ?? s.effortScore
        if let e = score, e >= config.hardEffort { return .hardEffort }
        if s.phase == .climbing { return .climbing }
        if let e = score, e < config.easyEffort { return .easy }
        return .raceEffort
    }

    /// The budget at run time `t` for this state.
    public func budget(for s: RunState, at t: TimeInterval, effort: Double? = nil) -> Budget {
        var b: Budget
        switch situation(for: s, effort: effort) {
        case .finalStretch:
            b = config.safetyOnly
            b.finalStretch = true
        case .technicalTurn, .kick, .surge: b = config.safetyOnly
        case .hardEffort, .climbing: b = config.strained
        case .standing, .easy: b = config.relaxed
        case .raceEffort: b = config.steady
        }
        b.maxElements = max(0, b.maxElements + setting.shift + attention.bonus(at: t, config: config))
        b.unreliable = unreliable(s.quality)
        return b
    }

    /// The inputs too poor to act on.
    public func unreliable(_ q: DataQuality) -> Set<CueInput> {
        var out: Set<CueInput> = []
        let stale = (q.secondsSinceFix ?? .infinity) > config.gpsStaleAfter
        let poor = (q.gpsAccuracy ?? .infinity) > config.gpsMaxAccuracy
        if stale || poor || q.paceUnknown || q.distanceEstimated || q.offCourse { out.insert(.gps) }
        if q.heartRateMissing { out.insert(.heartRate) }
        return out
    }
}
