//  ReviewView.swift
//  The review screen (design: "After the race"): the result against the
//  target, the splits against the plan, how many cues showed, were held back
//  or dismissed, every cue that showed with what the runner did and whether
//  it helped, and the one question, saved into the cue log. FULL LOG opens
//  the decision-by-decision CueLogView (with SHARE).

import SwiftUI
import Charts
import DragonEngine

struct ReviewView: View {
    let model: ReviewModel
    var onDone: () -> Void = {}
    @State private var showLog = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TopBar {
                    Button(action: onDone) {
                        Text("‹ RACES").font(Theme.mono(12, weight: .semibold)).foregroundColor(Theme.ink)
                    }
                    .accessibilityIdentifier("reviewDone")
                } trailing: {
                    HStack(spacing: 8) { BrandMark(); Text("RACE REVIEW") }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.record.plan.name).font(Theme.mono(11)).foregroundColor(Theme.muted)
                    Text(model.resultText).font(Theme.display(34)).monospacedDigit()
                        .foregroundColor(model.record.finished ? (model.beatTarget ? Theme.phos : Theme.amber) : Theme.ink)
                        .accessibilityIdentifier("reviewResult")
                    Text(model.targetLine).font(.system(size: 12)).foregroundColor(Theme.muted)
                        .accessibilityIdentifier("reviewTarget")
                }

                Field(label: model.splitsTitle) {
                    if model.splits.isEmpty {
                        Text("No full \(model.unit == .miles ? "mile" : "kilometre") run yet.")
                            .font(.system(size: 12)).foregroundColor(Theme.muted)
                    } else {
                        SplitsChart(splits: model.splits)
                            .frame(height: 110)
                            .accessibilityIdentifier("splitsChart")
                    }
                }

                HStack(spacing: 8) {
                    StatTile(label: "Shown", value: "\(model.shownCount)", id: "reviewShown")
                    StatTile(label: "Held back", value: "\(model.heldBackCount)", id: "reviewHeldBack")
                    StatTile(label: "Dismissed", value: "\(model.dismissedCount)", id: "reviewDismissed")
                }

                cueList

                Field(label: "How was the display?") {
                    HStack(spacing: 6) {
                        ForEach(CueRating.allCases, id: \.self) { r in
                            let on = model.rating == r
                            Button { model.rate(r) } label: {
                                Text(RaceFormat.rating(r))
                                    .font(.system(size: 12)).lineLimit(1).minimumScaleFactor(0.7)
                                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                                    .foregroundColor(on ? Theme.phos : Theme.ink)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? Theme.phos : Theme.line))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("rating.\(r.rawValue)")
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                    if let saved = model.savedMessage {
                        Text(saved).font(Theme.mono(10)).foregroundColor(Theme.phos)
                            .accessibilityIdentifier("ratingSaved")
                    }
                    if let error = model.saveError {
                        Text(error).font(.system(size: 12)).foregroundColor(Theme.danger)
                    }
                }

                HStack(spacing: 8) {
                    Button("FULL LOG") { showLog = true }
                        .buttonStyle(CTAButtonStyle(ghost: true))
                        .accessibilityIdentifier("fullLogButton")
                    ShareLink(item: model.logURL) { Text("SHARE LOG") }
                        .buttonStyle(CTAButtonStyle(ghost: true))
                    if let recording = model.recordingURL {
                        ShareLink(item: recording) { Text("SHARE RECORDING") }
                            .buttonStyle(CTAButtonStyle(ghost: true))
                            .accessibilityIdentifier("shareRecordingButton")
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.screen.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .statusBarScrim()
        .sheet(isPresented: $showLog) { CueLogView(log: model.log, fileURL: model.logURL) }
    }

    private var cueList: some View {
        VStack(spacing: 0) {
            let rows = model.cueRows
            if rows.isEmpty {
                Text("No cue showed on this run.").font(.system(size: 12)).foregroundColor(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                if i > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                cueRow(row)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }

    private func cueRow(_ row: ReviewModel.CueRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.marker).font(Theme.mono(11)).foregroundColor(Theme.muted).frame(width: 40, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                (Text(row.title).fontWeight(.semibold).foregroundColor(Theme.ink)
                    + Text(" · \(row.response)").foregroundColor(Theme.muted))
                    .font(.system(size: 12))
                if let outcome = row.outcome {
                    Text(outcome).font(.system(size: 12))
                        .foregroundColor(row.improved == false ? Theme.amber : Theme.phos)
                }
                if let r = row.rating {
                    Text("Rated: \(RaceFormat.rating(r).lowercased())").font(Theme.mono(10)).foregroundColor(Theme.muted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("cueRow")
        .contextMenu {
            ForEach(CueRating.allCases, id: \.self) { r in
                Button(RaceFormat.rating(r)) { model.rate(cue: row.id, r) }
            }
        }
    }
}

/// Split times as bars from the plan's time for the same stretch: amber
/// slower than plan, green faster; the dashed line is the plan.
struct SplitsChart: View {
    let splits: [ReviewModel.SplitBar]

    /// Points per bar: narrower the more splits there are (a marathon has 26).
    private var barWidth: CGFloat { max(4, min(16, 240 / CGFloat(max(splits.count, 1)) - 4)) }

    var body: some View {
        let values = splits.flatMap { [$0.time, $0.planTime] }
        let lo = (values.min() ?? 0) - 8, hi = (values.max() ?? 0) + 8
        Chart {
            ForEach(splits) { s in
                BarMark(x: .value("Split", Double(s.marker)),
                        yStart: .value("Plan", s.planTime),
                        // At least a sliver, as in the design, so a split on plan still shows.
                        yEnd: .value("Time", abs(s.time - s.planTime) < 0.6
                                     ? s.planTime + (s.slower ? 0.6 : -0.6) : s.time),
                        width: .fixed(barWidth))
                    .foregroundStyle(s.slower ? Theme.amber : Theme.phos)
            }
            ForEach(splits) { s in
                LineMark(x: .value("Split", Double(s.marker)), y: .value("Plan", s.planTime))
                    .interpolationMethod(.stepCenter)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .foregroundStyle(Theme.ink)
            }
        }
        .chartYScale(domain: lo...hi)
        .chartXScale(domain: 0.5...(Double(splits.count) + 0.5))
        .chartXAxis {
            AxisMarks(values: splits.map { Double($0.marker) }) { _ in
                AxisValueLabel().font(Theme.mono(8)).foregroundStyle(Theme.muted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine().foregroundStyle(Theme.line)
                AxisValueLabel {
                    if let s = v.as(Double.self) { Text(RaceFormat.paceValue(perUnit: s)) }
                }
                .font(Theme.mono(8)).foregroundStyle(Theme.muted)
            }
        }
    }
}

#Preview("Review") {
    if let model = SampleData.review() {
        ReviewView(model: model).preferredColorScheme(.dark)
    } else {
        Text("no sample")
    }
}

#Preview("Splits chart") {
    SplitsChart(splits: [494, 476, 475, 478, 479, 477, 479, 519, 464, 478, 494, 458, 452].enumerated().map {
        ReviewModel.SplitBar(marker: $0.offset + 1, time: Double($0.element), planTime: 481)
    })
    .frame(height: 110).padding().background(Color.black)
}
