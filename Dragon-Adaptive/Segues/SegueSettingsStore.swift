//  SegueSettingsStore.swift
//  The runner's Segue and HeadsUp choices and the SegueConfig tuning,
//  persisted in UserDefaults (one JSON value) so they survive launches.
//  HUDController hands them to the RunEngine and keeps it in step when they
//  change. The developer screen's SEGUES section edits them. Each race plan
//  carries its own Segue and Heads-up choice (picked in the plan editor);
//  this store's are what a new plan starts with and what the developer
//  RACE path uses. The SegueConfig tuning stays here, app-wide.

import Foundation
import Combine
import DragonEngine

final class SegueSettingsStore: ObservableObject {
    /// What is saved.
    struct Settings: Codable, Equatable {
        var segue = Segue.default
        var headsUp = HeadsUpKind.defaultSetting
        var config = SegueConfig()
        /// Redraw only what changed on the glasses (FrameDiff); off sends every frame whole.
        var partialRedraw = true
    }

    static let key = "dragon.segueSettings"

    @Published var settings: Settings {
        didSet { if settings != oldValue { save() } }
    }

    var segue: Segue {
        get { settings.segue }
        set { settings.segue = newValue }
    }

    var headsUp: Set<HeadsUpKind> {
        get { settings.headsUp }
        set { settings.headsUp = newValue }
    }

    var config: SegueConfig {
        get { settings.config }
        set { settings.config = newValue }
    }

    private let defaults: UserDefaults

    /// The app's store (standard defaults); tests pass their own suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = saved
        } else {
            settings = Settings()
        }
    }

    func setHeadsUp(_ kind: HeadsUpKind, on: Bool) {
        if on { settings.headsUp.insert(kind) } else { settings.headsUp.remove(kind) }
    }

    /// Back to the documented defaults.
    func reset() {
        settings = Settings()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
