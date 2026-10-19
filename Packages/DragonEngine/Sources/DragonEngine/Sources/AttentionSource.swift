//  AttentionSource.swift
//  The ONLY abstraction that changes when real gaze arrives.
//  ActiveLook has no gaze; the engine never asks for gaze — it consumes
//  an abstract AttentionEvent. Today: gesture sensor. Tomorrow: gaze.

import Foundation

public enum AttentionEvent: String, Sendable, Codable { case glance, dwell, idle }

public protocol AttentionSource: AnyObject {
    var onEvent: ((AttentionEvent) -> Void)? { get set }
    func start()
    func stop()
}
