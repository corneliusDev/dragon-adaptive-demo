//  WatchHapticsTests.swift
//  The Watch-tap heads-up (chunk 14 part B): the tap commands round-trip in
//  the version-1 format and an unknown command is still rejected cleanly
//  (what an older Watch build does with a tap); the strength follows the
//  coming cue's priority; the Watch's handler plays the right haptic on a
//  player and drops a tap that arrived too late; and RunEngine's heads-up
//  carries the coming cue's priority.

import XCTest
import DragonEngine

/// Stands in for WKInterfaceDevice.
final class HapticRecorder: WatchHapticPlaying {
    var played: [WatchHaptic] = []
    func play(_ haptic: WatchHaptic) { played.append(haptic) }
}

final class WatchHapticsTests: XCTestCase {
    private let t0 = 1_760_870_000.0

    func testTapCommandsRoundTripInVersionOne() throws {
        for command in [WatchCommand.tapLight, .tapStrong] {
            let m = WatchMessage(session: "phone-1", sequence: 3, sentAt: t0, body: .command(command))
            let data = m.encoded()
            XCTAssertEqual(try WatchMessage.decode(data), m)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["v"] as? Int, 1, "a new command inside v1, not a new version")
            XCTAssertEqual(object["kind"] as? String, "command")
            XCTAssertEqual(object["command"] as? String, command.rawValue)
        }
    }

    func testAnUnknownCommandIsRejectedCleanly() {
        // What a future command looks like to this build (and a tap to an older one).
        let data = Data(#"{"v":1,"session":"S","seq":1,"sentAt":1,"kind":"command","command":"tapTriple"}"#.utf8)
        XCTAssertThrowsError(try WatchMessage.decode(data)) {
            XCTAssertEqual($0 as? WatchMessageError, .invalidValue)
        }
        // The next message still reads.
        let next = WatchMessage(session: "S", sequence: 2, sentAt: 1, body: .command(.tapLight))
        XCTAssertEqual(try WatchMessage.decode(next.encoded()), next)
    }

    func testStrengthFollowsPriority() {
        XCTAssertEqual(WatchHaptic.forHeadsUp(.info), .light)
        XCTAssertEqual(WatchHaptic.forHeadsUp(.advisory), .light)
        XCTAssertEqual(WatchHaptic.forHeadsUp(.critical), .strong)
        XCTAssertEqual(WatchHaptic.forHeadsUp(.safety), .strong)
        XCTAssertEqual(WatchHaptic.light.command, .tapLight)
        XCTAssertEqual(WatchHaptic.strong.command, .tapStrong)
        XCTAssertEqual(WatchCommand.tapLight.haptic, .light)
        XCTAssertEqual(WatchCommand.tapStrong.haptic, .strong)
        XCTAssertNil(WatchCommand.startWorkout.haptic)
        XCTAssertNil(WatchCommand.endWorkout.haptic)
    }

    func testTheWatchHandlerPlaysTheRightHaptic() {
        let player = HapticRecorder()
        let handler = WatchTapHandler(player: player)
        XCTAssertEqual(handler.handle(.tapLight, sentAt: t0, now: t0 + 0.2), .light)
        XCTAssertEqual(handler.handle(.tapStrong, sentAt: t0, now: t0 + 0.3), .strong)
        XCTAssertNil(handler.handle(.startWorkout, sentAt: t0, now: t0), "not a tap")
        XCTAssertNil(handler.handle(.endWorkout, sentAt: t0, now: t0))
        XCTAssertEqual(player.played, [.light, .strong])
        XCTAssertEqual(handler.played, 2)
    }

    func testALateTapIsDropped() {
        let player = HapticRecorder()
        let handler = WatchTapHandler(player: player)
        XCTAssertNil(handler.handle(.tapStrong, sentAt: t0, now: t0 + 2.5), "the cue is already up")
        XCTAssertNil(handler.handle(.tapLight, sentAt: t0 + 60, now: t0), "clock far ahead")
        XCTAssertEqual(handler.handle(.tapLight, sentAt: t0 + 1, now: t0), .light, "clocks a little apart")
        XCTAssertEqual(player.played, [.light])
        XCTAssertEqual(handler.droppedLate, 2)
    }

    func testTheHeadsUpCarriesTheComingCuesPriority() {
        var config = RunEngine.Config()
        config.headsUp = [.watchTap]
        let race = segueRace(.designWalkthrough, config: config)
        let starts = race.rows.filter(\.headsUpBegan).compactMap(\.headsUp)
        XCTAssertFalse(starts.isEmpty)
        for h in starts {
            // The cue that heads-up was for, when it appeared.
            guard let shown = race.appearances.first(where: { $0.cue.key == h.key && $0.row.t >= h.since }) else { continue }
            XCTAssertEqual(h.priority, shown.cue.priority, "\(h.key.name) at \(h.since)")
        }
        XCTAssertTrue(starts.contains { $0.priority < .critical }, "splits: a light tap")
    }
}
