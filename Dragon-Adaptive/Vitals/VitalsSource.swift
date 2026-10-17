//  VitalsSource.swift
//  Motion + heart-rate input. Today: synthetic stream. Next: Apple Watch.
//  Same idea as AttentionSource — the engine never knows where samples
//  come from, so swapping in the real watch is a one-line change in HUDController.

import Foundation

struct VitalsSample {
    let timestamp: Date
    let heartRate: Double?   // bpm; nil when this sample carries no HR reading
    let motion: Double?      // 0–100 exertion; nil when this sample carries no motion reading
}

protocol VitalsSource: AnyObject {
    var onSample: ((VitalsSample) -> Void)? { get set }
    func start()
    func stop()
}
