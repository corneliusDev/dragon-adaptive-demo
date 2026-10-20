//  LiveRunView.swift
//  The live run screen (design: "During the run"): the glasses mirror, the
//  numbers behind it (elapsed, distance, heart rate, projected finish and
//  the gap to the target), what the engine is doing in plain words, the
//  latest cue it held back, and pause / end. Mostly for testing and for
//  anyone watching; the runner keeps the phone in a pocket.

import SwiftUI
import DragonEngine

struct LiveRunView: View {
    let model: LiveRunModel
    /// The glasses connection, for the status pill.
    var glassesConnected = false
    var onEnd: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TopBar {
                    HStack(spacing: 6) {
                        Circle().fill(glassesConnected ? Theme.phos : Color(white: 0.3)).frame(width: 7, height: 7)
                        Text("\(glassesConnected ? "Glasses" : "No glasses") · \(model.sourceName)")
                            .font(Theme.mono(11)).foregroundColor(Theme.muted)
                    }
                } trailing: {
                    Text(model.positionText).accessibilityIdentifier("livePosition")
                }
                HStack(spacing: 10) {
                    Text(model.plan.name).font(Theme.display(22)).textCase(.uppercase).foregroundColor(Theme.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Spacer()
                    // Race speed for the synthetic race.
                    Segmented(options: model.config.speeds.map { ("\(Int($0))×", $0) },
                              selection: Binding(get: { model.speed }, set: { model.speed = $0 }), idPrefix: "speed")
                        .frame(width: 104)
                }

                HUDPanel(frame: model.frame)

                HStack(spacing: 8) {
                    StatTile(label: "Elapsed", value: model.elapsedText, id: "liveElapsed")
                    StatTile(label: "Distance", value: model.distanceText, id: "liveDistance")
                    StatTile(label: "Heart", value: model.heartText, id: "liveHeart")
                }
                HStack(spacing: 8) {
                    StatTile(label: model.isFinished ? "Finish" : "Projected", value: model.projectedText,
                             color: model.isBehind ? Theme.amber : Theme.phos, id: "liveProjected")
                    StatTile(label: "Vs target", value: model.gapText,
                             color: model.isBehind ? Theme.amber : Theme.phos, id: "liveGap")
                }

                Field(label: "Engine") {
                    Text(model.status.headline).font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.ink)
                        .accessibilityIdentifier("engineStatus")
                    Text(model.status.detail).font(.system(size: 12)).foregroundColor(Theme.muted)
                    Text("\(model.cuesShown) cue\(model.cuesShown == 1 ? "" : "s") shown so far")
                        .font(.system(size: 12)).foregroundColor(Theme.muted)
                        .accessibilityIdentifier("liveCueCount")
                }
                Field(label: "Held back this \(model.unit == .miles ? "mile" : "km")") {
                    Text(model.heldBack ?? "Nothing held back")
                        .font(.system(size: 12)).foregroundColor(Theme.muted)
                }

                if model.isFinished {
                    Text("Across the line in \(RaceFormat.clock(model.finishTime ?? 0)). End the run to see the review.")
                        .font(.system(size: 13)).foregroundColor(Theme.phos)
                        .accessibilityIdentifier("finishedLabel")
                }
            }
            .padding(16)
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                if !model.hasStarted {
                    Button("START") { model.start() }
                        .buttonStyle(CTAButtonStyle())
                        .accessibilityIdentifier("startButton")
                } else {
                    Button(model.isRunning ? "PAUSE" : "RESUME") { model.togglePause() }
                        .buttonStyle(CTAButtonStyle(ghost: true))
                        .disabled(model.isFinished)
                        .accessibilityIdentifier("pauseButton")
                }
                Button("END", action: onEnd)
                    .buttonStyle(CTAButtonStyle(ghost: true))
                    .accessibilityIdentifier("endRunButton")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Theme.screen)
        }
        .background(Theme.screen.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .statusBarScrim()
    }
}

/// The live screen watching the glasses connection without redrawing the
/// whole screen for every HUDController update.
struct LiveRunScreen: View {
    let model: LiveRunModel
    @ObservedObject var hud: HUDController
    var onEnd: () -> Void = {}

    var body: some View {
        LiveRunView(model: model, glassesConnected: hud.connection.isConnected, onEnd: onEnd)
            // START RUN on the plan screen is the gun.
            .onAppear { if !model.hasStarted { model.start() } }
    }
}

#Preview("Mid-race") {
    LiveRunView(model: SampleData.liveRun(seconds: 2_400)).preferredColorScheme(.dark)
}

#Preview("Before the gun") {
    LiveRunView(model: SampleData.liveRun(seconds: 0, plan: SampleData.parkFiveK)).preferredColorScheme(.dark)
}
