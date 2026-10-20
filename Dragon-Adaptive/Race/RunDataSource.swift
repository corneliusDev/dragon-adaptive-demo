//  RunDataSource.swift
//  Where a live run's data comes from, as the runner picks it on the live
//  run screen: the synthetic race made from the plan, or the phone's own
//  sensors (GPS, motion, pedometer, barometer). The choice is remembered.
//  Synthetic is the default in the simulator (no real run to measure),
//  phone sensors on a device.

import Foundation

enum RunDataSource: String, CaseIterable, Codable {
    case synthetic
    case phone

    var title: String {
        switch self {
        case .synthetic: return "Synthetic"
        case .phone: return "Phone sensors"
        }
    }

    /// The choice before the runner has made one.
    static var platformDefault: RunDataSource {
        #if targetEnvironment(simulator)
        return .synthetic
        #else
        return .phone
        #endif
    }
}

/// The remembered choice: in UserDefaults normally, in memory for tests.
final class RunSourcePreference {
    private let defaults: UserDefaults?
    private var stored: RunDataSource
    static let key = "runDataSource"

    private init(defaults: UserDefaults?, initial: RunDataSource) {
        self.defaults = defaults
        stored = initial
    }

    static var standard: RunSourcePreference {
        let d = UserDefaults.standard
        let saved = d.string(forKey: key).flatMap(RunDataSource.init(rawValue:))
        return RunSourcePreference(defaults: d, initial: saved ?? .platformDefault)
    }

    static func inMemory(_ source: RunDataSource) -> RunSourcePreference {
        RunSourcePreference(defaults: nil, initial: source)
    }

    var source: RunDataSource {
        get { stored }
        set {
            stored = newValue
            defaults?.set(newValue.rawValue, forKey: RunSourcePreference.key)
        }
    }
}
