//  PlanEditorView.swift
//  The race plan screen (design: "Before the race"): name, distance and
//  target, pacing style, course file, heart rate zones, fuel, how much the
//  glasses should show, and how cues come onto them (segue and heads-ups,
//  each with a PREVIEW that loops a sample cue on the in-editor mirror and
//  the glasses until STOP). All checking is in PlanEditorModel; this lays it
//  out like the mockup and shows its messages.

import SwiftUI
import UniformTypeIdentifiers
import DragonEngine

struct PlanEditorView: View {
    @Bindable var model: PlanEditorModel
    /// PREVIEW's player: its frame is the in-editor mirror (the model starts and stops it).
    @ObservedObject var preview: SeguePreviewController = SeguePreviewController(hud: nil)
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
        ScrollViewReader { scroller in
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

                segueSection


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
        .onAppear {
            #if DEBUG
            // -planEditorSegues (screenshots): straight to the segue section; with -seguePreview, playing Slide.
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-planEditorSegues") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    scroller.scrollTo("segueSection", anchor: .top)
                    if args.contains("-seguePreview") {
                        model.segue = .slide
                        model.previewSegue()
                    }
                }
            }
            #endif
        }
        }
        .onDisappear { model.stopPreview() }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Button("SAVE") { focused = false; model.stopPreview(); if let p = save(model) { onSave(p) } }
                    .buttonStyle(CTAButtonStyle(ghost: true))
                    .accessibilityIdentifier("savePlanButton")
                Button("START RUN") { focused = false; model.stopPreview(); if let p = save(model) { onStart(p) } }
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

    // MARK: Segue and heads-ups

    private var segueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isPreviewing {
                VStack(alignment: .leading, spacing: 6) {
                    HUDPanel(frame: preview.frame)
                        .accessibilityIdentifier("seguePreviewMirror")
                    HStack {
                        Text("PREVIEW · \(model.previewing ?? "")")
                            .font(Theme.mono(11)).foregroundColor(Theme.amber)
                            .accessibilityIdentifier("seguePreviewLabel")
                        Spacer()
                        Button("STOP") { model.stopPreview() }
                            .font(Theme.mono(11, weight: .semibold)).foregroundColor(Theme.amber)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.amber.opacity(0.5)))
                            .accessibilityIdentifier("seguePreviewStop")
                    }
                }
            }

            Field(label: "Cues come on") {
                Segmented(options: Segue.allCases.map { (Self.segueLabel($0), $0) }, selection: $model.segue,
                          idPrefix: "segue")
                HStack(alignment: .top) {
                    Text(Self.segueNote(model.segue))
                        .font(.system(size: 12)).foregroundColor(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    previewButton("segue") { model.previewSegue() }
                }
            }

            Field(label: "Heads-up" + (model.headsUp.isEmpty ? " · off" : "")) {
                ForEach(HeadsUpKind.allCases, id: \.self) { kind in
                    let usable = kind != .watchTap || model.watchTapAvailable
                    HStack(spacing: 10) {
                        Toggle(isOn: Binding(get: { model.isOn(kind) }, set: { model.setHeadsUp(kind, on: $0) })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Self.headsUpLabel(kind)).font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(usable ? Theme.ink : Theme.muted)
                                Text(Self.headsUpNote(kind)).font(.system(size: 11)).foregroundColor(Theme.muted)
                            }
                        }
                        .tint(Theme.phos)
                        .disabled(!usable && !model.isOn(kind))
                        .accessibilityIdentifier("headsUp.\(kind.rawValue)")
                        previewButton("headsUp.\(kind.rawValue)") { model.previewHeadsUp(kind) }
                            .disabled(!usable)
                            .opacity(usable ? 1 : 0.35)
                    }
                }
                if let note = model.watchTapNote {
                    Text(note).font(.system(size: 12)).foregroundColor(Theme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("watchTapNote")
                }
                Text("A heads-up warns a moment before a cue you can see coming (a split, a hill, a gel). Safety cues always cut straight in.")
                    .font(.system(size: 12)).foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .id("segueSection")
    }

    private func previewButton(_ id: String, _ action: @escaping () -> Void) -> some View {
        Button("PREVIEW", action: action)
            .font(Theme.mono(11, weight: .semibold)).foregroundColor(Theme.phos)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
            .buttonStyle(.plain)
            .accessibilityIdentifier("preview.\(id)")
    }

    static func segueLabel(_ segue: Segue) -> String {
        switch segue {
        case .instant: return "Instant"
        case .fade: return "Fade"
        case .slide: return "Slide"
        case .glow: return "Glow"
        }
    }

    static func segueNote(_ segue: Segue) -> String {
        switch segue {
        case .instant: return "Cues cut in and out in one frame."
        case .fade: return "Cues fade in over about 0.3 s and out over 0.5 s."
        case .slide: return "Cues rise a few pixels into place as they fade in, and sink as they leave."
        case .glow: return "The whole display brightens as a cue arrives and dims as it leaves."
        }
    }

    static func headsUpLabel(_ kind: HeadsUpKind) -> String {
        switch kind {
        case .dotPulse: return "Dot pulse"
        case .edgeTick: return "Edge tick"
        case .ledBlink: return "LED blink"
        case .watchTap: return "Watch tap"
        }
    }

    static func headsUpNote(_ kind: HeadsUpKind) -> String {
        switch kind {
        case .dotPulse: return "The status dot brightens"
        case .edgeTick: return "A mark fills at the bottom edge"
        case .ledBlink: return "The glasses' green LED blinks"
        case .watchTap: return "A tap on the wrist; stronger for critical cues"
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
