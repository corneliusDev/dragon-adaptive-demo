//  CourseTests.swift

import XCTest
@testable import DragonEngine

final class CourseTests: XCTestCase {

    // MARK: Loading

    func testFlatLoopLoads() throws {
        let course = try GPXParser.parse(GPXFixtures.flatLoop)
        XCTAssertTrue(course.hasElevation)
        XCTAssertEqual(course.totalDistance, 2 * .pi * 250, accuracy: 3)
        XCTAssertEqual(course.points.first!.elevation!, 12, accuracy: 1e-9)
        XCTAssertTrue(course.hills().isEmpty)
        XCTAssertTrue(course.turns().isEmpty)
        XCTAssertEqual(course.markers(every: .kilometers).map(\.distance), [1000])
        XCTAssertEqual(course.markers(every: .miles).count, 0)
        // Distance increases monotonically.
        XCTAssertEqual(course.points.map(\.distance), course.points.map(\.distance).sorted())
    }

    func testNoElevationLoadsWithElevationMissing() throws {
        let course = try GPXParser.parse(GPXFixtures.noElevation)
        XCTAssertFalse(course.hasElevation)
        XCTAssertEqual(course.points.count, 5)
        XCTAssertTrue(course.points.allSatisfy { $0.elevation == nil })
        XCTAssertNil(course.elevation(at: 100))
        XCTAssertTrue(course.hills().isEmpty)
        // 4 × 0.0009° of latitude ≈ 400 m, across both segments.
        XCTAssertEqual(course.totalDistance, 4 * 0.0009 * .pi / 180 * Course.earthRadius, accuracy: 0.5)
    }

    func testMalformedAndEmptyFilesThrow() {
        XCTAssertThrowsError(try GPXParser.parse("<gpx><trk><trkseg>")) { error in
            guard case GPXError.malformed = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try GPXParser.parse("<gpx></gpx>")) { error in
            XCTAssertEqual(error as? GPXError, .noTrackPoints)
        }
    }

    func testMarkersEveryMileOrKilometre() throws {
        let course = try GPXParser.parse(GPXFixtures.waypoints)   // 3.01 km
        XCTAssertEqual(course.markers(every: .kilometers).map(\.number), [1, 2, 3])
        let miles = course.markers(every: .miles)
        XCTAssertEqual(miles.count, 1)
        XCTAssertEqual(miles[0].distance, 1609.344, accuracy: 1e-9)
    }

    // MARK: Hills

    func testHillIsFoundWhereItWasDrawn() throws {
        let course = try GPXParser.parse(GPXFixtures.hill())
        let hills = course.hills()
        XCTAssertEqual(hills.count, 1)
        let hill = try XCTUnwrap(hills.first)
        XCTAssertEqual(hill.startDistance, GPXFixtures.hillStart, accuracy: 20)
        XCTAssertEqual(hill.endDistance, GPXFixtures.hillEnd, accuracy: 20)
        XCTAssertEqual(hill.gain, GPXFixtures.hillGain, accuracy: 2)
        XCTAssertTrue(course.turns().isEmpty)
    }

    func testNoisyElevationStillGivesOneHill() throws {
        let course = try GPXParser.parse(GPXFixtures.hill(jitter: 0.5, seed: 11))
        let hills = course.hills()
        XCTAssertEqual(hills.count, 1)
        XCTAssertEqual(hills.first?.startDistance ?? 0, GPXFixtures.hillStart, accuracy: 20)
        XCTAssertEqual(hills.first?.endDistance ?? 0, GPXFixtures.hillEnd, accuracy: 20)
    }

    func testShortOrGentleClimbsAreNotHills() throws {
        // 150 m at 6%, then 400 m at 2%.
        let pts = stride(from: 0.0, through: 1500, by: 10).map { x -> GPXFixtures.P in
            let e = x < 300 ? 0 : x < 450 ? (x - 300) * 0.06 : x < 800 ? 9 : x < 1200 ? 9 + (x - 800) * 0.02 : 17
            return GPXFixtures.P(x: x, y: 0, ele: e)
        }
        let course = try GPXParser.parse(GPXFixtures.gpx(pts))
        XCTAssertTrue(course.hills().isEmpty)
    }

    // MARK: Turns

    func testHairpinIsFoundWhereItWasDrawn() throws {
        let course = try GPXParser.parse(GPXFixtures.hairpin)
        let turns = course.turns()
        XCTAssertEqual(turns.count, 1)
        let turn = try XCTUnwrap(turns.first)
        XCTAssertEqual(turn.distance, GPXFixtures.hairpinApex, accuracy: 20)
        XCTAssertGreaterThan(turn.angle, 60)   // a right-hand hairpin
        XCTAssertTrue(course.hills().isEmpty)
    }

    func testRightAngleCornerIsATurnButAGentleBendIsNot() throws {
        // East 300 m, then north 300 m (90° left), then a 30° bend over 100 m.
        var pts = stride(from: 0.0, through: 300, by: 10).map { GPXFixtures.P(x: $0, y: 0, ele: nil) }
        pts += stride(from: 10.0, through: 300, by: 10).map { GPXFixtures.P(x: 300, y: $0, ele: nil) }
        let bend = 30.0 * .pi / 180
        pts += stride(from: 10.0, through: 300, by: 10).map {
            GPXFixtures.P(x: 300 + $0 * sin(bend), y: 300 + $0 * cos(bend), ele: nil)
        }
        let course = try GPXParser.parse(GPXFixtures.gpx(pts))
        let turns = course.turns()
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.distance ?? 0, 300, accuracy: 20)
        XCTAssertEqual(turns.first?.angle ?? 0, -90, accuracy: 5)
    }

    // MARK: Aid stations

    func testAidStationsFromWaypoints() throws {
        let course = try GPXParser.parse(GPXFixtures.waypoints)
        XCTAssertEqual(course.waypoints.count, 3)
        let aid = course.aidStations()
        XCTAssertEqual(aid.map(\.name), ["Aid 1", "Aid 2"])   // sorted, parking dropped
        XCTAssertEqual(aid[0].distance, 1000, accuracy: 20)
        XCTAssertEqual(aid[0].offset, 15, accuracy: 1)
        XCTAssertEqual(aid[1].distance, 2000, accuracy: 20)
    }

    // MARK: Locate

    private func noisy(_ course: Course, at d: Double, rng: inout TestRNG, radius: Double) -> (Double, Double) {
        let p = course.position(at: d)
        let a = rng.uniform(0...(2 * .pi))
        let dx = radius * cos(a), dy = radius * sin(a)
        let lat = p.latitude + dy / Course.earthRadius * 180 / .pi
        let lon = p.longitude + dx / (Course.earthRadius * cos(p.latitude * .pi / 180)) * 180 / .pi
        return (lat, lon)
    }

    func testLocateWithNoiseOnALoop() throws {
        let course = try GPXParser.parse(GPXFixtures.flatLoop)
        var rng = TestRNG(seed: 99)
        var last = 0.0
        for d in stride(from: 0.0, through: course.totalDistance - 1, by: 25) {
            let (lat, lon) = noisy(course, at: d, rng: &rng, radius: 8)
            let loc = course.locate(latitude: lat, longitude: lon, near: last)
            XCTAssertEqual(loc.distance, d, accuracy: 10, "at \(d)")
            XCTAssertFalse(loc.offCourse)
            last = loc.distance
        }
    }

    func testLocateDoesNotJumpAcrossAnOutAndBack() throws {
        let course = try GPXParser.parse(GPXFixtures.outAndBack)
        XCTAssertEqual(course.totalDistance, 2000, accuracy: 2)
        var rng = TestRNG(seed: 5)
        var last = 0.0
        for d in stride(from: 0.0, through: 2000, by: 20) {
            let (lat, lon) = noisy(course, at: d, rng: &rng, radius: 8)
            let loc = course.locate(latitude: lat, longitude: lon, near: last)
            XCTAssertEqual(loc.distance, d, accuracy: 10, "at \(d)")
            last = loc.distance
        }

        // Same spot, 300 m east: out leg on the way out, back leg on the way back.
        let p = course.position(at: 300)
        XCTAssertEqual(course.locate(latitude: p.latitude, longitude: p.longitude, near: 280).distance, 300, accuracy: 1)
        XCTAssertEqual(course.locate(latitude: p.latitude, longitude: p.longitude, near: 1680).distance, 1700, accuracy: 1)
    }

    func testPointFarFromRouteIsOffCourse() throws {
        let course = try GPXParser.parse(GPXFixtures.waypoints)
        let far = GPXFixtures.latLon(1200, 80)
        let loc = course.locate(latitude: far.lat, longitude: far.lon, near: 1150)
        XCTAssertTrue(loc.offCourse)
        XCTAssertEqual(loc.offset, 80, accuracy: 1)
        XCTAssertEqual(loc.distance, 1200, accuracy: 2)

        let near = GPXFixtures.latLon(1200, 20)
        XCTAssertFalse(course.locate(latitude: near.lat, longitude: near.lon, near: 1150).offCourse)
    }

    func testLocateWithoutHistorySearchesWholeCourse() throws {
        let course = try GPXParser.parse(GPXFixtures.waypoints)
        let p = GPXFixtures.latLon(2600, -5)
        XCTAssertEqual(course.locate(latitude: p.lat, longitude: p.lon).distance, 2600, accuracy: 2)
    }
}
