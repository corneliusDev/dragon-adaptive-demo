//  ScenarioSequenceTests.swift
//  The cycling and SOF demos, replayed through long seeded sessions — glances,
//  held looks, motion changes, pauses and three loops of the scenario clock —
//  must show the same cards, count the same flywheel, report the same
//  attention and draw the same frames as the engine did before the renderer
//  and the scripted trigger replaced its hand-written drawing and card logic.
//  The fixture was recorded from that engine (chunk 0's AdaptiveEngine).

import XCTest
import DragonEngine

final class ScenarioSequenceTests: XCTestCase {
    /// Small repeatable generator (the engine's SeededRNG is internal).
    private struct LCG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    /// Every change in (card, flywheel, attention, frame) over a 120 s session at 20 Hz.
    private func session(_ scenario: Scenario, seed: UInt64) -> [String] {
        let engine = AdaptiveEngine(scenario: scenario)
        var rng = LCG(state: seed)
        engine.running = true
        var nextLook = 2 + rng.next() * 6
        var nextMotion = 0.0
        var out: [String] = []
        var last = ""
        let step = 1.0 / 20.0
        var t = 0.0
        for i in 1...2400 {
            t += step
            if t >= nextMotion {
                engine.motion = (rng.next() * 100).rounded()
                engine.measuredHeartRate = rng.next() < 0.5 ? nil : 120 + Int(rng.next() * 60)
                nextMotion = t + 4 + rng.next() * 12
            }
            if t >= nextLook {
                engine.handle(rng.next() < 0.7 ? .glance : .dwell, at: t)
                nextLook = t + 1 + rng.next() * 9
            }
            engine.running = !(t >= 50 && t < 58)        // a pause mid-session
            let frame = engine.tick(dt: step, at: t)
            let now = "\(engine.active?.id ?? "-") f\(engine.flywheel) \(engine.attention.rawValue) \(frame.signature)"
            if now != last {
                out.append("\(i) \(now)")
                last = now
            }
        }
        return out
    }

    func testCyclingAndSOFSessionsMatchTheLegacyEngine() {
        var entries: [(name: String, value: String)] = []
        for scenario in Scenarios.all {
            for seed: UInt64 in [1, 2, 3, 4] {
                for (n, line) in session(scenario, seed: seed).enumerated() {
                    entries.append(("\(scenario.key).\(seed).\(n)", line))
                }
            }
        }
        Goldens.check(entries, against: "scenario-sessions.txt")
    }
}
