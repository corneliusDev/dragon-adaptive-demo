//  CourseDebugView.swift
//  Debug sheet: loads the bundled SampleCourse.gpx through the engine and lists
//  what it found. Engine numbers are metres; miles/km formatting happens here.

import SwiftUI
import DragonEngine

struct CourseDebugView: View {
    @State private var unit: DistanceUnit = .miles
    private let loaded: Result<Course, Error> = CourseDebugView.loadSample()

    static func loadSample() -> Result<Course, Error> {
        Result {
            guard let url = Bundle.main.url(forResource: "SampleCourse", withExtension: "gpx") else {
                throw CocoaError(.fileNoSuchFile)
            }
            return try GPXParser.parse(Data(contentsOf: url))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                switch loaded {
                case .failure(let error):
                    Text("Couldn't load SampleCourse.gpx: \(error.localizedDescription)")
                case .success(let course):
                    content(course)
                }
            }
            .font(.system(size: 13, design: .monospaced))
            .navigationTitle("Course debug")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private func content(_ course: Course) -> some View {
        Section {
            Picker("Units", selection: $unit) {
                Text("MILES").tag(DistanceUnit.miles)
                Text("KM").tag(DistanceUnit.kilometers)
            }
            .pickerStyle(.segmented)
            row("Length", dist(course.totalDistance))
            row("Points", "\(course.points.count)")
            row("Elevation", course.hasElevation ? "yes" : "missing")
        }
        Section("Markers") {
            ForEach(course.markers(every: unit), id: \.number) { m in
                row("\(m.number) \(unitLabel)", dist(m.distance))
            }
        }
        Section("Hills") {
            ForEach(Array(course.hills().enumerated()), id: \.offset) { _, h in
                row("\(dist(h.startDistance)) → \(dist(h.endDistance))",
                    String(format: "+%.0f m  %.1f%%", h.gain, h.averageGrade * 100))
            }
        }
        Section("Turns") {
            ForEach(Array(course.turns().enumerated()), id: \.offset) { _, t in
                row(dist(t.distance), String(format: "%@ %.0f°", t.angle > 0 ? "R" : "L", abs(t.angle)))
            }
        }
        Section("Aid stations") {
            ForEach(Array(course.aidStations().enumerated()), id: \.offset) { _, a in
                row(a.name, "\(dist(a.distance))  (\(Int(a.offset.rounded())) m off)")
            }
        }
    }

    private var unitLabel: String { unit == .miles ? "mi" : "km" }

    private func dist(_ meters: Double) -> String {
        String(format: "%.2f %@", meters / unit.meters, unitLabel)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k)
            Spacer()
            Text(v).foregroundColor(.secondary)
        }
    }
}
