//  StateEstimator.swift
//  Stage 1 of the pipeline (Estimate → Trigger → Capacity → Arbiter → Render):
//  raw GPS, vitals and attention samples in, one RunState out.
//
//      distance   course.locate on each good fix when a course is loaded, else
//                 integrated GPS. Fixes worse than 20 m, or implying > 8 m/s
//                 from the last good one, are dropped. Each fix then pulls a
//                 smoothed distance into line (it moves at receiver speed in
//                 between), and for up to 2 minutes of GPS silence distance is
//                 dead-reckoned at the last minute's pace (or the last
//                 fix's speed, if there's less than a minute to go on).
//      pace       30 s and 60 s windows: mean receiver (Doppler) speed when the
//                 fixes carry it, which is far steadier than differencing
//                 positions; otherwise a least-squares fit of distance on time.
//      GAP        60 s pace ÷ the mean GradeModel factor over the metres that
//                 window covered (course elevation; with no course, the
//                 iPhone barometer's altitude when it covers the stretch,
//                 else GPS altitude).
//      projection elapsed + the plan's time for the rest of the course (grade
//                 included), stretched by how far the runner's grade-adjusted
//                 5-minute pace is off plan, counting only as much as the
//                 latest 2.5 minutes confirm. That correction is weighted by
//                 progress — none until 30%, full from 92% — and early on a
//                 dead band treats small deviations as noise: five minutes of
//                 pace wobble says little about the next hour.
//      vitals     device per reading from SourceSelection; HR older than 5 s
//                 is missing, not the last value. effortScore is the chosen
//                 device's motion averaged over 5 s.
//      phase      MovementPhaseClassifier on the good fixes and the chosen
//                 device's motion readings.
//
//  A pure value: ingest(_:) samples in time order, then ask state(at:) with
//  the current run time. It never reads the clock.

import Foundation

public struct StateEstimator {
    public struct Tuning: Sendable, Equatable {
        /// Metres; fixes reporting worse accuracy are ignored.
        public var maxFixAccuracy = 20.0
        /// m/s; a fix implying faster movement from the last good one is ignored.
        public var maxSpeed = 8.0
        /// No 30/60 s pace without a good fix at least this recent.
        public var gpsStaleAfter: TimeInterval = 5
        /// Longest GPS silence distance is dead-reckoned across.
        public var deadReckonLimit: TimeInterval = 120
        /// Seconds over which a fix's position pulls distance into line; between
        /// fixes distance moves at the receiver's speed. Smooths GPS wander.
        public var distanceSmoothing: TimeInterval = 30
        /// Window of the pace the projection extrapolates.
        public var trendWindow: TimeInterval = 300
        /// Progress (0–1) over which the projection hands over from plan pace to actual pace.
        public var blendFrom = 0.3
        public var blendTo = 0.92
        /// Early on, pace within this fraction of plan counts as on plan for the
        /// projection; it narrows to nothing as actual pace takes over.
        public var paceDeadBand = 0.010
        public var driftWindow: TimeInterval = 300
        /// Pace counts as steady for drift when its two halves differ by no more than this.
        public var steadyPaceTolerance = 0.03
        /// Below this (m/s) pace is unknown rather than enormous.
        public var minMovingSpeed = 0.5
        /// How long a glance / dwell stays the current attention (matches AdaptiveEngine).
        public var glanceHold: TimeInterval = 1.5
        public var dwellHold: TimeInterval = 2.6
        /// Seconds of motion readings averaged into effortScore.
        public var effortWindow: TimeInterval = 5
        /// Seconds of motion readings kept, for the kick's baseline.
        public var effortHistory: TimeInterval = 240
        /// Movement phase thresholds.
        public var phase = MovementPhaseClassifier.Config()
        /// A barometric altitude reading this old (seconds) at a fix no longer
        /// counts as the fix's altitude. The phone's altimeter reports every
        /// second or few while the pressure changes.
        public var barometerStaleAfter: TimeInterval = 5

        public init() {}
    }

    public let plan: RunPlan
    public let tuning: Tuning
    private let course: Course?
    private let features: [CourseFeature]
    private let costs: CostTable

    private struct Fix {
        let t: TimeInterval
        /// Metres as this fix alone puts it (course.locate or integrated).
        let measured: Double
        /// Smoothed metres: what the estimator reports.
        let distance: Double
        let speed: Double?
        let latitude: Double
        let longitude: Double
        let altitude: Double?
        /// Barometric altitude at this fix (relative), when a fresh reading was in.
        let baroAltitude: Double?
        let offCourse: Bool
        /// GradeModel factor where this fix was taken (1 when grade is unknown),
        /// so the phase classifier can compare speeds as if flat.
        var gradeFactor = 1.0
    }

    /// Good fixes from the last few minutes, oldest first.
    private var fixes: [Fix] = []
    /// Latest fix received, good or not.
    private var latestFix: (t: TimeInterval, accuracy: Double)?
    /// Watch heart rate from the last few minutes, for drift.
    private var heartRates: [(t: TimeInterval, bpm: Double)] = []
    private var watchHR: SourceReading?
    private var watchMotion: SourceReading?
    private var phoneMotion: SourceReading?
    private var watchCadence: SourceReading?
    private var phoneCadence: SourceReading?
    /// Latest barometric altitude (phone), for the next fixes.
    private var baroAltitude: SourceReading?
    private var lastAttention: AttentionSample?
    /// Motion readings from the last `effortHistory` seconds, per device, oldest first.
    private var watchEfforts: [EffortSample] = []
    private var phoneEfforts: [EffortSample] = []

    /// History kept, seconds: enough for the longest window.
    private var keep: TimeInterval { max(tuning.trendWindow, tuning.driftWindow) + 10 }

    public init(plan: RunPlan, tuning: Tuning = Tuning()) {
        self.plan = plan
        self.tuning = tuning
        self.course = plan.course
        if let course = plan.course {
            let found = course.hills().map(CourseFeature.hill)
                + course.turns().map(CourseFeature.turn)
                + course.aidStations().map(CourseFeature.aidStation)
            self.features = found.sorted { $0.distance < $1.distance }
        } else {
            self.features = []
        }
        self.costs = CostTable(plan: plan)
    }

    // MARK: Ingest

    public mutating func ingest(_ event: RunEvent) {
        switch event {
        case .location(let s): ingest(s)
        case .vitals(let s): ingest(s)
        case .attention(let s): ingest(s)
        }
    }

    public mutating func ingest(_ s: LocationSample) {
        if let latest = latestFix, s.t < latest.t { return }
        latestFix = (s.t, s.horizontalAccuracy)
        guard s.horizontalAccuracy >= 0, s.horizontalAccuracy <= tuning.maxFixAccuracy else { return }

        let last = fixes.last
        let measured: Double
        var offCourse = false
        if let course {
            // Search far enough ahead to catch up after a long outage.
            let reach = last.map { max(500, (s.t - $0.t) * tuning.maxSpeed) } ?? 500
            let loc = course.locate(latitude: s.latitude, longitude: s.longitude, near: last?.measured, ahead: reach)
            measured = loc.distance
            offCourse = loc.offCourse
        } else {
            let step = last.map { Course.haversine($0.latitude, $0.longitude, s.latitude, s.longitude) } ?? 0
            measured = (last?.measured ?? 0) + step
        }

        var distance = measured
        if let last {
            let dt = s.t - last.t
            guard dt > 0, abs(measured - last.measured) / dt <= tuning.maxSpeed else { return }
            // Predict at the receiver's speed, then pull toward this fix's position.
            let speeds = [last.speed, s.speed].compactMap { $0 }
            let v = speeds.isEmpty
                ? (speed(over: 60, at: last.t)?.speed ?? (measured - last.measured) / dt)
                : speeds.reduce(0, +) / Double(speeds.count)
            let predicted = last.distance + v * dt
            distance = predicted + min(1, dt / tuning.distanceSmoothing) * (measured - predicted)
            if let course { distance = min(max(distance, 0), course.totalDistance) }
        }

        let baro = baroAltitude.flatMap { abs(s.t - $0.t) <= tuning.barometerStaleAfter ? $0.value : nil }
        fixes.append(Fix(t: s.t, measured: measured, distance: distance, speed: s.speed, latitude: s.latitude,
                         longitude: s.longitude, altitude: s.altitude, baroAltitude: baro, offCourse: offCourse))
        fixes[fixes.count - 1].gradeFactor = grade(at: distance).map(GradeModel.paceFactor) ?? 1
        if let first = fixes.first, s.t - first.t > keep {
            fixes.removeFirst(fixes.firstIndex { s.t - $0.t <= keep } ?? 0)
        }
    }

    public mutating func ingest(_ s: VitalsSample) {
        let watch = s.source.isWatch
        if let bpm = s.heartRate, watch {
            // Heart rate is Watch-only; a phone HR reading is ignored.
            if watchHR.map({ s.timestamp >= $0.t }) ?? true {
                watchHR = SourceReading(value: bpm, t: s.timestamp, source: s.source)
                heartRates.append((s.timestamp, bpm))
                if let first = heartRates.first, s.timestamp - first.t > keep {
                    heartRates.removeFirst(heartRates.firstIndex { s.timestamp - $0.t <= keep } ?? 0)
                }
            }
        }
        if let m = s.motion {
            if watch {
                StateEstimator.update(&watchMotion, value: m, sample: s)
                append(&watchEfforts, EffortSample(t: s.timestamp, value: m))
            } else {
                StateEstimator.update(&phoneMotion, value: m, sample: s)
                append(&phoneEfforts, EffortSample(t: s.timestamp, value: m))
            }
        }
        if let a = s.altitude {
            StateEstimator.update(&baroAltitude, value: a, sample: s)
        }
        if let c = s.cadence {
            if watch {
                StateEstimator.update(&watchCadence, value: c, sample: s)
            } else {
                StateEstimator.update(&phoneCadence, value: c, sample: s)
            }
        }
    }

    public mutating func ingest(_ s: AttentionSample) {
        if let last = lastAttention, s.t < last.t { return }
        lastAttention = s
    }

    /// Keeps a device's motion history in time order and about `effortHistory`
    /// long (trimmed in batches, so appending stays cheap).
    private func append(_ history: inout [EffortSample], _ e: EffortSample) {
        if let last = history.last, e.t < last.t { return }
        history.append(e)
        if let first = history.first, e.t - first.t > tuning.effortHistory + 30 {
            history.removeFirst(history.firstIndex { e.t - $0.t <= tuning.effortHistory } ?? 0)
        }
    }

    private static func update(_ reading: inout SourceReading?, value: Double, sample s: VitalsSample) {
        guard reading.map({ s.timestamp >= $0.t }) ?? true else { return }
        reading = SourceReading(value: value, t: s.timestamp, source: s.source)
    }

    // MARK: State

    public func state(at t: TimeInterval) -> RunState {
        var q = DataQuality()
        q.gpsAccuracy = latestFix?.accuracy

        // Distance: last good fix, dead-reckoned forward at the recent pace.
        let last = fixes.last { $0.t <= t }
        var distance = 0.0
        if let last {
            let age = t - last.t
            q.secondsSinceFix = age
            q.offCourse = last.offCourse
            distance = last.distance
            if age > 0, let recent = speed(over: 60, at: last.t)?.speed ?? last.speed {
                distance += recent * min(age, tuning.deadReckonLimit)
            }
            q.distanceEstimated = age > tuning.gpsStaleAfter
            if let course { distance = min(distance, course.totalDistance) }
        }

        // Pace, only from fresh GPS.
        let fresh = last.map { t - $0.t <= tuning.gpsStaleAfter } ?? false
        let w30 = fresh ? speed(over: 30, at: t) : nil
        let w60 = fresh ? speed(over: 60, at: t) : nil
        let pace30 = w30.flatMap { pace($0.speed) }
        let pace60 = w60.flatMap { pace($0.speed) }
        q.paceUnknown = pace30 == nil
        let gap = w60.flatMap { w in
            pace60.flatMap { p in meanGradeFactor(from: w.from, to: w.to).map { p / $0 } }
        }

        // Plan and projection.
        var projected: TimeInterval?, behind: TimeInterval?
        if last != nil {
            behind = t - plan.planTime(at: distance)
            projected = t + remainingTime(from: distance, at: t)
        }

        // Vitals.
        let hr = SourceSelection.heartRate(watch: watchHR, at: t)
        q.secondsSinceHeartRate = watchHR.map { t - $0.t }

        let effortPick = SourceSelection.effort(watch: watchMotion, phone: phoneMotion, at: t)
        q.effortSource = effortPick?.reading.source
        q.effortFallback = effortPick?.isFallback ?? false
        // Neither device fresh: hold the newest reading rather than invent "stationary".
        let newestMotion = [watchMotion, phoneMotion].compactMap { $0 }.max { $0.t < $1.t }
        let effortReading = effortPick?.reading ?? newestMotion
        let effort = effortReading.map { MotionBand(motion: $0.value) } ?? .stationary
        let efforts = effortReading.map { $0.source.isWatch ? watchEfforts : phoneEfforts } ?? []
        let effortScore = effortReading.map { r in
            MovementPhaseClassifier.mean(efforts, from: t - tuning.effortWindow, to: t) ?? r.value
        }
        let grade = last == nil ? nil : grade(at: distance)
        let phase = MovementPhaseClassifier(config: tuning.phase).phase(
            at: t, speeds: fixes.map { MovementSample(t: $0.t, distance: $0.distance, speed: $0.speed,
                                                      gradeFactor: $0.gradeFactor) },
            efforts: efforts, grade: grade, distance: distance, total: course?.totalDistance ?? plan.distanceMeters)

        let cadencePick = SourceSelection.cadence(phone: phoneCadence, watch: watchCadence, at: t)
        q.cadenceSource = cadencePick?.reading.source
        q.cadenceFallback = cadencePick?.isFallback ?? false

        return RunState(elapsed: t,
                        distance: distance,
                        pace30s: pace30,
                        pace60s: pace60,
                        gradeAdjustedPace: gap,
                        projectedFinish: projected,
                        gapToTarget: projected.map { $0 - plan.targetTime },
                        behindPlanNow: behind,
                        heartRate: hr?.value,
                        heartZone: hr.flatMap { plan.heartRateZones?.zone(for: $0.value) },
                        heartDrift: heartDrift(at: t),
                        cadence: cadencePick?.reading.value,
                        grade: grade,
                        ahead: ahead(of: distance),
                        effort: effort,
                        effortScore: effortScore,
                        phase: phase,
                        attention: attention(at: t),
                        quality: q)
    }

    // MARK: Pace

    private struct WindowSpeed {
        let speed: Double      // m/s
        let from: Double       // metres at the first and last fix in the window
        let to: Double
    }

    /// Speed over the good fixes in (t − window, t]. Needs at least 3 fixes
    /// spanning half the window.
    private func speed(over window: TimeInterval, at t: TimeInterval) -> WindowSpeed? {
        guard let end = fixes.lastIndex(where: { $0.t <= t }) else { return nil }
        var start = end
        while start > 0, fixes[start - 1].t > t - window { start -= 1 }
        let w = fixes[start...end]
        guard w.count >= 3, let first = w.first, let last = w.last, last.t - first.t >= window / 2 else { return nil }

        let doppler = w.compactMap(\.speed)
        let v: Double
        if Double(doppler.count) >= 0.8 * Double(w.count) {
            v = doppler.reduce(0, +) / Double(doppler.count)
        } else {
            v = StateEstimator.slope(w.map { ($0.t, $0.measured) }) ?? 0
        }
        return WindowSpeed(speed: v, from: first.distance, to: last.distance)
    }

    private func pace(_ speed: Double) -> Double? {
        speed >= tuning.minMovingSpeed ? 1 / speed : nil
    }

    /// Least-squares slope of y on x; nil with no spread in x.
    static func slope(_ points: [(x: Double, y: Double)]) -> Double? {
        guard points.count >= 2 else { return nil }
        let n = Double(points.count)
        let mx = points.reduce(0) { $0 + $1.x } / n, my = points.reduce(0) { $0 + $1.y } / n
        let sxx = points.reduce(0) { $0 + ($1.x - mx) * ($1.x - mx) }
        guard sxx > 0 else { return nil }
        return points.reduce(0) { $0 + ($1.x - mx) * ($1.y - my) } / sxx
    }

    // MARK: Grade

    /// Mean GradeModel factor over a stretch: from the course when it has
    /// elevation, else from barometric or GPS altitude; nil when none is known.
    private func meanGradeFactor(from d0: Double, to d1: Double) -> Double? {
        if let course {
            return course.hasElevation ? costs.meanFactor(from: d0, to: d1) : nil
        }
        return altitudeGrade(from: d0, to: d1).map(GradeModel.paceFactor)
    }

    private func grade(at d: Double) -> Double? {
        if let course {
            guard let up = course.elevation(at: d + 10), let down = course.elevation(at: d - 10) else { return nil }
            return (up - down) / 20
        }
        return altitudeGrade(from: d - 100, to: d)
    }

    /// Grade from altitude against distance over a stretch (at least 50 m of
    /// it, widened back if shorter): the barometer's when its readings span the
    /// stretch (far steadier), else GPS altitude, which is noisy. A fallback
    /// for runs without a course.
    private func altitudeGrade(from d0: Double, to d1: Double) -> Double? {
        let lo = min(d0, d1 - 50)
        func grade(_ altitude: (Fix) -> Double?) -> Double? {
            let pts = fixes.compactMap { f in altitude(f).map { (x: f.distance, y: $0) } }
                .filter { $0.x >= lo && $0.x <= d1 }
            guard let first = pts.first, let last = pts.last, last.x - first.x >= 50 else { return nil }
            return StateEstimator.slope(pts)
        }
        return grade(\.baroAltitude) ?? grade(\.altitude)
    }

    // MARK: Projection

    /// Seconds to the finish from `distance`: the plan's time for the rest
    /// of the course (grade included), scaled by how far the runner's
    /// grade-adjusted trend pace is off plan (as far as its latest half
    /// agrees), by a weight that grows with progress. Early on, small deviations inside the dead band count as on
    /// plan; a few minutes of pace says little about the next hour.
    private func remainingTime(from distance: Double, at t: TimeInterval) -> TimeInterval {
        let planned = costs.plannedRemaining(from: distance)
        let flatAhead = costs.flatRemaining(from: distance)
        guard flatAhead > 0, let long = flatPaceOff(over: tuning.trendWindow, at: t, planFlatPace: planned / flatAhead)
        else { return planned }
        // Count only what the latest half of the window confirms: a real change
        // of pace shows in both (the full window, lagging, is the smaller), while
        // a wobble that is already reversing shows in one.
        let recent = flatPaceOff(over: tuning.trendWindow / 2, at: t, planFlatPace: planned / flatAhead) ?? long
        let off = long * recent > 0 ? (abs(long) < abs(recent) ? long : recent) : 0

        let progress = distance / plan.distanceMeters
        let w = min(1, max(0, (progress - tuning.blendFrom) / (tuning.blendTo - tuning.blendFrom)))
        let band = tuning.paceDeadBand * (1 - w * w)
        let counted = off > 0 ? max(0, off - band) : min(0, off + band)
        return planned * (1 + w * counted)
    }

    /// Fraction the runner's grade-adjusted pace over `window` is off a flat
    /// plan pace (+ = slower); nil without enough fixes or movement.
    private func flatPaceOff(over window: TimeInterval, at t: TimeInterval, planFlatPace: Double) -> Double? {
        guard let w = speed(over: window, at: t), let pace = pace(w.speed) else { return nil }
        return pace / (meanGradeFactor(from: w.from, to: w.to) ?? 1) / planFlatPace - 1
    }

    // MARK: Heart rate drift

    /// bpm gained over the last 5 minutes (least-squares), if pace held steady.
    private func heartDrift(at t: TimeInterval) -> Double? {
        let window = tuning.driftWindow
        let hrs = heartRates.filter { $0.t > t - window && $0.t <= t }
        guard hrs.count >= Int(window / 2), let first = hrs.first, let last = hrs.last,
              last.t - first.t >= window * 0.8 else { return nil }
        guard let early = speed(over: window / 2, at: t - window / 2),
              let late = speed(over: window / 2, at: t), early.speed > 0,
              abs(late.speed / early.speed - 1) <= tuning.steadyPaceTolerance else { return nil }
        return StateEstimator.slope(hrs.map { ($0.t, $0.bpm) }).map { $0 * window }
    }

    // MARK: Course and attention

    private func ahead(of distance: Double) -> Ahead? {
        guard let next = features.first(where: { $0.endDistance > distance }) else { return nil }
        return Ahead(feature: next, meters: max(0, next.distance - distance))
    }

    private func attention(at t: TimeInterval) -> AttentionEvent {
        guard let a = lastAttention, a.t <= t else { return .idle }
        switch a.event {
        case .glance: return t - a.t <= tuning.glanceHold ? .glance : .idle
        case .dwell: return t - a.t <= tuning.dwellHold ? .dwell : .idle
        case .idle: return .idle
        }
    }
}

/// Cumulative grade cost along the plan's distance, every 10 m, so the time
/// left to the finish is two lookups instead of a walk down the course.
///     flat(x)    = ∫₀ˣ GradeModel factor           (metres "as if flat")
///     planned(x) = ∫₀ˣ plan pace × GradeModel factor (seconds)
/// Without course elevation every factor is 1.
struct CostTable {
    static let step = 10.0
    private let flat: [Double]
    private let planned: [Double]
    private let total: Double

    init(plan: RunPlan) {
        total = plan.distanceMeters
        let n = Int((total / CostTable.step).rounded(.up))
        var flat = [0.0], planned = [0.0]
        flat.reserveCapacity(n + 1)
        planned.reserveCapacity(n + 1)
        for i in 0..<n {
            let a = Double(i) * CostTable.step, b = min(total, a + CostTable.step), mid = (a + b) / 2
            var factor = 1.0
            if let course = plan.course, let up = course.elevation(at: mid + 10), let down = course.elevation(at: mid - 10) {
                factor = GradeModel.paceFactor(grade: (up - down) / 20)
            }
            flat.append(flat[i] + factor * (b - a))
            planned.append(planned[i] + plan.targetPace(at: mid) * factor * (b - a))
        }
        self.flat = flat
        self.planned = planned
    }

    private static func value(_ table: [Double], at x: Double, total: Double) -> Double {
        let d = min(max(x, 0), total)
        let i = min(Int(d / step), table.count - 2)
        let a = Double(i) * step, b = min(total, a + step)
        let f = b > a ? (d - a) / (b - a) : 0
        return table[i] + (table[i + 1] - table[i]) * f
    }

    func flatRemaining(from d: Double) -> Double {
        flat[flat.count - 1] - CostTable.value(flat, at: d, total: total)
    }

    func plannedRemaining(from d: Double) -> Double {
        planned[planned.count - 1] - CostTable.value(planned, at: d, total: total)
    }

    /// Mean factor over [d0, d1]; the point factor when the stretch is shorter than a step.
    func meanFactor(from d0: Double, to d1: Double) -> Double {
        let lo = min(d0, d1), hi = max(d0, d1)
        if hi - lo < CostTable.step {
            let mid = (lo + hi) / 2
            return (CostTable.value(flat, at: mid + CostTable.step / 2, total: total)
                - CostTable.value(flat, at: mid - CostTable.step / 2, total: total)) / CostTable.step
        }
        return (CostTable.value(flat, at: hi, total: total) - CostTable.value(flat, at: lo, total: total)) / (hi - lo)
    }
}
