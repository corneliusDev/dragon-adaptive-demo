//  HUDController.swift
//  Orchestrates engine + attention + motion + glasses. Drives a 20fps loop,
//  pushes frames to the glasses when connected and to the on-phone mirror.
//
//  Live HUD version:
//  - Calibration is OFF, so the display moves again.
//  - Sends a short BLE OK test pattern after connect.
//  - Then hands off to the adaptive HUD.
//  - Forces redraws on gesture, reset, scenario change, and run toggle.
//
//  The engine is clock-free: this controller owns run time (monotonic seconds
//  since launch) and passes it to every engine call.

import Foundation
import Combine
import SwiftUI
import DragonEngine

enum VitalsMode {
    case manual      // motion slider; HR estimated from motion
    case synthetic   // SyntheticVitalsSource stands in for the Apple Watch
}

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
    @Published var vitalsMode: VitalsMode = .synthetic
    @Published var vitalsLabel = "—"

    private let engine = AdaptiveEngine(scenario: Scenarios.cyclingTri)
    private let session = GlassesSession()
    private let sim = SimulatedAttentionSource()
    private let motionSource = MotionSource()
    private let synthetic = SyntheticVitalsSource()

    // HR older than this is treated as missing and the engine falls back to its estimate.
    private let hrStaleAfter: TimeInterval = 5
    private var lastHR: Double?
    private var lastHRAt: TimeInterval = -.infinity   // run time of the last HR reading

    // Monotonic run time handed to the engine.
    private let launchUptime = ProcessInfo.processInfo.systemUptime
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime - launchUptime }

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
            guard let self = self else { return }
            self.engine.handle(event, at: self.now)
            self.backend?.invalidate()
        }
        sim.start()

        synthetic.onSample = { [weak self] sample in
            self?.receive(sample)
        }

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
                guard let self = self else { return }
                self.engine.handle(event, at: self.now)
                self.backend?.invalidate()
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
        synthetic.stop()
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
        syncSynthetic()
        backend?.invalidate()
        print("[HUDController] running: \(running)")
    }

    func reset() {
        print("[HUDController] reset")

        engine.reset()
        running = false
        resetVitals()

        backend?.invalidate()
        pushImmediateFrame()
    }

    func setScenario(_ key: String) {
        print("[HUDController] set scenario: \(key)")

        scenarioKey = key
        engine.setScenario(key == "sof" ? Scenarios.operatorSOF : Scenarios.cyclingTri)

        running = false
        resetVitals()

        backend?.invalidate()
        pushImmediateFrame()
    }

    func setVitalsMode(_ mode: VitalsMode) {
        print("[HUDController] vitals mode: \(mode)")

        vitalsMode = mode
        resetVitals()
        syncSynthetic()
        pushImmediateFrame()
    }

    // MARK: - Vitals

    private func receive(_ sample: VitalsSample) {
        if let m = sample.motion {
            motion = m
        }

        if let hr = sample.heartRate {
            lastHR = hr
            lastHRAt = now
        }
    }

    /// The synthetic watch streams only while the scenario is playing.
    private func syncSynthetic() {
        if vitalsMode == .synthetic && running {
            synthetic.start()
        } else {
            synthetic.stop()
        }
    }

    private func resetVitals() {
        synthetic.stop()
        synthetic.reset()
        lastHR = nil
        lastHRAt = -.infinity
        motion = 0
    }

    private var freshHeartRate: Int? {
        guard let hr = lastHR, now - lastHRAt < hrStaleAfter else {
            return nil
        }
        return Int(hr)
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
        step(dt: 1.0 / 20.0)
    }

    private func pushImmediateFrame() {
        step(dt: 0)
    }

    private func step(dt: Double) {
        engine.motion = motionSource.value
        engine.measuredHeartRate = freshHeartRate

        let nextFrame = engine.tick(dt: dt, at: now)

        DispatchQueue.main.async {
            self.frame = nextFrame
            self.bandLabel = self.engine.band.label
            self.attnLabel = self.attnTag
            self.ctxLabel = self.engine.active.map {
                "\($0.tag) · \($0.line1)"
            } ?? (self.engine.band == .stationary ? "dashboard" : "ambient only")
            self.vitalsLabel = self.vitalsTag
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

    private var vitalsTag: String {
        let hr = engine.measuredHeartRate.map { "HR \($0)" } ?? "HR \(engine.heartRate) est"
        return "\(hr) · MOT \(Int(motion))"
    }
}
