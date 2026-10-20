//  DeveloperView.swift
//  The Developer menu (the gear on the home screen): what used to be the
//  app's main screen. The legacy cycling / SOF scenario demos, the motion
//  slider and source (SLIDER / WATCH / RACE), LOOK / WAVE, the synthetic race
//  profile picker with 1x / 10x, the DISPLAY setting, the state overlay, the
//  cue log, course debug and the screen gallery. Same HUDController as the
//  main flow, so the glasses connection is shared.
import SwiftUI
import DragonEngine

struct DeveloperView: View {
    @ObservedObject var hud: HUDController
    @Environment(\.dismiss) private var dismiss
    @State private var showCourseDebug = false
    @State private var showGallery = false
    private let amber = Color(red: 1, green: 0.54, blue: 0.24)
    private let phos  = Color(red: 57/255, green: 226/255, blue: 122/255)
    private let bench = Color(red: 0.06, green: 0.08, blue: 0.075)

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                ConnectBar(hud: hud)
                MirrorView(frame: hud.frame).padding(14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.10)))
                motionControl
                scenarioControls
                lookButton
                telemetry
                Text("The engine decides what to surface and what to hide from motion + attention + context. Faster motion → fewer elements, bigger glyphs. Safety-critical context surfaces unprompted.")
                    .font(.system(size: 12)).foregroundColor(.gray).padding(.horizontal, 4)
                #if DEBUG
                HStack(spacing: 18) {
                    Button("COURSE DEBUG") { showCourseDebug = true }
                    Button("SCREEN GALLERY") { showGallery = true }
                        .accessibilityIdentifier("screenGalleryButton")
                }
                .font(.system(size: 11, design: .monospaced)).foregroundColor(.gray)
                #endif
            }
            .padding(16)
        }
        .background(Color.black.ignoresSafeArea())
        #if DEBUG
        .overlay(alignment: .bottom) {
            if hud.vitalsMode == .race && hud.showStateOverlay {
                RunStateDebugView(state: hud.raceState, targetTime: hud.raceTargetTime,
                                      decisions: hud.raceDecisions, budget: hud.raceBudget,
                                      situation: hud.raceSituation)
                    .padding(.horizontal, 12).padding(.bottom, 6)
                    .onTapGesture { hud.toggleStateOverlay() }
            }
        }
        #endif
        .sheet(isPresented: $showCourseDebug) { CourseDebugView() }
        .sheet(isPresented: $hud.showCueLog) {
            if let log = hud.raceLog {
                CueLogView(log: log, fileURL: hud.raceLogURL)
            }
        }
        #if DEBUG
        .sheet(isPresented: $showGallery, onDismiss: { hud.resumeLiveHUD() }) { ScreenGalleryView(hud: hud) }
        #endif
    }

    private var header: some View {
        HStack {
            Button("DONE") { dismiss() }
                .font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundColor(phos)
                .accessibilityIdentifier("developerDone")
            Text("DRAGON").font(.system(size: 13, weight: .bold, design: .monospaced))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.25)))
            Text("DEVELOPER").font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
            Spacer()
            Circle().fill(hud.connection.isConnected ? phos : Color(white: 0.3)).frame(width: 8, height: 8)
            Text(hud.connection.label).font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
        }
    }

    private var motionControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("MOTION / EXERTION").font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
                Spacer()
                Text(hud.bandLabel).font(.system(size: 10, design: .monospaced)).foregroundColor(amber)
            }
            if hud.vitalsMode == .race {
                // In a race the slider is the effort the capacity budget uses.
                Slider(value: raceEffort, in: 0...100).accentColor(amber)
                HStack {
                    Text(hud.effortOverride.map { "BUDGET EFFORT \(Int($0)) (SLIDER)" } ?? "BUDGET EFFORT: MEASURED")
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
                    Spacer()
                    if hud.effortOverride != nil {
                        Button("USE MEASURED") { hud.useMeasuredEffort() }
                            .font(.system(size: 10, design: .monospaced)).foregroundColor(phos)
                    }
                }
            } else {
                Slider(value: $hud.motion, in: 0...100).accentColor(amber)
                    .disabled(hud.vitalsMode != .manual)
            }
            HStack(spacing: 10) {
                Text("SOURCE").font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
                sourceSeg("SLIDER", .manual); sourceSeg("WATCH", .synthetic); sourceSeg("RACE", .race)
            }
            if hud.vitalsMode == .race {
                raceControls
            }
        }
    }

    /// The race's slider: shows the measured effort until dragged, then the override.
    private var raceEffort: Binding<Double> {
        Binding(get: { hud.effortOverride ?? hud.motion }, set: { hud.effortOverride = $0 })
    }

    /// Synthetic race: pick a profile and speed, play it, watch distance and HR advance.
    private var raceControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("SYNTHETIC RACE").font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
                Spacer()
                Menu {
                    ForEach(SyntheticProfile.pickerProfiles, id: \.name) { profile in
                        Button(profile.displayName) { hud.setRaceProfile(profile) }
                    }
                } label: {
                    Text(hud.raceProfile.displayName).font(.system(size: 11, design: .monospaced)).foregroundColor(phos)
                }
            }
            HStack(spacing: 10) {
                speedSeg("1×", 1); speedSeg("10×", 10)
                Spacer()
                Button(hud.racePlaying ? "⏸" : "▶") { hud.toggleRace() }
                    .font(.system(size: 13, design: .monospaced)).foregroundColor(hud.racePlaying ? amber : .white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 7).stroke(Color(white: 0.22)))
                Button("↻") { hud.resetRace() }
                    .font(.system(size: 13, design: .monospaced)).foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 7).stroke(Color(white: 0.22)))
            }
            Text(hud.raceLabel).font(.system(size: 12, design: .monospaced)).foregroundColor(amber)
            Button("CUE LOG") { hud.openCueLog() }
                .font(.system(size: 11, design: .monospaced)).foregroundColor(phos)
                .accessibilityIdentifier("cueLogButton")
            #if DEBUG
            HStack(spacing: 10) {
                Text("DISPLAY").font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
                displaySeg("MINIMAL", .minimal); displaySeg("BALANCED", .balanced); displaySeg("COACH", .coach)
            }
            Button(hud.showStateOverlay ? "HIDE STATE OVERLAY" : "SHOW STATE OVERLAY") { hud.toggleStateOverlay() }
                .font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
            #endif
        }
        .padding(.top, 4)
    }

    private func speedSeg(_ title: String, _ speed: Double) -> some View {
        Button(title) { hud.setRaceSpeed(speed) }
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(hud.raceSpeed == speed ? phos : .gray)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(hud.raceSpeed == speed ? Color(white: 0.14) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(white: 0.2)))
    }

    private func displaySeg(_ title: String, _ setting: DisplaySetting) -> some View {
        Button(title) { hud.displaySetting = setting }
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(hud.displaySetting == setting ? phos : .gray)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(hud.displaySetting == setting ? Color(white: 0.14) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(white: 0.2)))
    }

    private func sourceSeg(_ title: String, _ mode: VitalsMode) -> some View {
        Button(title) { hud.setVitalsMode(mode) }
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(hud.vitalsMode == mode ? phos : .gray)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(hud.vitalsMode == mode ? Color(white: 0.14) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(white: 0.2)))
    }

    private var scenarioControls: some View {
        HStack(spacing: 10) {
            seg("CYCLING / TRI", "tri"); seg("OPERATOR / SOF", "sof")
            Spacer()
            Button(hud.running ? "⏸" : "▶") { hud.toggleRun() }
                .font(.system(size: 13, design: .monospaced)).foregroundColor(hud.running ? amber : .white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 7).stroke(Color(white: 0.22)))
            Button("↻") { hud.reset() }
                .font(.system(size: 13, design: .monospaced)).foregroundColor(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 7).stroke(Color(white: 0.22)))
        }
    }

    private func seg(_ title: String, _ key: String) -> some View {
        Button(title) { hud.setScenario(key) }
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(hud.scenarioKey == key ? phos : .gray)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(hud.scenarioKey == key ? Color(white: 0.14) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(white: 0.2)))
    }

    private var lookButton: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SIMULATED GAZE").font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
            Text("◉ LOOK / WAVE")
                .font(.system(size: 14, weight: .semibold, design: .monospaced)).foregroundColor(amber)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.12, green: 0.08, blue: 0.04)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(amber.opacity(0.5)))
                .gesture(LongPressGesture(minimumDuration: 0.38).onEnded { _ in hud.dwell() })
                .simultaneousGesture(TapGesture().onEnded { hud.glance() })
            Text("Tap = glance · hold = dwell. On glasses this is the gesture sensor (gaze stand-in).")
                .font(.system(size: 11)).foregroundColor(Color(white: 0.4))
        }
    }

    private var telemetry: some View {
        VStack(spacing: 0) {
            row("VITALS", hud.vitalsLabel, amber)
            Divider().background(Color(white: 0.15))
            row("ATTENTION", hud.attnLabel, amber)
            Divider().background(Color(white: 0.15))
            row("CONTEXT", hud.ctxLabel, phos)
            Divider().background(Color(white: 0.15))
            if hud.vitalsMode == .race {
                // The cue log replaces the flywheel count in a race.
                row("CUE LOG", hud.raceLog.map { CueLogFormat.counts($0.summary) } ?? "0 shown · 0 held back", phos)
            } else {
                row("FLYWHEEL", "\(hud.flywheel)  tuples", phos)
            }
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).stroke(Color(white: 0.18)))
    }

    private func row(_ k: String, _ v: String, _ c: Color) -> some View {
        HStack {
            Text(k).font(.system(size: 10, design: .monospaced)).foregroundColor(.gray).frame(width: 96, alignment: .leading)
            Spacer()
            Text(v).font(.system(size: 12, design: .monospaced)).foregroundColor(c)
        }.padding(.horizontal, 14).padding(.vertical, 11)
    }
}

#Preview("Developer menu") {
    DeveloperView(hud: HUDController.shared).preferredColorScheme(.dark)
}
