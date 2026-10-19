//  Budget.swift
//  Stage 3 of the pipeline (Estimate → Trigger → Capacity → Arbiter → Render):
//  how much the runner can take in right now. Capacity computes it from
//  effort, movement, terrain, attention and data quality each tick.
//
//      Standing, or easy and steady        3 elements · info and up
//      Steady at race effort               2 elements · advisory and up
//      Hard effort or climbing             1 element  · critical and up
//      Surge, final kick, technical turn   nothing except safety
//      Final 400 m (by position)           nothing except safety, and the rest dropped
//
//  An answer the runner asked for (a glance or held look) gets through below
//  the lowest priority, except where only safety does (answersRequests).

import Foundation

public struct Budget: Sendable, Equatable, Codable {
    /// Elements that fit on screen; 0 is the empty budget (only safety gets through).
    /// The renderer (chunk 7) picks a layout to fit it; the arbiter only asks "is it empty".
    public var maxElements: Int
    /// The lowest priority allowed through. Safety always is.
    public var minPriority: Priority
    /// Whether a more important cue may cut short one that is still within its
    /// minimum time. When false it waits its turn; safety still interrupts.
    public var allowInterrupt: Bool
    /// Inputs too poor to act on: a cue that needs one of them is held back
    /// (not taken down if already showing). Safety cues are not exempt; a
    /// safety cue shouldn't depend on data it can't trust.
    public var unreliable: Set<CueInput>
    /// In the race's final stretch (the last 400 m, by position): nothing but
    /// safety until the finish, so the arbiter drops other cues rather than
    /// holding them back. The kick clock (chunk 9) owns this stretch.
    public var finalStretch: Bool
    /// Whether a cue the runner asked for (a glance's or held look's answer:
    /// reveal .glance / .dwell) may show below `minPriority`, as long as the
    /// budget isn't empty. Design: "Ask and it answers". Capacity sets it for
    /// every row but the safety-only ones.
    public var answersRequests: Bool

    public init(maxElements: Int, minPriority: Priority, allowInterrupt: Bool = true,
                unreliable: Set<CueInput> = [], finalStretch: Bool = false, answersRequests: Bool = false) {
        self.maxElements = maxElements
        self.minPriority = minPriority
        self.allowInterrupt = allowInterrupt
        self.unreliable = unreliable
        self.finalStretch = finalStretch
        self.answersRequests = answersRequests
    }

    public var isEmpty: Bool { maxElements <= 0 }

    /// Whether a cue of this priority may show under this budget.
    public func admits(_ priority: Priority) -> Bool {
        priority == .safety || (!isEmpty && priority >= minPriority)
    }

    /// Whether this cue may show: its priority is allowed, or it answers the
    /// runner and the budget answers requests.
    public func admits(_ cue: Cue) -> Bool {
        admits(cue.priority) || (answersRequests && !isEmpty && cue.reveal != .auto)
    }

    /// The first input this cue needs that the budget can't trust, if any.
    public func distrusted(_ cue: Cue) -> CueInput? {
        CueInput.allCases.first { cue.needs.contains($0) && unreliable.contains($0) }
    }

    /// Standing, or easy and steady.
    public static let relaxed = Budget(maxElements: 3, minPriority: .info)
    /// Steady at race effort.
    public static let steady = Budget(maxElements: 2, minPriority: .advisory)
    private enum CodingKeys: String, CodingKey {
        case maxElements, minPriority, allowInterrupt, unreliable, finalStretch, answersRequests
    }

    // Logs written before answersRequests existed decode with it off.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(maxElements: try c.decode(Int.self, forKey: .maxElements),
                  minPriority: try c.decode(Priority.self, forKey: .minPriority),
                  allowInterrupt: try c.decode(Bool.self, forKey: .allowInterrupt),
                  unreliable: try c.decode(Set<CueInput>.self, forKey: .unreliable),
                  finalStretch: try c.decode(Bool.self, forKey: .finalStretch),
                  answersRequests: try c.decodeIfPresent(Bool.self, forKey: .answersRequests) ?? false)
    }

    /// Hard effort or climbing.
    public static let strained = Budget(maxElements: 1, minPriority: .critical)
    /// Surge, final kick, technical turn: nothing except safety.
    public static let safetyOnly = Budget(maxElements: 0, minPriority: .safety)
}
