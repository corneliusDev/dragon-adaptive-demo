//  AppEnvironment.swift
//  Where the app keeps plans and runs, and the UI test hooks. A normal launch
//  keeps plans and run records in Application Support and cue logs in
//  Documents/CueLogs (the folder CueLogStore has always used, which the
//  Files app can reach). Launched with -uiTesting, everything goes in a fresh
//  temporary folder so a test starts from nothing, and the environment
//  variable DRAGON_TIME_SCALE multiplies the synthetic race's speed (the
//  10x button then plays a 5K in seconds).

import Foundation

struct AppEnvironment {
    let plans: PlanStore
    let runs: RunStore
    /// Extra speed on top of the 1x / 10x the runner picks (1 outside UI tests).
    let timeScale: Double

    static let current = AppEnvironment.make(arguments: ProcessInfo.processInfo.arguments,
                                             environment: ProcessInfo.processInfo.environment)

    static func make(arguments: [String], environment: [String: String]) -> AppEnvironment {
        let fm = FileManager.default
        if arguments.contains("-uiTesting") {
            let root = fm.temporaryDirectory.appendingPathComponent("dragon-uitest", isDirectory: true)
            try? fm.removeItem(at: root)
            let scale = environment["DRAGON_TIME_SCALE"].flatMap(Double.init) ?? 1
            return AppEnvironment(root: root, cueLogs: root.appendingPathComponent("CueLogs"), timeScale: max(1, scale))
        }
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dragon", isDirectory: true)
        return AppEnvironment(root: support, cueLogs: CueLogStore.documents.directory, timeScale: 1)
    }

    init(root: URL, cueLogs: URL, timeScale: Double = 1) {
        plans = PlanStore(directory: root.appendingPathComponent("Plans", isDirectory: true))
        runs = RunStore(runs: root.appendingPathComponent("Runs", isDirectory: true), cueLogs: cueLogs)
        self.timeScale = timeScale
    }

    /// A throwaway environment in a new temporary folder (tests, previews).
    static func temporary() -> AppEnvironment {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dragon-\(UUID().uuidString)")
        return AppEnvironment(root: root, cueLogs: root.appendingPathComponent("CueLogs"))
    }
}
