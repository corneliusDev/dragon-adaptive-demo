//  SyntheticVitalsSource.swift
//  Fake Apple Watch stream for testing without hardware.
//  Timer-driven wrapper around DragonEngine's pure SyntheticVitalsGenerator:
//  the generator decides what the watch would send, this class decides when.

import Foundation
import DragonEngine

final class SyntheticVitalsSource: VitalsSource {
    var onSample: ((VitalsSample) -> Void)?

    var speed: Double = 1               // simulated seconds per real second
    private(set) var generator: SyntheticVitalsGenerator

    private let tickInterval = 1.0 / 20.0
    private var timer: Timer?

    var isStreaming: Bool { timer != nil }

    init(seed: UInt64 = 42) {
        self.generator = SyntheticVitalsGenerator(seed: seed)
    }

    /// Starts or resumes the stream. Simulated time continues from where stop() left it.
    func start() {
        guard timer == nil else { return }

        let t = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if let sample = self.generator.advance(by: self.tickInterval * self.speed) {
                self.onSample?(sample)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func reset() {
        generator.reset()
    }
}
