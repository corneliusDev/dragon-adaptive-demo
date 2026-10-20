//  AppEnvironment.swift
//  Where the app keeps plans and runs, and the UI test hooks. A normal launch
//  keeps plans and run records in Application Support, cue logs in
//  Documents/CueLogs (the folder CueLogStore has always used, which the
//  Files app can reach) and real runs' recordings in Documents/Recordings.
//  Launched with -uiTesting, everything goes in a fresh temporary folder so a
//  test starts from nothing, the environment variable DRAGON_TIME_SCALE
//  multiplies the synthetic race's speed (the 10x button then plays a 5K in
//  seconds), the run data source starts as synthetic unless
//  DRAGON_RUN_SOURCE says "phone", and a real run's heart source starts as
//  none unless DRAGON_HEART_SOURCE says "watch" or "synthetic".

import Foundation

struct AppEnvironment {
    let plans: PlanStore
    let runs: RunStore
    /// Extra speed on top of the 1x / 10x the runner picks (1 outside UI tests).
    let timeScale: Double
    /// Where the live run's data comes from (the runner's last choice).
    let runSource: RunSourcePreference
    /// Where a real run's heart rate comes from (the runner's last choice).
    let heartSource: HeartSourcePreference

    static let current = AppEnvironment.make(arguments: ProcessInfo.processInfo.arguments,
                                             environment: ProcessInfo.processInfo.environment)

    static func make(arguments: [String], environment: [String: String]) -> AppEnvironment {
        let fm = FileManager.default
        if arguments.contains("-uiTesting") {
            let root = fm.temporaryDirectory.appendingPathComponent("dragon-uitest", isDirectory: true)
            try? fm.removeItem(at: root)
            let scale = environment["DRAGON_TIME_SCALE"].flatMap(Double.init) ?? 1
            let source = environment["DRAGON_RUN_SOURCE"].flatMap(RunDataSource.init(rawValue:)) ?? .synthetic
            let heart = environment["DRAGON_HEART_SOURCE"].flatMap(HeartSource.init(rawValue:)) ?? HeartSource.none
            return AppEnvironment(root: root, cueLogs: root.appendingPathComponent("CueLogs"),
                                  recordings: root.appendingPathComponent("Recordings"), timeScale: max(1, scale),
                                  runSource: .inMemory(source), heartSource: .inMemory(heart))
        }
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dragon", isDirectory: true)
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return AppEnvironment(root: support, cueLogs: CueLogStore.documents.directory,
                              recordings: documents.appendingPathComponent("Recordings", isDirectory: true),
                              timeScale: 1, runSource: .standard, heartSource: .standard)
    }

    init(root: URL, cueLogs: URL, recordings: URL, timeScale: Double = 1,
         runSource: RunSourcePreference = .inMemory(.synthetic),
         heartSource: HeartSourcePreference = .inMemory(.none)) {
        plans = PlanStore(directory: root.appendingPathComponent("Plans", isDirectory: true))
        runs = RunStore(runs: root.appendingPathComponent("Runs", isDirectory: true), cueLogs: cueLogs,
                        recordings: recordings)
        self.timeScale = timeScale
        self.runSource = runSource
        self.heartSource = heartSource
    }

    /// A throwaway environment in a new temporary folder (tests, previews).
    static func temporary() -> AppEnvironment {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dragon-\(UUID().uuidString)")
        return AppEnvironment(root: root, cueLogs: root.appendingPathComponent("CueLogs"),
                              recordings: root.appendingPathComponent("Recordings"))
    }
}
