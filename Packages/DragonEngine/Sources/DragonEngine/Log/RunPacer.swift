//  RunPacer.swift
//  Turns a live stream of inputs into engine updates on a fixed run-time
//  grid, so a real run replays with exactly the same decisions.
//
//  Real sensors deliver late and in bursts: a GPS fix arrives a moment after
//  it was taken, the pedometer every couple of seconds. The pacer holds what
//  arrives and updates the engine at run times 0, step, 2·step, …, each once
//  the sensors' clock is `lag` past it, first ingesting (in time order) every
//  held input taken up to that time. An input that arrives after its time has
//  been updated is dropped as late, and counted. Each input goes to the
//  caller as the engine takes it (for the RunRecorder), so the recording
//  holds exactly what the engine saw; replaying it on the same grid
//  (RunEngine.replay) ingests the same inputs before the same updates.
//
//  Ties in time go location, vitals, attention, as RunRecording merges them.

import Foundation

public struct RunPacer {
    public struct Config: Sendable, Equatable {
        /// Run-time seconds between engine updates: the design's four decisions a second.
        public var step: TimeInterval = 0.25
        /// Seconds the engine runs behind the sensors' clock, so inputs that
        /// arrive late (a GPS fix's timestamp is when it was taken) still make it.
        public var lag: TimeInterval = 2

        public init(step: TimeInterval = 0.25, lag: TimeInterval = 2) {
            self.step = step
            self.lag = lag
        }
    }

    public let config: Config
    /// Updates run so far; update k is at run time k × step.
    public private(set) var updates = 0
    /// Inputs dropped because their time had already been updated.
    public private(set) var lateDropped = 0

    /// Held inputs, with an arrival number to keep equal times in arrival order.
    private var held: [(event: RunEvent, seq: Int)] = []
    /// Held inputs before this index have been ingested.
    private var head = 0
    private var arrivals = 0
    private var sorted = true

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Run time of update `k`.
    public func time(ofUpdate k: Int) -> TimeInterval { Double(k) * config.step }

    /// Run time of the latest update; nil before the first.
    public var lastUpdate: TimeInterval? { updates == 0 ? nil : time(ofUpdate: updates - 1) }

    /// Inputs held for a later update.
    public var pending: Int { held.count - head }

    /// Holds an input for the next update due at or after its time. Returns
    /// false, dropping it, when that time has already been updated.
    @discardableResult
    public mutating func receive(_ event: RunEvent) -> Bool {
        if let last = lastUpdate, event.t <= last {
            lateDropped += 1
            return false
        }
        if let previous = held.last, head < held.count,
           RunPacer.precedes((event, arrivals), previous) {
            sorted = false
        }
        held.append((event, arrivals))
        arrivals += 1
        return true
    }

    /// The next update due by sensor run time `now` (at or before now − lag):
    /// its run time and the inputs to ingest first, in order; nil when none
    /// is due. The caller ingests them, then updates the engine at `t`.
    public mutating func nextUpdate(by now: TimeInterval) -> (t: TimeInterval, inputs: [RunEvent])? {
        let t = time(ofUpdate: updates)
        guard t <= now - config.lag + 1e-9 else {
            compact()
            return nil
        }
        if !sorted {
            held[head...].sort(by: RunPacer.precedes)
            sorted = true
        }
        var inputs: [RunEvent] = []
        while head < held.count, held[head].event.t <= t {
            inputs.append(held[head].event)
            head += 1
        }
        updates += 1
        return (t, inputs)
    }

    /// Runs every update due by sensor run time `now`, in order. `ingested`
    /// sees each input as the engine takes it, `stepped` each update's result.
    public mutating func advance(to now: TimeInterval, engine: inout RunEngine,
                                 ingested: (RunEvent) -> Void = { _ in },
                                 stepped: (RunEngine.Step) -> Void = { _ in }) {
        while let update = nextUpdate(by: now) {
            for event in update.inputs {
                engine.ingest(event)
                ingested(event)
            }
            stepped(engine.update(at: update.t))
        }
    }

    /// Drops what's been ingested once it's a good share of the buffer.
    private mutating func compact() {
        if head > 256 && head * 2 > held.count {
            held.removeFirst(head)
            head = 0
        }
    }

    private static func rank(_ e: RunEvent) -> Int {
        switch e {
        case .location: return 0
        case .vitals: return 1
        case .attention: return 2
        }
    }

    private static func precedes(_ a: (event: RunEvent, seq: Int), _ b: (event: RunEvent, seq: Int)) -> Bool {
        if a.event.t != b.event.t { return a.event.t < b.event.t }
        let ra = rank(a.event), rb = rank(b.event)
        if ra != rb { return ra < rb }
        return a.seq < b.seq
    }
}

extension RunEngine.Config {
    /// The settings a recording notes (name, unit, display), defaults for the rest.
    public init(replaying recording: RunRecording) {
        self.init(unit: recording.unit ?? .miles)
        name = recording.name
        display = recording.display ?? .balanced
    }
}

extension RunEngine {
    /// Replays a recording on the grid it was made on (`updateStep`, every
    /// update from run time 0 through `endedAt`), so a recording a RunPacer
    /// made gives the same decisions it gave live. Recordings without that
    /// grid use RunPacer's default step through their last input.
    /// `plan` defaults to the recording's own, `config` to the settings it notes.
    public static func replay(_ recording: RunRecording, plan: RunPlan? = nil, config: Config? = nil,
                              through end: TimeInterval? = nil,
                              stepped: (RunEngine.Step) -> Void = { _ in }) -> RunEngine {
        guard let plan = plan ?? recording.plan else {
            preconditionFailure("RunEngine.replay needs a plan: the recording has none")
        }
        var engine = RunEngine(plan: plan, config: config ?? Config(replaying: recording))
        var pacer = RunPacer(config: RunPacer.Config(step: recording.updateStep ?? RunPacer.Config().step, lag: 0))
        for event in recording.events { pacer.receive(event) }
        pacer.advance(to: end ?? recording.endedAt ?? recording.duration, engine: &engine, stepped: stepped)
        return engine
    }
}
