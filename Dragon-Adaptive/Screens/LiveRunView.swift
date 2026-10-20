//  LiveRunView.swift
//  The live run screen (design: "During the run"): the glasses mirror, the
//  numbers behind it (elapsed, distance, heart rate, projected finish and
//  the gap to the target), what the engine is doing in plain words, the
//  latest cue it held back, and pause / end. Mostly for testing and for
//  anyone watching; the runner keeps the phone in a pocket.
//
//  Above the mirror, the run's data source: Synthetic or Phone sensors
//  (until a real run starts). With phone sensors, before the start, the
//  sensor panel explains each permission before the system asks, and says
//  plainly when location is off (with a way back to synthetic data); under
//  it, where heart rate comes from: the Watch, synthetic, or none. Ending
//  the workout on the Watch ends the run here too.

import SwiftUI
import UIKit
import DragonEngine

struct LiveRunView: View {
    let model: LiveRunModel
    /// The glasses connection, for the status pill.
    var glassesConnected = false
    var onEnd: () -> Void = {}
    /// The runner picked another data source; nil hides the picker.
    var onSourceChange: ((RunDataSource) -> Void)?
    /// The runner picked another heart source (phone runs, before the start); nil hides the picker.
    var onHeartChange: ((HeartSource) -> Void)?

    /// The picker shows until a real run starts (a synthetic one can be swapped any time).
    private var showsSourcePicker: Bool {
        guard onSourceChange != nil else { return false }
        switch model.kind {
        case .synthetic: return true
        case .phone: return !model.hasStarted
        case .replay: return false
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TopBar {
                    HStack(spacing: 6) {
                        Circle().fill(glassesConnected ? Theme.phos : Color(white: 0.3)).frame(width: 7, height: 7)
                        Text("\(glassesConnected ? "Glasses" : "No glasses")\(model.heartSource == .watch ? " · Watch" : "") · \(model.sourceName)")
                            .font(Theme.mono(11)).foregroundColor(Theme.muted)
                    }
                } trailing: {
                    Text(model.positionText).accessibilityIdentifier("livePosition")
                }
                HStack(spacing: 10) {
                    Text(model.plan.name).font(Theme.display(22)).textCase(.uppercase).foregroundColor(Theme.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Spacer()
                    // Race speed for the synthetic race or a replay.
                    if model.hasSpeeds {
                        Segmented(options: model.config.speeds.map { ("\(Int($0))×", $0) },
                                  selection: Binding(get: { model.speed }, set: { model.speed = $0 }), idPrefix: "speed")
                            .frame(width: 104)
                    }
                }

                if showsSourcePicker, let onSourceChange {
                    Segmented(options: RunDataSource.allCases.map { ($0.title, $0) },
                              selection: Binding(get: { model.kind == .phone ? .phone : .synthetic },
                                                 set: { if $0 != (model.kind == .phone ? .phone : .synthetic) { onSourceChange($0) } }),
                              idPrefix: "source")
                }

                if model.kind == .phone, !model.hasStarted, let permissions = model.permissions {
                    PhoneSensorsPanel(permissions: permissions,
                                      onUseSynthetic: onSourceChange.map { change in { change(.synthetic) } })
                }

                if model.kind == .phone, !model.hasStarted, let onHeartChange, let heart = model.heartSource {
                    Field(label: "Heart rate from") {
                        Segmented(options: HeartSource.allCases.map { ($0.title, $0) },
                                  selection: Binding(get: { heart }, set: { if $0 != heart { onHeartChange($0) } }),
                                  idPrefix: "heart")
                        Text(HeartSource.explanation(heart)).font(.system(size: 12)).foregroundColor(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
                if let sensors = model.sensorText {
                    Field(label: "Sensors") {
                        Text(sensors).font(.system(size: 12)).foregroundColor(Theme.muted)
                            .accessibilityIdentifier("liveSensors")
                        if let note = model.permissions?.motionNote {
                            Text(note).font(.system(size: 12)).foregroundColor(Theme.muted)
                        }
                    }
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
    var onSourceChange: ((RunDataSource) -> Void)?
    var onHeartChange: ((HeartSource) -> Void)?

    var body: some View {
        LiveRunView(model: model, glassesConnected: hud.connection.isConnected, onEnd: onEnd,
                    onSourceChange: onSourceChange, onHeartChange: onHeartChange)
            // Ending the workout on the Watch ends the run.
            .onChange(of: model.endedOnWatch) { _, ended in if ended { onEnd() } }
            .onAppear {
                // START RUN on the plan screen is the gun for a synthetic race or a
                // replay; a real run waits for START (and its permissions).
                if model.kind == .phone {
                    model.permissions?.prepare()
                } else if !model.hasStarted {
                    model.start()
                }
            }
    }
}

extension HeartSource {
    /// One line under the picker on what this choice does.
    static func explanation(_ source: HeartSource) -> String {
        switch source {
        case .watch: return "START opens Dragon on the Apple Watch and starts a running workout there; its heart rate and wrist motion come over every second or so. END on either ends both."
        case .synthetic: return "A synthetic Watch: made-up heart rate and wrist motion, for trying heart-rate cues without a Watch."
        case .none: return "No heart rate: heart-rate cues stay off; effort comes from the phone's motion."
        }
    }
}

/// Phone sensors before the start: what's allowed, the explanation for the
/// next permission (before the system asks), and what to do when location is off.
struct PhoneSensorsPanel: View {
    let permissions: SensorPermissions
    /// Switch to synthetic data; nil hides the button.
    var onUseSynthetic: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let explanation = permissions.explanation {
                Text(explanation.title).font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.ink)
                    .accessibilityIdentifier("permissionTitle")
                Text(explanation.body).font(.system(size: 13)).foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(explanation.allow) { permissions.allow() }
                        .buttonStyle(CTAButtonStyle())
                        .accessibilityIdentifier("permissionAllow")
                    Button("NOT NOW") { permissions.skip() }
                        .buttonStyle(CTAButtonStyle(ghost: true))
                        .accessibilityIdentifier("permissionSkip")
                }
            } else if let problem = permissions.locationProblem {
                Text("Phone sensors can't run").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.amber)
                Text(problem).font(.system(size: 13)).foregroundColor(Theme.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("locationProblem")
                HStack(spacing: 8) {
                    if let onUseSynthetic {
                        Button("USE SYNTHETIC", action: onUseSynthetic)
                            .buttonStyle(CTAButtonStyle())
                            .accessibilityIdentifier("useSyntheticButton")
                    }
                    if permissions.location == .denied, let url = URL(string: UIApplication.openSettingsURLString) {
                        Button("OPEN SETTINGS") { UIApplication.shared.open(url) }
                            .buttonStyle(CTAButtonStyle(ghost: true))
                    }
                }
            } else {
                Text(permissions.canRun ? "Ready: GPS, and the phone's motion sensors where it has them. Put the phone in a pocket and tap START."
                                        : "Location hasn't been allowed yet. Tap START to be asked.")
                    .font(.system(size: 13)).foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sensorsReady")
                if let note = permissions.motionNote {
                    Text(note).font(.system(size: 12)).foregroundColor(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }
}

#Preview("Mid-race") {
    LiveRunView(model: SampleData.liveRun(seconds: 2_400)).preferredColorScheme(.dark)
}

#Preview("Before the gun") {
    LiveRunView(model: SampleData.liveRun(seconds: 0, plan: SampleData.parkFiveK)).preferredColorScheme(.dark)
}
