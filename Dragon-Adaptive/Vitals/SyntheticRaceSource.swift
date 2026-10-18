//  SyntheticRaceSource.swift
//  A whole synthetic race (GPS + watch) for testing without going outside.
//  Timer-driven wrapper around DragonEngine's pure SyntheticRun: the run
//  decides what the phone and watch would send, this class decides when.
//  `speed` plays it faster than real time (10x = ten race seconds per second).

import Foundation
import DragonEngine

final class SyntheticRaceSource: LocationSource {
    var onSample: ((LocationSample) -> Void)?
    var onVitals: ((VitalsSample) -> Void)?

    var speed: Double = 1               // simulated seconds per real second
    let seed: UInt64
    private(set) var run: SyntheticRun

    private let tickInterval = 1.0 / 20.0
    private var timer: Timer?

    var isStreaming: Bool { timer != nil }
    var profile: SyntheticProfile { run.profile }

    init(profile: SyntheticProfile = .designWalkthrough, seed: UInt64 = 42) {
        self.seed = seed
        self.run = SyntheticRun(profile: profile, seed: seed)
    }

    /// Starts or resumes the race from where stop() left it.
    func start() {
        guard timer == nil else { return }

        let t = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.step(by: self.tickInterval * self.speed)
            if self.run.isFinished { self.stop() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Back to the start line, optionally with a different profile.
    func reset(profile: SyntheticProfile? = nil) {
        stop()
        run = SyntheticRun(profile: profile ?? run.profile, seed: seed)
    }

    /// Advances race time by dt seconds and delivers what was sent meanwhile.
    func step(by dt: TimeInterval) {
        for event in run.advance(by: dt) {
            switch event {
            case .location(let fix): onSample?(fix)
            case .vitals(let sample): onVitals?(sample)
            case .attention: break
            }
        }
    }
}

extension SyntheticProfile {
    /// Picker label. Engine values are metres; miles/km formatting happens here.
    var displayName: String {
        switch self {
        case .onPlan: return "On plan"
        case .slowFade(let from): return String(format: "Slow fade from mi %.0f", from / DistanceUnit.metersPerMile)
        case .tooHot: return "Too hot"
        case .hilly: return "Hilly"
        case .gpsDropout(let at, let duration): return String(format: "GPS dropout at %.0f km for %.0f s", at / 1000, duration)
        case .designWalkthrough: return "Design walkthrough (1:45 half)"
        }
    }
}
