//  WatchMessageTests.swift
//  The Watch ↔ phone message format: every kind round-trips, and anything
//  that isn't version 1 (older, newer, missing) is rejected before its body
//  is read.

import XCTest
import DragonEngine

final class WatchMessageTests: XCTestCase {
    private let t0 = 1_760_870_000.0

    private func message(_ body: WatchMessage.Body, seq: Int = 7) -> WatchMessage {
        WatchMessage(session: "S1", sequence: seq, sentAt: t0 + 0.25, body: body)
    }

    private func json(_ s: String) -> Data { Data(s.utf8) }

    func testEveryKindRoundTrips() throws {
        let bodies: [WatchMessage.Body] = [
            .heartRate(bpm: 152, at: t0),
            .heartRate(bpm: 61.5, at: t0 - 3.125),
            .effort(score: 0, at: t0),
            .effort(score: 47.25, at: t0 + 1),
            .effort(score: 100, at: t0 + 2),
        ] + WatchSessionState.allCases.map { .state($0, at: t0) }
          + WatchCommand.allCases.map { .command($0) }
        for (i, body) in bodies.enumerated() {
            let m = message(body, seq: i)
            XCTAssertEqual(try WatchMessage.decode(m.encoded()), m, "\(body)")
        }
    }

    func testWireFormatIsSmallFlatJSONWithTheVersion() throws {
        let data = message(.heartRate(bpm: 152, at: t0)).encoded()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(object["kind"] as? String, "hr")
        XCTAssertEqual(object["value"] as? Double, 152)
        XCTAssertEqual(object["seq"] as? Int, 7)
        XCTAssertEqual(object["session"] as? String, "S1")
        XCTAssertLessThan(data.count, 160, "a heart rate message should stay small for the radio")
        XCTAssertEqual(WatchMessage.version, 1)
    }

    func testOlderAndNewerVersionsAreRejected() {
        for v in [0, 2, 99, -1] {
            let data = json(#"{"v":\#(v),"session":"S1","seq":1,"sentAt":1,"kind":"hr","value":150,"at":1}"#)
            XCTAssertThrowsError(try WatchMessage.decode(data)) { error in
                XCTAssertEqual(error as? WatchMessageError, .unsupportedVersion(v))
            }
        }
    }

    func testANewerVersionIsRejectedEvenWhenItsBodyIsUnreadable() {
        // v2 might change every other field; we must not try to read them.
        let data = json(#"{"v":2,"payload":{"heart":[150,151]},"sequence":"abc"}"#)
        XCTAssertThrowsError(try WatchMessage.decode(data)) { error in
            XCTAssertEqual(error as? WatchMessageError, .unsupportedVersion(2))
        }
    }

    func testMissingVersionOrGarbageIsMalformed() {
        let bad = [
            json(#"{"session":"S1","seq":1,"sentAt":1,"kind":"hr","value":150,"at":1}"#),
            json("not json"),
            Data(),
            json(#"{"v":"1"}"#),
            json(#"{"v":1,"session":"S1","seq":1,"sentAt":1,"kind":"hr","at":1}"#),        // no value
            json(#"{"v":1,"session":"S1","seq":1,"sentAt":1,"kind":"hr","value":150}"#),   // no at
            json(#"{"v":1,"session":"S1","seq":-4,"sentAt":1,"kind":"hr","value":150,"at":1}"#),
            json(#"{"v":1,"session":"S1","seq":1,"sentAt":1,"kind":"state","at":1}"#),
        ]
        for data in bad {
            XCTAssertThrowsError(try WatchMessage.decode(data)) { error in
                XCTAssertEqual(error as? WatchMessageError, .malformed, String(decoding: data, as: UTF8.self))
            }
        }
    }

    func testUnknownKindAndOutOfRangeValuesAreRejected() {
        XCTAssertThrowsError(try WatchMessage.decode(json(#"{"v":1,"session":"S","seq":1,"sentAt":1,"kind":"spo2","value":97,"at":1}"#))) {
            XCTAssertEqual($0 as? WatchMessageError, .unknownKind("spo2"))
        }
        let invalid = [
            #"{"v":1,"session":"S","seq":1,"sentAt":1,"kind":"hr","value":-5,"at":1}"#,
            #"{"v":1,"session":"S","seq":1,"sentAt":1,"kind":"hr","value":400,"at":1}"#,
            #"{"v":1,"session":"S","seq":1,"sentAt":1,"kind":"effort","value":101,"at":1}"#,
            #"{"v":1,"session":"S","seq":1,"sentAt":1,"kind":"state","state":"sleeping","at":1}"#,
            #"{"v":1,"session":"S","seq":1,"sentAt":1,"kind":"command","command":"selfDestruct"}"#,
        ]
        for s in invalid {
            XCTAssertThrowsError(try WatchMessage.decode(json(s))) {
                XCTAssertEqual($0 as? WatchMessageError, .invalidValue, s)
            }
        }
    }

    func testSequencerCountsUpWithinASession() {
        var seq = WatchMessageSequencer(session: "A")
        let a = seq.message(.heartRate(bpm: 150, at: t0), sentAt: t0)
        let b = seq.message(.effort(score: 40, at: t0), sentAt: t0)
        XCTAssertEqual([a.sequence, b.sequence], [0, 1])
        XCTAssertEqual(a.session, "A")
        XCTAssertEqual(a.stream, .heartRate)
        XCTAssertEqual(b.stream, .effort)
        XCTAssertEqual(seq.next, 2)
    }
}
