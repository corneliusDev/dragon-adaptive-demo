//  SimulatedAttentionSource.swift
//  Desk/demo testing with no glasses (and the on-screen LOOK button).

import Foundation

public final class SimulatedAttentionSource: AttentionSource {
    public var onEvent: ((AttentionEvent) -> Void)?
    public init() {}
    public func start() {}
    public func stop() {}
    public func fire(_ e: AttentionEvent) { onEvent?(e) }
}
