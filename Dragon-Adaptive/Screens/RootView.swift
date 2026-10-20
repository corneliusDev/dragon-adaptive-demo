//  RootView.swift
//  The main flow: Home (plans, past runs, start) → Plan editor → Live run →
//  Review. One HUDController (glasses connection, the developer demos) is
//  shared by the whole app; while a run is live its frames go to the glasses
//  through it, and glasses gestures come back to the run.

import SwiftUI
import DragonEngine

extension HUDController {
    /// The app's one controller: the glasses session and the 20 Hz HUD loop;
    /// Watch-tap heads-ups go through the Watch link.
    static let shared: HUDController = {
        let hud = HUDController()
        hud.haptics = WatchHeadsUpHaptics(link: WatchLink.shared)
        return hud
    }()
}

/// The models of the screens on the navigation stack.
@Observable
final class Flow {
    var editor: PlanEditorModel?
    /// The plan editor's PREVIEW player (its mirror and the glasses).
    var preview: SeguePreviewController?
    var live: LiveRunModel?
    var review: ReviewModel?
}

struct RootView: View {
    enum Route: Hashable {
        case newPlan
        case editPlan(UUID)
        case live
        case review(UUID)
    }

    private let environment: AppEnvironment
    /// Not observed here: its 20 Hz updates redraw only the views that watch it.
    private let hud: HUDController
    @State private var home: HomeModel
    @State private var path: [Route] = []
    /// The models behind the pushed screens. A reference, so the navigation
    /// destinations (built once by SwiftUI) always read the current ones.
    @State private var flow = Flow()
    @State private var showDeveloper = false
    @State private var alert: String?

    init(environment: AppEnvironment = .current, hud: HUDController = .shared) {
        self.environment = environment
        self.hud = hud
        _home = State(initialValue: HomeModel(environment: environment))
        #if DEBUG
        _showDeveloper = State(initialValue: ProcessInfo.processInfo.arguments.contains("-watchDemo"))
        #endif
    }

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(model: home, hud: hud,
                     onNew: { openEditor(nil) },
                     onEdit: { openEditor($0) },
                     onStart: { start($0) },
                     onReview: { openReview($0) },
                     onDeveloper: { showDeveloper = true })
                .navigationDestination(for: Route.self, destination: destination)
        }
        .sheet(isPresented: $showDeveloper) {
            DeveloperView(hud: hud, recordings: environment.runs.recorded(),
                          onReplay: { record in
                              showDeveloper = false
                              replay(record)
                          },
                          heartSource: environment.heartSource)
        }
        .onAppear {
            #if DEBUG
            // -planEditorSegues (screenshots): open a new plan at its segue section.
            if ProcessInfo.processInfo.arguments.contains("-planEditorSegues"), path.isEmpty { openEditor(nil) }
            #endif
        }
        .alert(alert ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .newPlan, .editPlan:
            if let editor = flow.editor, let preview = flow.preview {
                PlanEditorView(model: editor, preview: preview,
                               onBack: { path.removeLast() },
                               onSave: { _ in home.reload(); path.removeLast() },
                               onStart: { plan in home.reload(); path.removeLast(); start(plan) },
                               onDelete: { deleteEditedPlan() },
                               save: { save($0) })
            }
        case .live:
            if let live = flow.live {
                LiveRunScreen(model: live, hud: hud, onEnd: { end(live) },
                              onSourceChange: { switchSource(of: live, to: $0) },
                              onHeartChange: { show(setup.switchHeart(of: live, to: $0)) })
            }
        case .review:
            if let review = flow.review {
                ReviewView(model: review, onDone: { home.reload(); path = [] })
            }
        }
    }

    private func openEditor(_ plan: SavedPlan?) {
        let preview = SeguePreviewController(hud: hud, haptics: hud.haptics)
        let defaults = hud.segueSettings.settings
        flow.preview = preview
        flow.editor = PlanEditorModel(plan: plan, segueDefaults: (defaults.segue, defaults.headsUp),
                                      segueConfig: defaults.config, watch: WatchLink.shared, previewer: preview)
        path.append(plan.map { .editPlan($0.id) } ?? .newPlan)
    }

    private func save(_ model: PlanEditorModel) -> SavedPlan? {
        do {
            return try model.save(to: environment.plans)
        } catch {
            alert = "Couldn't save the plan: \(error.localizedDescription)"
            return nil
        }
    }

    private func deleteEditedPlan() {
        if let id = flow.editor?.planID, let plan = home.plan(id) { home.delete(plan: plan) }
        path.removeLast()
    }

    private var setup: LiveRunSetup {
        var s = LiveRunSetup(environment: environment)
        s.segueConfig = hud.segueSettings.config
        return s
    }

    private func start(_ plan: SavedPlan) {
        show(setup.model(for: plan))
        path.append(.live)
    }

    /// The live run's frames go to the glasses, the glasses' gestures to the run.
    private func show(_ model: LiveRunModel) {
        model.onFrame = { [weak hud] frame in hud?.showRunFrame(frame) }
        model.haptics = hud.haptics
        hud.onAttention = { [weak model] event in model?.receive(event) }
        flow.live = model
    }

    private func switchSource(of model: LiveRunModel, to source: RunDataSource) {
        show(setup.switchSource(of: model, to: source))
    }

    /// A recorded real run, played through the live screen (Developer menu).
    private func replay(_ record: RunRecord) {
        do {
            guard let model = try setup.replay(record, store: environment.runs) else {
                alert = "That run has no recording."
                return
            }
            show(model)
            path = [.live]
        } catch {
            alert = "Couldn't open that run's recording: \(error.localizedDescription)"
        }
    }

    private func end(_ model: LiveRunModel) {
        hud.showRunFrame(nil)
        hud.onAttention = nil
        do {
            let record = try model.end(store: environment.runs)
            home.reload()
            flow.review = try ReviewModel(record: record, store: environment.runs)
            path = [.review(record.id)]
        } catch {
            alert = "Couldn't save the run: \(error.localizedDescription)"
            path = []
        }
        flow.live = nil
    }

    private func openReview(_ record: RunRecord) {
        do {
            flow.review = try ReviewModel(record: record, store: environment.runs)
            path.append(.review(record.id))
        } catch {
            alert = "Couldn't open that run's cue log: \(error.localizedDescription)"
        }
    }
}

#Preview("Main flow") {
    let env = AppEnvironment.temporary()
    try? env.plans.save(SampleData.halfMarathon)
    return RootView(environment: env)
}
