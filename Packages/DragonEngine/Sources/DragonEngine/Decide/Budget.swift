//  Budget.swift
//  Stage 3 of the pipeline (Estimate → Trigger → Capacity → Arbiter → Render):
//  how much the runner can take in right now. Chunk 6 computes it from
//  effort, movement, terrain and attention; until then RunEngine passes the
//  fixed `.steady` budget.
//
//      Standing, or easy and steady        3 elements · info and up
//      Steady at race effort               2 elements · advisory and up
//      Hard effort or climbing             1 element  · critical and up
//      Surge, final kick, technical turn   nothing except safety

import Foundation

public struct Budget: Sendable, Equatable {
    /// Elements that fit on screen; 0 is the empty budget (only safety gets through).
    /// The renderer (chunk 7) picks a layout to fit it; the arbiter only asks "is it empty".
    public var maxElements: Int
    /// The lowest priority allowed through. Safety always is.
    public var minPriority: Priority
    /// Whether a more important cue may cut short one that is still within its
    /// minimum time. When false it waits its turn; safety still interrupts.
    public var allowInterrupt: Bool

    public init(maxElements: Int, minPriority: Priority, allowInterrupt: Bool = true) {
        self.maxElements = maxElements
        self.minPriority = minPriority
        self.allowInterrupt = allowInterrupt
    }

    public var isEmpty: Bool { maxElements <= 0 }

    /// Whether a cue of this priority may show under this budget.
    public func admits(_ priority: Priority) -> Bool {
        priority == .safety || (!isEmpty && priority >= minPriority)
    }

    /// Standing, or easy and steady.
    public static let relaxed = Budget(maxElements: 3, minPriority: .info)
    /// Steady at race effort: RunEngine's fixed budget until chunk 6.
    public static let steady = Budget(maxElements: 2, minPriority: .advisory)
    /// Hard effort or climbing.
    public static let strained = Budget(maxElements: 1, minPriority: .critical)
    /// Surge, final kick, technical turn: nothing except safety.
    public static let safetyOnly = Budget(maxElements: 0, minPriority: .safety)
}
