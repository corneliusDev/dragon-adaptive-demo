//  CueLogView.swift
//  The post-race review: every cue that showed, with the arbiter's decision
//  and reason, what the runner did (glanced, held a look, ignored, dismissed)
//  and, for pace-gap and heart-rate cues, whether it helped a minute later
//  (pace back toward plan, or heart rate down; the gap is shown alongside);
//  plus how many cues of each kind were held back or expired without showing.
//  SHARE exports the run's JSON-lines file through the share sheet.

import SwiftUI
import DragonEngine

/// Cue log values as text. UI-side only; the engine never formats.
enum CueLogFormat {
    /// "4 shown · 2 held back": the telemetry row that replaced the flywheel counter.
    static func counts(_ s: RunSummary) -> String {
        "\(s.total.shown) shown · \(s.total.heldBack) held back"
    }

    static func response(_ r: CueResponse?) -> String {
        switch r {
        case .glanced?: return "glanced"
        case .heldLook?: return "held a look"
        case .ignored?: return "ignored"
        case .dismissed?: return "dismissed"
        case nil: return "still up"
        }
    }

    /// "pace +4.7% → +3.1% after 60 s · better · gap +0:28 → +0:29, +0:04 at 180 s",
    /// "HR 176 → 171 after 60 s · better". The pace offset decides; the gap is information.
    static func outcome(_ o: CueOutcome) -> String {
        func value(_ v: Double?) -> String {
            guard let v else { return "—" }
            switch o.measure {
            case .paceOffset: return String(format: "%+.1f%%", v * 100)
            case .heartRate: return "\(Int(v.rounded()))"
            }
        }
        let name = o.measure == .paceOffset ? "pace" : "HR"
        var text: String
        if o.after == nil {
            text = "\(name) \(value(o.atShow)) · waiting"
        } else {
            let verdict = o.improved.map { $0 ? "better" : "worse" } ?? "unknown"
            text = "\(name) \(value(o.atShow)) → \(value(o.after)) after \(Int((o.at - o.shownAt).rounded())) s · \(verdict)"
        }
        if let g = o.gapAtShow {
            text += " · gap \(RunStateFormat.gap(g))"
            if let a = o.gapAfter { text += " → \(RunStateFormat.gap(a))" }
            if let l = o.gapLater, let at = o.laterAt {
                text += ", \(RunStateFormat.gap(l)) at \(Int((at - o.shownAt).rounded())) s"
            }
        }
        return text
    }

    /// "MILE 3 · 8:14"
    static func content(_ c: CueContent) -> String {
        [c.heading ?? c.tag.map(CueText.label), c.main].compactMap { $0 }.map(CueFormat.string)
            .joined(separator: " · ")
    }

    /// "1:44:29 · 0:31 under target"
    static func finish(_ s: RunSummary) -> String {
        guard let finish = s.finishTime, let vs = s.finishVsTarget else {
            return "not finished · target \(RunStateFormat.clock(s.targetTime))"
        }
        let diff = RunStateFormat.clock(abs(vs))
        return "\(RunStateFormat.clock(finish)) · \(diff) \(vs <= 0 ? "under" : "over") target"
    }
}

struct CueLogView: View {
    let log: CueLog
    /// The saved file, for SHARE; nil until saved.
    let fileURL: URL?
    @Environment(\.dismiss) private var dismiss

    private let phos = Color(red: 57 / 255, green: 226 / 255, blue: 122 / 255)
    private let amber = Color(red: 1, green: 0.54, blue: 0.24)

    var body: some View {
        let summary = log.summary
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("CUE LOG").font(.system(size: 13, weight: .bold, design: .monospaced))
                Spacer()
                if let fileURL {
                    ShareLink(item: fileURL) { Text("SHARE") }
                        .accessibilityIdentifier("cueLogShare")
                }
                Button("DONE") { dismiss() }
                    .accessibilityIdentifier("cueLogDone")
            }
            .font(.system(size: 12, design: .monospaced)).foregroundColor(phos)

            Text(log.header.name).foregroundColor(.gray)
            Text("FINISH \(CueLogFormat.finish(summary))").foregroundColor(amber)
            Text(CueLogFormat.counts(summary) + " · \(summary.total.expired) expired unshown")
                .foregroundColor(phos)
                .accessibilityIdentifier("cueLogCounts")
            ForEach(summary.byKind, id: \.kind) { k in
                Text("\(k.kind.rawValue): \(k.counts.shown) shown · \(k.counts.heldBack) held · \(k.counts.expired) expired")
                    .foregroundColor(Color(white: 0.6))
            }
            Divider().background(Color(white: 0.2))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if log.appearances.isEmpty {
                        Text("no cue shown yet").foregroundColor(.gray)
                    }
                    ForEach(Array(log.appearances.enumerated()), id: \.offset) { _, e in
                        row(e)
                    }
                }
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(.white)
        .padding(16)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func row(_ e: CueEvent) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(RunStateFormat.clock(e.t)).foregroundColor(.gray)
                Text(String(format: "mi %.2f", e.state.distance / DistanceUnit.metersPerMile)).foregroundColor(.gray)
                Spacer()
                Text(e.cue.key.name.uppercased()).foregroundColor(phos)
            }
            Text(CueLogFormat.content(e.cue.content))
            Text("SHOWN · \(e.text)").foregroundColor(Color(white: 0.6))
            Text("RESPONSE \(CueLogFormat.response(e.response))").foregroundColor(amber)
            if let o = e.outcome {
                Text("OUTCOME \(CueLogFormat.outcome(o))").foregroundColor(o.improved == true ? phos : amber)
            }
        }
        .padding(.vertical, 4)
    }
}
