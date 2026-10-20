//  WatchMessage.swift
//  The one definition of what the Apple Watch app and the phone say to each
//  other, shared by both targets. Small, flat JSON, versioned:
//
//      {"v":1,"session":"…","seq":42,"sentAt":1760870000.25,
//       "kind":"hr","value":152,"at":1760870000.0}
//
//      v        format version; this build speaks `WatchMessage.version` only.
//               Anything else (older or newer) is rejected before the body
//               is looked at, with WatchMessageError.unsupportedVersion.
//      session  the Watch workout this came from. `seq` counts up from 0
//               within it, so (session, seq) names a message exactly once.
//      sentAt   when it was sent, seconds since 1970 on the sender's clock.
//      kind     hr      heart rate: `value` bpm, taken at `at`
//               effort  wrist-motion effort score 0–100 over the second ending `at`
//               state   the Watch workout's state (`state`) as of `at`
//               command phone → Watch: `command` (start / end the workout,
//                       or a heads-up tap on the wrist: tapLight / tapStrong)
//
//  The Watch taps (chunk 14) are new `command` values inside version 1, not a
//  version 2: every other field and kind is unchanged, so a phone and Watch
//  of this build still read all of each other's messages, and an older
//  Watch build that gets a tap rejects just that message cleanly
//  (WatchMessageError.invalidValue: an unknown command) and carries on with
//  the rest. A tap is worth nothing late, so nothing is lost by dropping it.
//
//  Times are wall-clock seconds since 1970 because the two devices share no
//  other clock; the phone turns them into its own run time (the engine never
//  reads a clock, it only gets the number). Encoding and decoding are pure.

import Foundation

/// The Watch workout's state, as the Watch reports it.
public enum WatchSessionState: String, Sendable, Codable, CaseIterable {
    /// Asked to start; waiting for HealthKit.
    case starting
    case running
    case paused
    /// Ended normally (from the Watch or the phone).
    case ended
    /// Couldn't start or stopped with an error.
    case failed
}

/// What the phone can ask the Watch to do.
public enum WatchCommand: String, Sendable, Codable, CaseIterable {
    case startWorkout
    case endWorkout
    /// A light tap on the wrist: an advisory or info cue is coming (heads-up).
    case tapLight
    /// A strong tap: a critical or safety cue is coming.
    case tapStrong

    /// The haptic this command plays on the Watch; nil for the workout commands.
    public var haptic: WatchHaptic? {
        switch self {
        case .tapLight: return .light
        case .tapStrong: return .strong
        case .startWorkout, .endWorkout: return nil
        }
    }
}

public enum WatchMessageError: Error, Equatable {
    /// A version this build doesn't speak (older or newer).
    case unsupportedVersion(Int)
    /// Not JSON, or a field is missing or of the wrong type.
    case malformed
    /// A kind this version doesn't define.
    case unknownKind(String)
    /// A value out of range (negative heart rate, effort over 100, NaN).
    case invalidValue
}

public struct WatchMessage: Sendable, Equatable {
    /// The format version this build reads and writes.
    public static let version = 1

    public enum Body: Sendable, Equatable {
        /// bpm, taken at `at` (seconds since 1970).
        case heartRate(bpm: Double, at: Double)
        /// 0–100 effort over the second ending at `at`.
        case effort(score: Double, at: Double)
        case state(WatchSessionState, at: Double)
        case command(WatchCommand)
    }

    /// Which per-stream ordering a message belongs to.
    public enum Stream: String, Sendable, CaseIterable {
        case heartRate, effort, state, command
    }

    public var session: String
    public var sequence: Int
    public var sentAt: Double
    public var body: Body

    public init(session: String, sequence: Int, sentAt: Double, body: Body) {
        self.session = session
        self.sequence = sequence
        self.sentAt = sentAt
        self.body = body
    }

    public var stream: Stream {
        switch body {
        case .heartRate: return .heartRate
        case .effort: return .effort
        case .state: return .state
        case .command: return .command
        }
    }

    /// When the reading or state change happened (seconds since 1970);
    /// a command's is when it was sent.
    public var at: Double {
        switch body {
        case .heartRate(_, let at), .effort(_, let at), .state(_, let at): return at
        case .command: return sentAt
        }
    }

    // MARK: Wire format

    /// Every field any version-1 kind uses; optional so one struct reads them all.
    private struct Wire: Codable {
        var v: Int
        var session: String
        var seq: Int
        var sentAt: Double
        var kind: String
        var value: Double?
        var at: Double?
        var state: String?
        var command: String?
    }

    /// Just enough to read the version, before trusting the rest.
    private struct Header: Decodable {
        var v: Int
    }

    public func encoded() -> Data {
        var w = Wire(v: WatchMessage.version, session: session, seq: sequence, sentAt: sentAt, kind: "")
        switch body {
        case .heartRate(let bpm, let at): w.kind = "hr"; w.value = bpm; w.at = at
        case .effort(let score, let at): w.kind = "effort"; w.value = score; w.at = at
        case .state(let s, let at): w.kind = "state"; w.state = s.rawValue; w.at = at
        case .command(let c): w.kind = "command"; w.command = c.rawValue
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // Wire has only strings, ints and finite-or-not doubles; a NaN can't be
        // made by the initialisers the apps use, but fail soft rather than trap.
        return (try? encoder.encode(w)) ?? Data()
    }

    public static func decode(_ data: Data) throws -> WatchMessage {
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data) else { throw WatchMessageError.malformed }
        guard header.v == version else { throw WatchMessageError.unsupportedVersion(header.v) }
        guard let w = try? decoder.decode(Wire.self, from: data), w.seq >= 0 else { throw WatchMessageError.malformed }
        guard w.sentAt.isFinite else { throw WatchMessageError.invalidValue }

        func time() throws -> Double {
            guard let at = w.at else { throw WatchMessageError.malformed }
            guard at.isFinite else { throw WatchMessageError.invalidValue }
            return at
        }
        func value(in range: ClosedRange<Double>) throws -> Double {
            guard let v = w.value else { throw WatchMessageError.malformed }
            guard v.isFinite, range.contains(v) else { throw WatchMessageError.invalidValue }
            return v
        }

        let body: Body
        switch w.kind {
        case "hr":
            body = .heartRate(bpm: try value(in: 20...260), at: try time())
        case "effort":
            body = .effort(score: try value(in: 0...100), at: try time())
        case "state":
            guard let raw = w.state else { throw WatchMessageError.malformed }
            guard let s = WatchSessionState(rawValue: raw) else { throw WatchMessageError.invalidValue }
            body = .state(s, at: try time())
        case "command":
            guard let raw = w.command else { throw WatchMessageError.malformed }
            guard let c = WatchCommand(rawValue: raw) else { throw WatchMessageError.invalidValue }
            body = .command(c)
        default:
            throw WatchMessageError.unknownKind(w.kind)
        }
        return WatchMessage(session: w.session, sequence: w.seq, sentAt: w.sentAt, body: body)
    }
}

/// Numbers a sender's messages: one session id, sequence counting up from 0.
public struct WatchMessageSequencer: Sendable {
    public let session: String
    public private(set) var next = 0

    public init(session: String) {
        self.session = session
    }

    /// The next message of this session, sent at `sentAt` (seconds since 1970).
    public mutating func message(_ body: WatchMessage.Body, sentAt: Double) -> WatchMessage {
        defer { next += 1 }
        return WatchMessage(session: session, sequence: next, sentAt: sentAt, body: body)
    }
}
