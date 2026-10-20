//  HomeView.swift
//  The main screen: glasses connection, the saved race plans (start, edit,
//  duplicate, delete), a new plan, and past runs to review. The gear opens
//  the Developer menu (the old demo controls).

import SwiftUI
import DragonEngine

struct HomeView: View {
    let model: HomeModel
    let hud: HUDController
    var onNew: () -> Void = {}
    var onEdit: (SavedPlan) -> Void = { _ in }
    var onStart: (SavedPlan) -> Void = { _ in }
    var onReview: (RunRecord) -> Void = { _ in }
    var onDeveloper: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TopBar {
                    BrandMark()
                } trailing: {
                    HStack(spacing: 14) {
                        Text("RACES")
                        Button(action: onDeveloper) {
                            Image(systemName: "gearshape").font(.system(size: 16)).foregroundColor(Theme.muted)
                        }
                        .accessibilityLabel("Developer menu")
                        .accessibilityIdentifier("developerButton")
                    }
                }
                GlassesRow(hud: hud)
                Text("Your races").font(Theme.display(30)).textCase(.uppercase).foregroundColor(Theme.ink)

                Button("+ NEW RACE", action: onNew)
                    .buttonStyle(CTAButtonStyle())
                    .accessibilityIdentifier("newRaceButton")

                if model.plans.isEmpty {
                    Text("No plans yet. Set a distance, a target and how much the glasses should say.")
                        .font(.system(size: 13)).foregroundColor(Theme.muted)
                }
                ForEach(model.plans) { plan in
                    planCard(plan)
                }

                Text("PAST RUNS").font(Theme.mono(10)).tracking(1).foregroundColor(Theme.muted).padding(.top, 8)
                if model.runs.isEmpty {
                    Text("Runs you finish or end show up here with their review.")
                        .font(.system(size: 13)).foregroundColor(Theme.muted)
                }
                ForEach(model.runs) { run in
                    runRow(run)
                }
            }
            .padding(16)
        }
        .background(Theme.screen.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .statusBarScrim()
    }

    private func planCard(_ plan: SavedPlan) -> some View {
        Field(label: plan.courseFileName.map { "Race · \($0)" } ?? "Race") {
            Button { onEdit(plan) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(plan.name).font(.system(size: 16, weight: .semibold)).foregroundColor(Theme.ink)
                    Text(plan.summary).font(Theme.mono(12)).foregroundColor(Theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("plan.\(plan.name)")
            HStack(spacing: 8) {
                Button("EDIT") { onEdit(plan) }.buttonStyle(CTAButtonStyle(ghost: true))
                Button("START") { onStart(plan) }.buttonStyle(CTAButtonStyle())
                    .accessibilityIdentifier("start.\(plan.name)")
            }
            .padding(.top, 4)
        }
        .contextMenu {
            Button("Edit") { onEdit(plan) }
            Button("Duplicate") { model.duplicate(plan) }
            Button("Delete", role: .destructive) { model.delete(plan: plan) }
        }
    }

    private func runRow(_ run: RunRecord) -> some View {
        Button { onReview(run) } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.plan.name).font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.ink)
                    Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(Theme.mono(11)).foregroundColor(Theme.muted)
                }
                Spacer()
                let beat = (run.finishTime ?? .infinity) <= run.plan.targetTime
                Text(run.resultText).font(Theme.display(22)).monospacedDigit()
                    .foregroundColor(run.finished ? (beat ? Theme.phos : Theme.amber) : Theme.muted)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("run.\(run.plan.name)")
        .contextMenu {
            Button("Delete", role: .destructive) { model.delete(run: run) }
        }
    }
}

/// Glasses connection: a status dot and the connect button, kept reachable
/// from the main flow. Observes the controller on its own, so the 20 Hz
/// updates redraw only this row.
struct GlassesRow: View {
    @ObservedObject var hud: HUDController

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(hud.connection.isConnected ? Theme.phos : Color(white: 0.3)).frame(width: 7, height: 7)
            Text("Glasses · \(hud.connection.label)").font(Theme.mono(11)).foregroundColor(Theme.muted)
                .lineLimit(1).minimumScaleFactor(0.7)
            Spacer()
            Button(hud.connection.isConnected ? "DISCONNECT" : "CONNECT") {
                hud.connection.isConnected ? hud.disconnect() : hud.connect()
            }
            .font(Theme.mono(11, weight: .semibold))
            .foregroundColor(hud.connection.isConnected ? Theme.danger : Theme.phos)
            .accessibilityIdentifier("connectGlasses")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }
}

#Preview("Home") {
    let env = AppEnvironment.temporary()
    try? env.plans.save(SampleData.halfMarathon)
    try? env.plans.save(SampleData.parkFiveK)
    _ = SampleData.finishedRun(in: env)
    return NavigationStack {
        HomeView(model: HomeModel(environment: env), hud: HUDController.shared)
    }
    .preferredColorScheme(.dark)
}
