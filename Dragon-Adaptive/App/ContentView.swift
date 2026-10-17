//  ContentView.swift
import SwiftUI

struct ContentView: View {
    @StateObject private var hud = HUDController()
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
            }
            .padding(16)
        }
        .background(Color.black.ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            Text("DRAGON").font(.system(size: 13, weight: .bold, design: .monospaced))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.25)))
            Text("ADAPTIVE HUD").font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
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
            Slider(value: $hud.motion, in: 0...100).accentColor(amber)
        }
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
            row("ATTENTION", hud.attnLabel, amber)
            Divider().background(Color(white: 0.15))
            row("CONTEXT", hud.ctxLabel, phos)
            Divider().background(Color(white: 0.15))
            row("FLYWHEEL", "\(hud.flywheel)  tuples", phos)
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
