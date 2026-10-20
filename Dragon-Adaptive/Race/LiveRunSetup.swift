//  LiveRunSetup.swift
//  Builds the live run for a plan from the chosen data source, and switches
//  source on the live screen: the runner's choice is remembered, and moving
//  to synthetic data (say, when location is off) gives a race that runs at
//  once, so the app stays usable without any permission. Replays of a real
//  run's recording come from here too (the Developer menu).

import Foundation
import DragonEngine

struct LiveRunSetup {
    let timeScale: Double
    let preference: RunSourcePreference
    /// Where a real run's heart rate comes from (the Watch, synthetic, none).
    let heart: HeartSourcePreference
    /// The phone's sensors for a new real run, with the heart source picked (fakes in tests).
    var sensors: (HeartSource) -> PhoneSensorRun

    init(environment: AppEnvironment,
         heartSensors: @escaping (HeartSource) -> PhoneSensorRun = { PhoneSensorRun.system(heart: $0) }) {
        timeScale = environment.timeScale
        preference = environment.runSource
        heart = environment.heartSource
        sensors = heartSensors
    }

    /// Sensors that don't depend on the heart source (tests).
    init(environment: AppEnvironment, sensors: @escaping () -> PhoneSensorRun) {
        self.init(environment: environment, heartSensors: { _ in sensors() })
    }

    /// A live run of `plan` from the remembered source (not started).
    func model(for plan: SavedPlan) -> LiveRunModel {
        model(for: plan, source: preference.source)
    }

    func model(for plan: SavedPlan, source: RunDataSource) -> LiveRunModel {
        switch source {
        case .synthetic: return LiveRunModel(plan: plan, timeScale: timeScale)
        case .phone: return LiveRunModel(plan: plan, feed: .phone(sensors(heart.source)), timeScale: timeScale)
        }
    }

    /// The runner picked `source` on the live screen: remembered, and a new
    /// run made from it. The run it replaces is stopped (nothing saved). A
    /// synthetic race starts straight away, as it does from the plan screen;
    /// a real run waits for START.
    func switchSource(of current: LiveRunModel, to source: RunDataSource, timer: Bool = true) -> LiveRunModel {
        preference.source = source
        current.pause()
        current.sensors?.stop()
        let next = model(for: current.plan, source: source)
        if source == .synthetic { next.start(timer: timer) }
        return next
    }

    /// The runner picked another heart source before a real run's start:
    /// remembered, and the not-yet-started run rebuilt with it.
    func switchHeart(of current: LiveRunModel, to source: HeartSource) -> LiveRunModel {
        heart.source = source
        guard current.kind == .phone, !current.hasStarted else { return current }
        current.sensors?.stop()
        return model(for: current.plan, source: .phone)
    }

    /// A replay of a recorded run, on the run's own plan and settings.
    func replay(_ record: RunRecord, store: RunStore) throws -> LiveRunModel? {
        guard let recording = try store.recording(for: record) else { return nil }
        let label = "\(record.plan.name), \(record.startedAt.formatted(date: .abbreviated, time: .shortened))"
        return LiveRunModel(plan: record.plan, feed: .replay(recording, label: label), timeScale: timeScale)
    }
}
