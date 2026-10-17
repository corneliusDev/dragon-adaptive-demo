//  SimulatedAttentionSource.swift
//  Desk/demo testing with no glasses (and the on-screen LOOK button).

import Foundation

final class SimulatedAttentionSource: AttentionSource {
    var onEvent: ((AttentionEvent) -> Void)?
    func start() {}
    func stop() {}
    func fire(_ e: AttentionEvent) { onEvent?(e) }
}
