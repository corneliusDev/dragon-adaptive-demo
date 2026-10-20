//  PlanEditorView.swift
//  The race plan screen (design: "Before the race"): name, distance and
//  target, pacing style, course file, heart rate zones, fuel, and how much
//  the glasses should show. All checking is in PlanEditorModel; this lays it
//  out like the mockup and shows its messages.

import SwiftUI
import UniformTypeIdentifiers
import DragonEngine

struct PlanEditorView: View {
    @Bindable var model: PlanEditorModel
    var onBack: () -> Void = {}
    /// Saved; the plan.
    var onSave: (SavedPlan) -> Void = { _ in }
    /// Saved, then start the run with it.
    var onStart: (SavedPlan) -> Void = { _ in }
    var onDelete: (() -> Void)?
    /// Saves the plan; returns nil and leaves the messages showing while there are problems.
    var save: (PlanEditorModel) -> SavedPlan? = { $0.makePlan() }
    /// Apple Health, for "Fill from Health".
    var health: HealthStoreProviding = SystemHealthStore.shared

    @State private var importing = false
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TopBar {
                    Button(action: onBack) {
                        Text("‹ RACES").font(Theme.mono(12, weight: .semibold)).foregroundColor(Theme.ink)
                    }
                    .accessibilityIdentifier("backButton")
                } trailing: {
                    HStack(spacing: 8) { BrandMark(); Text("RACE PLAN") }
                }
                Text(model.isNew ? "New race" : "Edit race").font(Theme.display(30)).textCase(.uppercase)
                    .foregroundColor(Theme.ink)

                Field(label: "Race") {
                    PlainInput(placeholder: "City Half Marathon", text: $model.name, id: "planName")
                        .focused($focused)
                }

                HStack(spacing: 8) {
                    Field(label: "Distance") {
                        Text(model.distanceMeters.map { RaceFormat.distance($0, unit: model.unit) } ?? "—")
                            .font(Theme.display(28)).monospacedDigit().foregroundColor(Theme.ink)
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                    Field(label: "Target") {
                        PlainInput(placeholder: "1:45:00", text: $model.target, keyboard: .numbersAndPunctuation,
                                   big: true, color: Theme.phos, id: "planTarget")
                            .focused($focused)
                    }
                }

                Field(label: "Race distance") {
                    Segmented(options: RaceDistance.allCases.map { ($0.label, $0) }, selection: $model.preset,
                              idPrefix: "distance")
                    if model.preset == .custom {
                        HStack {
                            PlainInput(placeholder: "26.2", text: $model.customDistance, keyboard: .decimalPad,
                                       id: "customDistance")
                                .focused($focused)
                            Text(RaceFormat.unitName(model.unit)).foregroundColor(Theme.muted)
                        }
                    }
                    Segmented(options: [("Miles", DistanceUnit.miles), ("Kilometres", .kilometers)],
                              selection: $model.unit, idPrefix: "unit")
                }

                Field(label: "Pacing") {
                    Segmented(options: PacingStyle.allCases.map { ($0.label, $0) }, selection: $model.pacingStyle,
                              idPrefix: "pacing")
                    switch model.pacingStyle {
                    case .even:
                        EmptyView()
                    case .negative:
                        HStack {
                            Text("Second half faster by").font(.system(size: 13)).foregroundColor(Theme.muted)
                            PlainInput(placeholder: "2", text: $model.negativePercent, keyboard: .decimalPad,
                                       id: "negativePercent")
                                .focused($focused).frame(width: 48)
                            Text("%").foregroundColor(Theme.muted)
                        }
                    case .perSplit:
                        PlainInput(placeholder: "8:05, 8:00, 7:55 …", text: $model.splitTimes,
                                   keyboard: .numbersAndPunctuation, id: "splitTimes")
                            .focused($focused)
                        Text("One time per split; scaled to add up to the target.")
                            .font(.system(size: 12)).foregroundColor(Theme.muted)
                    }
                    if let s = model.pacingSummary {
                        Text(s).font(.system(size: 12)).foregroundColor(Theme.muted)
                    }
                }

                courseField

                Field(label: "Heart rate zones · \(model.zonesFromHealth ? "from Health" : "typed in")") {
                    HStack(spacing: 10) {
                        zoneInput("Rest", $model.resting, "52", "zoneRest")
                        zoneInput("Threshold", $model.threshold, "172", "zoneThreshold")
                        zoneInput("Max", $model.maxHeartRate, "188", "zoneMax")
                    }
                    Text(model.healthNote ?? "Fill from Apple Health, or type them in. Leave empty to skip heart rate cues.")
                        .font(.system(size: 12)).foregroundColor(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("healthNote")
                    Button(model.readingHealth ? "READING HEALTH…" : "FILL FROM HEALTH") { model.fillFromHealth(health) }
                        .disabled(model.readingHealth)
                        .font(Theme.mono(11, weight: .semibold)).foregroundColor(Theme.phos).padding(.top, 2)
                        .accessibilityIdentifier("fillFromHealth")
                }

                Field(label: "Fuel") {
                    HStack {
                        Text("Gel every").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.ink)
                        PlainInput(placeholder: "45", text: $model.fuelMinutes, keyboard: .numberPad, id: "fuelMinutes")
                            .focused($focused).frame(width: 52)
                        Text("min").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.ink)
                        Spacer()
                    }
                }

                Field(label: "How much to show") {
                    Segmented(options: [("Minimal", DisplaySetting.minimal), ("Balanced", .balanced), ("Coach", .coach)],
                              selection: $model.display, idPrefix: "display")
                }

                if !model.problems.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.problems, id: \.self) { p in
                            Text(p).font(.system(size: 12)).foregroundColor(Theme.amber)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("planProblems")
                }

                if let onDelete, !model.isNew {
                    Button("DELETE PLAN", role: .destructive, action: onDelete)
                        .font(Theme.mono(11)).foregroundColor(Theme.danger)
                        .frame(maxWidth: .infinity).padding(.top, 6)
                        .accessibilityIdentifier("deletePlan")
                }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Button("SAVE") { focused = false; if let p = save(model) { onSave(p) } }
                    .buttonStyle(CTAButtonStyle(ghost: true))
                    .accessibilityIdentifier("savePlanButton")
                Button("START RUN") { focused = false; if let p = save(model) { onStart(p) } }
                    .buttonStyle(CTAButtonStyle())
                    .accessibilityIdentifier("startRunButton")
            }
            .disabled(!model.canSave)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Theme.screen)
        }
        .background(Theme.screen.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .statusBarScrim()
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = false }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.gpxTypes) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                model.importGPX(data, fileName: url.lastPathComponent)
            }
        }
    }

    static var gpxTypes: [UTType] {
        [UTType(filenameExtension: "gpx"), .xml].compactMap { $0 }
    }

    private var courseField: some View {
        Field(label: "Course") {
            Text(model.courseFileName ?? "No file: synthetic course")
                .font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.ink)
                .accessibilityIdentifier("courseFile")
            if let s = model.courseSummary {
                Text(s).font(.system(size: 12)).foregroundColor(Theme.muted)
            }
            if let notice = model.courseNotice {
                Text(notice).font(.system(size: 12)).foregroundColor(Theme.amber)
                    .accessibilityIdentifier("courseNotice")
            }
            if let error = model.importError {
                Text(error).font(.system(size: 12)).foregroundColor(Theme.danger)
            }
            HStack(spacing: 16) {
                Button(model.course == nil ? "IMPORT GPX" : "REPLACE") { importing = true }
                    .accessibilityIdentifier("importGPX")
                if model.course != nil {
                    Button("USE ITS DISTANCE") { model.useCourseDistance() }
                    Button("REMOVE") { model.removeCourse() }
                }
            }
            .font(Theme.mono(11, weight: .semibold)).foregroundColor(Theme.phos).padding(.top, 2)
        }
    }

    private func zoneInput(_ label: String, _ text: Binding<String>, _ placeholder: String, _ id: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Theme.mono(9)).foregroundColor(Theme.muted)
            PlainInput(placeholder: placeholder, text: text, keyboard: .numberPad, id: id)
                .focused($focused)
        }
    }
}

#Preview("New plan") {
    PlanEditorView(model: PlanEditorModel()).preferredColorScheme(.dark)
}

#Preview("City Half") {
    PlanEditorView(model: PlanEditorModel(plan: SampleData.halfMarathon), onDelete: {}).preferredColorScheme(.dark)
}
