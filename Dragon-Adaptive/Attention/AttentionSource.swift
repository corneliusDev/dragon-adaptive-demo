//  AttentionSource.swift
//  The ONLY abstraction that changes when real gaze arrives.
//  ActiveLook has no gaze; the engine never asks for gaze — it consumes
//  an abstract AttentionEvent. Today: gesture sensor. Tomorrow: gaze.

import Foundation

enum AttentionEvent { case glance, dwell, idle }

protocol AttentionSource: AnyObject {
    var onEvent: ((AttentionEvent) -> Void)? { get set }
    func start()
    func stop()
}
