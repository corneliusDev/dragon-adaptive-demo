//  WatchRunView.swift
//  The Watch screen, kept minimal: heart rate, elapsed time, the link to
//  the phone, and start / stop. Most runs never look at it: the phone
//  starts the workout and the glasses show the cues.

import SwiftUI
import DragonEngine

struct WatchRunView: View {
    @ObservedObject var manager: WorkoutManager

    private let phos = Color(red: 57/255, green: 226/255, blue: 122/255)
    private let amber = Color(red: 1, green: 0.54, blue: 0.24)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(manager.heartRate.map { "\(Int($0.rounded()))" } ?? "--")
                        .font(.system(size: 40, weight: .semibold, design: .rounded)).foregroundColor(phos)
                        .accessibilityIdentifier("watchHeartRate")
                    Text("BPM").font(.system(size: 12, design: .monospaced)).foregroundColor(.gray)
                }
                elapsed
                HStack(spacing: 5) {
                    Circle().fill(manager.linkText == "iPhone not reachable" ? Color(white: 0.35) : phos)
                        .frame(width: 6, height: 6)
                    Text(manager.linkText).font(.system(size: 11)).foregroundColor(.gray)
                        .accessibilityIdentifier("watchLink")
                }
                Text("\(manager.sent) sent\(manager.notSent > 0 ? " · \(manager.notSent) not sent" : "")\(manager.state.map { " · \($0.rawValue)" } ?? "")")
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
                if let error = manager.lastError {
                    Text(error).font(.system(size: 10)).foregroundColor(amber)
                }
                Button(manager.isActive ? "STOP" : "START") {
                    manager.isActive ? manager.end() : manager.start()
                }
                .tint(manager.isActive ? amber : phos)
                .accessibilityIdentifier("watchStartStop")
                #if DEBUG
                Toggle("Synthetic HR", isOn: $manager.syntheticHR)
                    .font(.system(size: 12))
                    .disabled(manager.isActive)
                #endif
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { manager.activate() }
    }

    /// Elapsed time, ticking while the workout runs.
    private var elapsed: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = manager.startDate.map { (manager.endDate ?? context.date).timeIntervalSince($0) } ?? 0
            Text(Self.clock(max(0, seconds)))
                .font(.system(size: 20, weight: .medium, design: .monospaced)).foregroundColor(.white)
        }
    }

    static func clock(_ s: TimeInterval) -> String {
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }
}
