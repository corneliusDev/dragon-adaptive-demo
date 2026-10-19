//  SampleCourseTests.swift
//  The bundled sample GPX the course debug sheet shows loads and has the
//  features it was drawn with: a 4% climb, a hairpin turnaround, waypoints.

import XCTest
import DragonEngine
@testable import Dragon_Adaptive

final class SampleCourseTests: XCTestCase {
    func testBundledSampleCourseLoadsWithFeatures() throws {
        let course = try CourseDebugView.loadSample().get()
        XCTAssertTrue(course.hasElevation)
        XCTAssertEqual(course.totalDistance, 5250, accuracy: 30)
        XCTAssertEqual(course.markers(every: .miles).count, 3)
        XCTAssertEqual(course.markers(every: .kilometers).count, 5)

        let hills = course.hills()
        XCTAssertEqual(hills.count, 1)
        XCTAssertEqual(hills.first?.startDistance ?? 0, 1200, accuracy: 20)
        XCTAssertEqual(hills.first?.endDistance ?? 0, 1700, accuracy: 20)

        let turns = course.turns()
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.distance ?? 0, 2600 + 15 * .pi / 2, accuracy: 20)

        XCTAssertEqual(course.aidStations().map(\.name), ["Water 1", "Water 2", "Gels"])
    }
}
