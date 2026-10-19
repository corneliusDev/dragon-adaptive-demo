//  HeartCeilingTrigger.swift
//  Heart rate over its ceiling: zone 5 at any point, or zone 4 before 80% of
//  the distance (too early to be working that hard), held for 30 s, is a
//  critical cue ("HR 178 Z5 · EASE 5 SEC/MI"). Back below the ceiling for 20 s
//  clears it; the next time over is a new cue. While on, a ceiling that only
//  moves (zone 5 easing to zone 4 before 80%) doesn't clear it or fire again.
//
//  Heart rate is smoothed over 10 s so one noisy reading neither starts nor
//  clears it. Missing or stale heart rate (RunState.heartRate nil) never fires
//  it: the wait to fire starts over, and the cue needs heart rate, so the
//  arbiter holds it back while the budget calls heart rate unreliable.
//  Zone 4 on a climb, and for a minute after it, is expected (design: "zone
//  4 is expected on a climb") and doesn't count; zone 5 always does. Without
//  the plan's heart rate zones it never fires.

import Foundation

public struct HeartCeilingTrigger: Trigger {
    public struct Config: Sendable, Equatable {
        /// Zone that is too high before `lateFraction` of the distance, and from then on.
        public var earlyZone = 4
        public var lateZone = 5
        /// Fraction of the distance from which only `lateZone` counts (0.8 = 80%).
        public var lateFraction = 0.8
        /// Seconds over the ceiling before it fires, and back under it before it clears.
        public var hold: TimeInterval = 30
        public var clearHold: TimeInterval = 20
        /// Seconds of heart rate averaged before the zone is read.
        public var smoothing: TimeInterval = 10
        /// Seconds after a climb during which `earlyZone` still doesn't count (heart rate lags the grade).
        public var climbGrace: TimeInterval = 60
        /// The advice: ease off this many seconds per mile / kilometre.
        public var easeBy: TimeInterval = 5
        public var unit: DistanceUnit = .miles
        public var priority: Priority = .critical
        /// Seconds the cue stays up (design: 5 s).
        public var minShow: TimeInterval = 5
        public var expiresAfter: TimeInterval = 30

        public init(unit: DistanceUnit = .miles) {
            self.unit = unit
        }
    }

    public let plan: RunPlan
    public let config: Config
    /// Over its ceiling (fired and not yet cleared).
    public private(set) var isOn = false
    /// Heart rate averaged over `smoothing`, as of the last evaluate; nil while missing.
    public private(set) var smoothed: Double?
    /// Run time the current wait to fire, or to clear, began.
    private var overSince: TimeInterval?
    private var underSince: TimeInterval?
    private var lastClimbAt: TimeInterval?
    private var recent: [(t: TimeInterval, bpm: Double)] = []

    public init(plan: RunPlan, config: Config = Config()) {
        self.plan = plan
        self.config = config
    }

    /// The zone the smoothed heart rate is in, as of the last evaluate.
    public var zone: Int? { smoothed.flatMap { plan.heartRateZones?.zone(for: $0) } }

    public mutating func evaluate(state s: RunState, at t: TimeInterval) -> [Cue] {
        if s.phase == .climbing { lastClimbAt = t }
        guard let bpm = s.heartRate, let zones = plan.heartRateZones else {
            // Missing heart rate: nothing to judge. Start the wait over; don't clear.
            smoothed = nil
            recent = []
            overSince = nil
            return []
        }
        recent.append((t, bpm))
        recent.removeAll { t - $0.t > config.smoothing }
        let hr = recent.reduce(0) { $0 + $1.bpm } / Double(recent.count)
        smoothed = hr
        let zone = zones.zone(for: hr)
        let early = s.distance < config.lateFraction * plan.distanceMeters
        let ceiling = early ? config.earlyZone : config.lateZone
        let climbing = lastClimbAt.map { t - $0 <= config.climbGrace } ?? false
        let over = zone >= config.lateZone || (zone >= ceiling && !climbing)

        if isOn {
            guard !over else {
                underSince = nil
                return []
            }
            let since = underSince ?? t
            underSince = since
            if t - since >= config.clearHold {
                isOn = false
                underSince = nil
            }
            return []
        }
        guard over else {
            overSince = nil
            return []
        }
        let since = overSince ?? t
        overSince = since
        guard t - since >= config.hold else { return [] }
        isOn = true
        overSince = nil
        return [cue(bpm: hr, zone: zone, at: t)]
    }

    private func cue(bpm: Double, zone: Int, at t: TimeInterval) -> Cue {
        Cue(key: .heartCeiling,
            priority: config.priority,
            reveal: .auto,
            content: CueContent(main: .label("HR \(Int(bpm.rounded())) Z\(zone)"),
                                subtitle: [.phrase([.label("EASE"), .perUnit(config.easeBy, config.unit)])],
                                tag: "HEART",
                                icon: .warn),
            createdAt: t,
            expiresAt: t + config.expiresAfter,
            minShow: config.minShow,
            needs: [.heartRate])
    }
}
