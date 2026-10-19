//  RunStateDebugView.swift
//  Debug overlay for a synthetic race: what the engine's state estimator makes
//  of it — projected finish, gap to target, pace, heart rate — and how far to
//  trust each (DataQuality) — and what the arbiter last decided about each
//  cue, with its reason, under the capacity budget it had to fit. Engine
//  values are metres, seconds and s/m; turning
//  them into clocks and min/mi happens here.

import SwiftUI
import DragonEngine

/// RunState numbers as text. UI-side only; the engine never formats.
enum RunStateFormat {
    /// 1:44:29, or 4:05 under an hour.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// +0:12 behind / -1:05 ahead, rounded to the second.
    static func gap(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let sign = total < 0 ? "-" : "+"
        return String(format: "%@%d:%02d", sign, abs(total) / 60, abs(total) % 60)
    }

    /// Seconds per metre as m:ss per mile or kilometre; "—" when unknown.
    static func pace(_ secondsPerMeter: Double?, unit: DistanceUnit = .miles) -> String {
        guard let p = secondsPerMeter, p.isFinite, p > 0 else { return "—" }
        let total = Int((p * unit.meters).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "SHOWN · mile 3 split · highest priority the budget allows"
    static func decision(_ d: Decision) -> String {
        let outcome: String
        switch d.outcome {
        case .shown: outcome = "SHOWN"
        case .heldBack: outcome = "HELD"
        case .expired: outcome = "DROPPED"
        }
        return "\(outcome) · \(d.key.name) · \(d.text)"
    }

    /// "room for 2 · advisory and up · steady at race effort", plus "· GPS held" when inputs are distrusted.
    static func budget(_ b: Budget, situation: Capacity.Situation) -> String {
        let room = b.isEmpty ? "safety only" : "room for \(b.maxElements) · \(b.minPriority) and up"
        let held = CueInput.allCases.filter { b.unreliable.contains($0) }
            .map { $0 == .gps ? "GPS held" : "HR held" }
        return ([room, situation.label] + held).joined(separator: " · ")
    }

    /// Short labels for whatever DataQuality is flagging; empty when all is well.
    static func flags(_ q: DataQuality) -> [String] {
        var out: [String] = []
        if q.paceUnknown { out.append("PACE ?") }
        if q.distanceEstimated { out.append("DEAD RECKONING") }
        if q.offCourse { out.append("OFF COURSE") }
        if q.heartRateMissing { out.append("HR MISSING") }
        if q.effortFallback { out.append("EFFORT FROM PHONE") }
        if q.cadenceFallback { out.append("CADENCE FROM WATCH") }
        return out
    }
}

struct RunStateDebugView: View {
    let state: RunState?
    let targetTime: TimeInterval
    /// The arbiter's latest decisions; shown under the state.
    var decisions: [Decision] = []
    /// The capacity budget of the latest step.
    var budget: Budget?
    var situation: Capacity.Situation?
    private let amber = Color(red: 1, green: 0.54, blue: 0.24)
    private let phos = Color(red: 57 / 255, green: 226 / 255, blue: 122 / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("STATE ESTIMATOR").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.gray)
            if let s = state {
                content(s)
            } else {
                Text("waiting for the race to start").foregroundColor(.gray)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(white: 0.25)))
    }

    @ViewBuilder
    private func content(_ s: RunState) -> some View {
        let gapColor = (s.gapToTarget ?? 0) > 0 ? amber : phos
        row("FINISH", s.projectedFinish.map(RunStateFormat.clock) ?? "—",
            "target \(RunStateFormat.clock(targetTime))")
        row("GAP", s.gapToTarget.map(RunStateFormat.gap) ?? "—",
            "now \(s.behindPlanNow.map(RunStateFormat.gap) ?? "—")", color: gapColor)
        row("PACE", "\(RunStateFormat.pace(s.pace30s)) /mi",
            "60s \(RunStateFormat.pace(s.pace60s)) · GAP \(RunStateFormat.pace(s.gradeAdjustedPace))")
        row("HR", s.heartRate.map { "\(Int($0))" } ?? "—",
            "Z\(s.heartZone.map(String.init) ?? "—") · drift \(s.heartDrift.map { String(format: "%+.1f", $0) } ?? "—")")
        row("EFFORT", s.effort.label,
            "\(s.phase.rawValue) · grade \(s.grade.map { String(format: "%+.1f%%", $0 * 100) } ?? "—")")
        if let budget, let situation {
            row("BUDGET", budget.isEmpty ? "0" : "\(budget.maxElements)",
                RunStateFormat.budget(budget, situation: situation))
        }
        row("GPS", s.quality.gpsAccuracy.map { String(format: "±%.0f m", $0) } ?? "—",
            "fix \(age(s.quality.secondsSinceFix)) · HR \(age(s.quality.secondsSinceHeartRate))")
        let flags = RunStateFormat.flags(s.quality)
        Text(flags.isEmpty ? "DATA OK" : flags.joined(separator: " · "))
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(flags.isEmpty ? phos : amber)
        decisionRows
    }

    @ViewBuilder
    private var decisionRows: some View {
        Text("ARBITER\(decisions.first.map { " @ " + RunStateFormat.clock($0.t) } ?? "")")
            .font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.gray)
            .padding(.top, 2)
        if decisions.isEmpty {
            Text("no cue proposed yet").foregroundColor(.gray)
        }
        // What is on screen first, then what was held back or dropped.
        let ordered = decisions.filter { $0.outcome == .shown } + decisions.filter { $0.outcome != .shown }
        ForEach(Array(ordered.prefix(3).enumerated()), id: \.offset) { _, d in
            Text(RunStateFormat.decision(d))
                .foregroundColor(d.outcome == .shown ? phos : d.outcome == .heldBack ? amber : Color(white: 0.55))
                .lineLimit(2).minimumScaleFactor(0.7)
        }
    }

    private func age(_ seconds: TimeInterval?) -> String {
        seconds.map { String(format: "%.0fs", $0) } ?? "—"
    }

    private func row(_ k: String, _ v: String, _ detail: String, color: Color? = nil) -> some View {
        HStack(spacing: 8) {
            Text(k).foregroundColor(.gray).frame(width: 52, alignment: .leading)
            Text(v).foregroundColor(color ?? .white)
            Spacer(minLength: 4)
            Text(detail).foregroundColor(Color(white: 0.55)).lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}
