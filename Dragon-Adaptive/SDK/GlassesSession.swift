//
//  GlassesSession.swift
//  ActiveLook scan / connect / lifecycle with BLE diagnostics.
//  Uses ActiveLookSDKBootstrap.sdk so the SDK is initialized exactly once.
//

import Foundation
import ActiveLookSDK

enum ConnectionState: Equatable {
    case idle
    case scanning
    case connecting(String)
    case connected(String)
    case failed(String)

    var label: String {
        switch self {
        case .idle:
            return "DISCONNECTED"
        case .scanning:
            return "SCANNING…"
        case .connecting(let name):
            return "CONNECTING \(name)"
        case .connected(let name):
            return "CONNECTED · \(name)"
        case .failed(let error):
            return "ERROR · \(error)"
        }
    }

    var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }
}

final class GlassesSession {
    private(set) var glasses: Glasses?

    var onState: ((ConnectionState) -> Void)?
    var onConnected: ((Glasses) -> Void)?

    private lazy var sdk: ActiveLookSDK = {
        return ActiveLookSDKBootstrap.sdk
    }()

    private var scanTimeout: Timer?
    private var didStartConnect = false

    func connect() {
        log("connect() tapped")

        cleanupBeforeNewConnection()

        setState(.scanning)
        log("Starting BLE scan…")

        sdk.startScanning(
            onGlassesDiscovered: { [weak self] discovered in
                guard let self = self else { return }

                let name = discovered.name
                self.log("Discovered glasses: \(name)")

                guard self.didStartConnect == false else {
                    self.log("Already connecting; ignoring extra discovered device: \(name)")
                    return
                }

                self.didStartConnect = true
                self.scanTimeout?.invalidate()
                self.scanTimeout = nil

                self.setState(.connecting(name))
                self.log("Connecting to \(name)…")

                discovered.connect(
                    onGlassesConnected: { [weak self] connectedGlasses in
                        guard let self = self else { return }

                        self.log("Connected to glasses: \(connectedGlasses.name)")

                        self.sdk.stopScanning()
                        self.scanTimeout?.invalidate()
                        self.scanTimeout = nil
                        self.glasses = connectedGlasses

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            self.log("Powering display on…")

                            connectedGlasses.power(on: true)
                            connectedGlasses.luma(level: 15)
                            connectedGlasses.clear()

                            self.setState(.connected(connectedGlasses.name))
                            self.onConnected?(connectedGlasses)
                        }
                    },
                    onGlassesDisconnected: { [weak self] in
                        guard let self = self else { return }

                        self.log("Glasses disconnected")
                        self.glasses = nil
                        self.didStartConnect = false
                        self.setState(.idle)
                    },
                    onConnectionError: { [weak self] error in
                        self?.fail("Connection error: \(error.localizedDescription)")
                    }
                )
            },
            onScanError: { [weak self] error in
                self?.fail("Scan error: \(error.localizedDescription)")
            }
        )

        startScanTimeout()
    }

    func disconnect() {
        log("disconnect()")

        scanTimeout?.invalidate()
        scanTimeout = nil

        sdk.stopScanning()

        glasses?.clear()
        glasses?.disconnect()
        glasses = nil

        didStartConnect = false
        setState(.idle)
    }

    private func cleanupBeforeNewConnection() {
        scanTimeout?.invalidate()
        scanTimeout = nil

        sdk.stopScanning()

        glasses?.disconnect()
        glasses = nil

        didStartConnect = false
    }

    private func startScanTimeout() {
        DispatchQueue.main.async {
            self.scanTimeout?.invalidate()

            self.scanTimeout = Timer.scheduledTimer(withTimeInterval: 12.0, repeats: false) { [weak self] _ in
                guard let self = self else { return }

                if self.glasses == nil && self.didStartConnect == false {
                    self.sdk.stopScanning()
                    self.fail("No glasses discovered after 12s. Check Bluetooth permission, glasses power, and whether another app is connected.")
                }
            }
        }
    }

    private func fail(_ message: String) {
        log("FAIL: \(message)")

        scanTimeout?.invalidate()
        scanTimeout = nil

        sdk.stopScanning()
        glasses = nil
        didStartConnect = false

        setState(.failed(message))
    }

    private func setState(_ state: ConnectionState) {
        DispatchQueue.main.async {
            self.onState?(state)
        }
    }

    private func log(_ message: String) {
        print("[GlassesSession] \(message)")
    }
}
