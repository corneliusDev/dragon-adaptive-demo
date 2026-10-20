//  HeartSource.swift
//  Where a phone-sensor run's heart rate and wrist motion come from, as
//  picked on the live run screen before the start or in the Developer menu:
//  the Apple Watch, the synthetic Watch, or none. Remembered like the run's
//  data source. (A synthetic race brings its own synthetic heart rate; a
//  replay has the recorded one.) The Watch is the default on a device,
//  synthetic in the simulator; UI tests start with none unless
//  DRAGON_HEART_SOURCE says otherwise.

import Foundation

enum HeartSource: String, CaseIterable, Codable {
    case watch
    case synthetic
    case none

    var title: String {
        switch self {
        case .watch: return "Watch"
        case .synthetic: return "Synthetic"
        case .none: return "None"
        }
    }

    static var platformDefault: HeartSource {
        #if targetEnvironment(simulator)
        return .synthetic
        #else
        return .watch
        #endif
    }
}

/// The remembered choice: in UserDefaults normally, in memory for tests.
final class HeartSourcePreference {
    private let defaults: UserDefaults?
    private var stored: HeartSource
    static let key = "heartSource"

    private init(defaults: UserDefaults?, initial: HeartSource) {
        self.defaults = defaults
        stored = initial
    }

    static var standard: HeartSourcePreference {
        let d = UserDefaults.standard
        let saved = d.string(forKey: key).flatMap(HeartSource.init(rawValue:))
        return HeartSourcePreference(defaults: d, initial: saved ?? .platformDefault)
    }

    static func inMemory(_ source: HeartSource) -> HeartSourcePreference {
        HeartSourcePreference(defaults: nil, initial: source)
    }

    var source: HeartSource {
        get { stored }
        set {
            stored = newValue
            defaults?.set(newValue.rawValue, forKey: HeartSourcePreference.key)
        }
    }
}
