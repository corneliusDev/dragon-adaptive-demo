//  MotionSource.swift
//  Motion input for the engine (0–100).
//  Stub: echoes the manual slider value. Swap in CoreMotion / sensor data later.

import Foundation

final class MotionSource {
    var manualValue: Double = 0
    var value: Double { manualValue }

    func start() {}
    func stop() {}
}
