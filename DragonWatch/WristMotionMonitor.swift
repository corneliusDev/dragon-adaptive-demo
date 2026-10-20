//  WristMotionMonitor.swift
//  Wrist motion at 50 Hz (CMMotionManager device motion, gravity removed),
//  summarised by DragonEngine's WristEffortScorer to a 0–100 effort score
//  once a second. Runs while the workout does (a workout session keeps the
//  app running with the screen off). No motion hardware (the simulator):
//  nothing is sent.

import Foundation
import CoreMotion
import DragonEngine

final class WristMotionMonitor {
    /// Each second's score, with the wall-clock time its second ended (main queue).
    var onEffort: ((_ score: Double, _ at: Date) -> Void)?

    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private var scorer = WristEffortScorer()

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        scorer.reset()
        queue.maxConcurrentOperationCount = 1
        manager.deviceMotionUpdateInterval = 1.0 / 50
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let a = motion.userAcceleration
            guard let score = self.scorer.add(t: motion.timestamp, x: a.x, y: a.y, z: a.z) else { return }
            // Device-motion timestamps are seconds since boot; place the
            // window's end on the wall clock the phone understands.
            let at = Date().addingTimeInterval(score.t - ProcessInfo.processInfo.systemUptime)
            DispatchQueue.main.async { self.onEffort?(score.effort, at) }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}
