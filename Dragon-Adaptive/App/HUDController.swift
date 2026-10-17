//  HUDController.swift
//  Orchestrates engine + attention + motion + glasses. Drives a 20fps loop,
//  pushes frames to the glasses when connected and to the on-phone mirror.
//
//  Live HUD version:
//  - Calibration is OFF, so the display moves again.
//  - Sends a short BLE OK test pattern after connect.
//  - Then hands off to the adaptive HUD.
//  - Forces redraws on gesture, reset, scenario change, and run toggle.

import Foundation
import Combine
import SwiftUI

final class HUDController: ObservableObject {
    @Published var connection: ConnectionState = .idle
    @Published var frame = HUDFrame()
    @Published var motion: Double = 0 {
        didSet {
            motionSource.manualValue = motion
        }
    }
    @Published var running = false
    @Published var scenarioKey = "tri"
    @Published var flywheel = 0
    @Published var bandLabel = "STATIONARY"
    @Published var attnLabel = "○ IDLE"
    @Published var ctxLabel = "—"

    private let engine = AdaptiveEngine(scenario: Scenarios.cyclingTri)
    private let session = GlassesSession()
    private let sim = SimulatedAttentionSource()
    private let motionSource = MotionSource()

    private var gesture: GestureAttentionSource?
    private var backend: GlassesBackend?
    private var timer: Timer?

    // Keep this false for live HUD motion.
    // Change to true only when you want to freeze the glasses on the calibration pattern.
    private let showCalibrationOnConnect = false

    init() {
        print("[HUDController] init")

        sim.onEvent = { [weak self] event in
            print("[HUDController] simulated attention event: \(event)")
            self?.engine.handle(event)
            self?.backend?.invalidate()
        }
        sim.start()

        engine.onFlywheel = { [weak self] n in
            DispatchQueue.main.async {
                self?.flywheel = n
            }
        }

        session.onState = { [weak self] state in
            DispatchQueue.main.async {
                print("[HUDController] connection state: \(state.label)")
                self?.connection = state
            }
        }

        session.onConnected = { [weak self] glasses in
            guard let self = self else { return }

            print("[HUDController] onConnected: \(glasses.name)")

            let backend = GlassesBackend(glasses: glasses)
            self.backend = backend

            let gesture = GestureAttentionSource(glasses: glasses)
            gesture.onEvent = { [weak self] event in
                print("[HUDController] glasses gesture event: \(event)")
                self?.engine.handle(event)
                self?.backend?.invalidate()
            }
            gesture.start()
            self.gesture = gesture

            if self.showCalibrationOnConnect {
                backend.sendCalibrationPattern()
                print("[HUDController] holding calibration pattern. Set showCalibrationOnConnect = false to run HUD.")
            } else {
                backend.sendTestPattern()
                backend.invalidate()

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) {
                    print("[HUDController] engine taking over display after test pattern")
                    self.backend?.invalidate()
                    self.pushImmediateFrame()
                }
            }
        }

        motionSource.start()
        startLoop()
    }

    deinit {
        print("[HUDController] deinit")
        timer?.invalidate()
        motionSource.stop()
        gesture?.stop()
        session.disconnect()
    }

    // MARK: - Controls

    func connect() {
        print("[HUDController] connect tapped")
        session.connect()
    }

    func disconnect() {
        print("[HUDController] disconnect tapped")

        gesture?.stop()
        gesture = nil

        backend?.invalidate()
        backend = nil

        session.disconnect()
    }

    func glance() {
        print("[HUDController] glance tapped")
        sim.fire(.glance)
        backend?.invalidate()
        pushImmediateFrame()
    }

    func dwell() {
        print("[HUDController] dwell triggered")
        sim.fire(.dwell)
        backend?.invalidate()
        pushImmediateFrame()
    }

    func toggleRun() {
        running.toggle()
        engine.running = running
        backend?.invalidate()
        print("[HUDController] running: \(running)")
    }

    func reset() {
        print("[HUDController] reset")

        engine.reset()
        running = false
        motion = 0

        backend?.invalidate()
        pushImmediateFrame()
    }

    func setScenario(_ key: String) {
        print("[HUDController] set scenario: \(key)")

        scenarioKey = key
        engine.setScenario(key == "sof" ? Scenarios.operatorSOF : Scenarios.cyclingTri)

        running = false
        motion = 0

        backend?.invalidate()
        pushImmediateFrame()
    }

    // MARK: - Loop

    private func startLoop() {
        timer?.invalidate()

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            self?.tick()
        }

        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }

        print("[HUDController] render loop started")
    }

    private func tick() {
        if running {
            autoMotion()
        }

        engine.motion = motionSource.value

        let nextFrame = engine.tick(dt: 1.0 / 20.0)

        DispatchQueue.main.async {
            self.frame = nextFrame
            self.bandLabel = self.engine.band.label
            self.attnLabel = self.attnTag
            self.ctxLabel = self.engine.active.map {
                "\($0.tag) · \($0.line1)"
            } ?? (self.engine.band == .stationary ? "dashboard" : "ambient only")
        }

        if !showCalibrationOnConnect {
            backend?.apply(nextFrame)
        }
    }

    private func pushImmediateFrame() {
        engine.motion = motionSource.value
        let nextFrame = engine.tick(dt: 0)

        DispatchQueue.main.async {
            self.frame = nextFrame
            self.bandLabel = self.engine.band.label
            self.attnLabel = self.attnTag
            self.ctxLabel = self.engine.active.map {
                "\($0.tag) · \($0.line1)"
            } ?? (self.engine.band == .stationary ? "dashboard" : "ambient only")
        }

        if !showCalibrationOnConnect {
            backend?.apply(nextFrame)
        }
    }

    private var attnTag: String {
        switch engine.attention {
        case .glance:
            return "◉ GLANCE"
        case .dwell:
            return "◉◉ DWELL"
        case .idle:
            return "○ IDLE"
        }
    }

    private func autoMotion() {
        let t = engine.clock

        var m = 30 + 28 * sin(t / 3.2) + 18 * sin(t / 1.3)

        if t > 12 && t < 20 {
            m += 30
        }

        if t > 30 && t < 38 {
            m += 20
        }

        motion = max(0, min(100, m))
    }
}
