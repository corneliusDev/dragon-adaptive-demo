//  SeguesView.swift
//  Debug menu, SEGUES: how cues come onto the glasses. The Segue picker and
//  the HeadsUp toggles, each with PREVIEW (the sample split appearing and
//  leaving in that style, looping on the mirror here and on the glasses when
//  connected, until STOP), and the SegueConfig sliders for tuning on real
//  glasses. Everything is saved (SegueSettingsStore) and the race engine
//  follows it. Part B moves the Segue / Heads-up pickers into the plan editor.

import SwiftUI
import DragonEngine

struct SeguesView: View {
    @ObservedObject var hud: HUDController
    @ObservedObject var store: SegueSettingsStore
    @StateObject private var preview: SeguePreviewController
    @Environment(\.dismiss) private var dismiss

    private let phos = Color(red: 57 / 255, green: 226 / 255, blue: 122 / 255)
    private let amber = Color(red: 1, green: 0.54, blue: 0.24)

    init(hud: HUDController) {
        self.hud = hud
        store = hud.segueSettings
        _preview = StateObject(wrappedValue: SeguePreviewController(hud: hud, haptics: hud.haptics))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("SEGUES").font(.system(size: 13, weight: .bold, design: .monospaced))
                    Spacer()
                    Button("DONE") { preview.stop(); dismiss() }
                        .font(.system(size: 12, design: .monospaced)).foregroundColor(phos)
                        .accessibilityIdentifier("seguesDone")
                }
                MirrorView(frame: preview.isPlaying ? preview.frame : hud.frame)
                    .accessibilityIdentifier("seguesMirror")
                HStack {
                    Text(preview.isPlaying ? "PREVIEW · \(preview.label)" : "LIVE")
                        .foregroundColor(preview.isPlaying ? amber : .gray)
                        .accessibilityIdentifier("seguesPreviewLabel")
                    Spacer()
                    if preview.isPlaying {
                        Button("STOP") { preview.stop() }.foregroundColor(amber)
                            .accessibilityIdentifier("seguesStop")
                    }
                }
                .font(.system(size: 11, design: .monospaced))

                section("SEGUE")
                HStack(spacing: 8) {
                    ForEach(Segue.allCases, id: \.self) { s in
                        seg(s.rawValue.uppercased(), store.segue == s) { store.segue = s }
                            .accessibilityIdentifier("segue.\(s.rawValue)")
                    }
                    Spacer()
                    previewButton("segue") {
                        preview.play(segue: store.segue, headsUp: store.headsUp, config: store.config)
                    }
                }

                section("HEADS-UP" + (store.headsUp.isEmpty ? " · OFF" : ""))
                ForEach(HeadsUpKind.allCases, id: \.self) { kind in
                    HStack {
                        Toggle(isOn: Binding(get: { store.headsUp.contains(kind) },
                                             set: { store.setHeadsUp(kind, on: $0) })) {
                            Text(title(kind)).font(.system(size: 12, design: .monospaced)).foregroundColor(.white)
                        }
                        .tint(phos)
                        .accessibilityIdentifier("headsUp.\(kind.rawValue)")
                        previewButton("headsUp.\(kind.rawValue)") {
                            preview.play(segue: store.segue, headsUp: [kind], config: store.config)
                        }
                    }
                }

                section("TUNING")
                slider("FADE IN", value: $store.settings.config.fadeIn, in: 0...1, unit: "s")
                stepper("FADE IN STEPS", value: $store.settings.config.fadeInSteps, in: 1...8)
                slider("FADE OUT", value: $store.settings.config.fadeOut, in: 0...1.5, unit: "s")
                stepper("FADE OUT STEPS", value: $store.settings.config.fadeOutSteps, in: 1...8)
                stepper("SLIDE PX", value: $store.settings.config.slideDistance, in: 0...16)
                slider("GLOW IN", value: $store.settings.config.glowIn, in: 0...1, unit: "s")
                slider("GLOW OUT", value: $store.settings.config.glowOut, in: 0...1.5, unit: "s")
                slider("HEADS-UP LEAD", value: $store.settings.config.headsUpLead, in: 0.5...3, unit: "s")
                slider("EDGE TICK", value: $store.settings.config.edgeTick, in: 0.25...2, unit: "s")
                slider("QUIET GAP", value: $store.settings.config.quietGap, in: 0...4, unit: "s")
                Toggle(isOn: $store.settings.partialRedraw) {
                    Text("REDRAW ONLY WHAT CHANGED").font(.system(size: 11, design: .monospaced)).foregroundColor(.gray)
                }
                .tint(phos)
                Button("RESET TO DEFAULTS") { store.reset() }
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(.gray)
                Text("Settings are saved and the race follows them. PREVIEW loops the mile split in that style on the mirror and the glasses.")
                    .font(.system(size: 11)).foregroundColor(Color(white: 0.4))
            }
            .padding(16)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            // -seguePreview: start the preview at once (screenshots).
            if ProcessInfo.processInfo.arguments.contains("-seguePreview") {
                preview.play(segue: store.segue, headsUp: store.headsUp, config: store.config)
            }
        }
        .onDisappear { preview.stop() }
    }

    private func title(_ kind: HeadsUpKind) -> String {
        switch kind {
        case .dotPulse: return "DOT PULSE"
        case .edgeTick: return "EDGE TICK"
        case .ledBlink: return "LED BLINK"
        case .watchTap: return "WATCH TAP"
        }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 10, design: .monospaced)).foregroundColor(.gray).padding(.top, 6)
    }

    private func previewButton(_ id: String, _ action: @escaping () -> Void) -> some View {
        Button("PREVIEW", action: action)
            .font(.system(size: 11, design: .monospaced)).foregroundColor(phos)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(white: 0.2)))
            .accessibilityIdentifier("preview.\(id)")
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f %@", value.wrappedValue, unit)).foregroundColor(amber)
            }
            .font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
            Slider(value: value, in: range, step: 0.05).accentColor(amber)
        }
    }

    private func stepper(_ title: String, value: Binding<Int>, in range: ClosedRange<Int>) -> some View {
        Stepper(value: value, in: range) {
            HStack {
                Text(title).foregroundColor(.gray)
                Spacer()
                Text("\(value.wrappedValue)").foregroundColor(amber)
            }
            .font(.system(size: 10, design: .monospaced))
        }
    }

    private func seg(_ title: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(on ? phos : .gray)
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color(white: 0.14) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(white: 0.2)))
    }
}
