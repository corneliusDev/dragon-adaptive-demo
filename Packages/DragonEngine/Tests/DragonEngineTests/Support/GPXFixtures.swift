//  GPXFixtures.swift
//  Small hand-drawn courses for the plan/course tests. Each is drawn in local
//  east/north metres around a fixed origin and written out as GPX text, so
//  the test knows exactly where the hill, turn or waypoint was drawn.

import Foundation

enum GPXFixtures {
    static let origin = (lat: 47.6062, lon: -122.3321)
    private static let r = 6_371_000.0

    struct P {
        var x: Double
        var y: Double
        var ele: Double?
    }

    static func latLon(_ x: Double, _ y: Double) -> (lat: Double, lon: Double) {
        let lat = origin.lat + y / r * 180 / .pi
        let lon = origin.lon + x / (r * cos(origin.lat * .pi / 180)) * 180 / .pi
        return (lat, lon)
    }

    static func gpx(_ points: [P], waypoints: [(name: String, x: Double, y: Double)] = []) -> String {
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        s += "<gpx version=\"1.1\" creator=\"fixture\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n"
        for w in waypoints {
            let c = latLon(w.x, w.y)
            s += "  <wpt lat=\"\(c.lat)\" lon=\"\(c.lon)\"><name>\(w.name)</name></wpt>\n"
        }
        s += "  <trk><name>fixture</name><trkseg>\n"
        for p in points {
            let c = latLon(p.x, p.y)
            if let e = p.ele {
                s += "    <trkpt lat=\"\(c.lat)\" lon=\"\(c.lon)\"><ele>\(e)</ele></trkpt>\n"
            } else {
                s += "    <trkpt lat=\"\(c.lat)\" lon=\"\(c.lon)\"></trkpt>\n"
            }
        }
        s += "  </trkseg></trk>\n</gpx>\n"
        return s
    }

    /// Circle of radius 250 m (≈1571 m), flat at 12 m, a point every ~10 m.
    static var flatLoop: String {
        let n = 157
        let pts = (0...n).map { i -> P in
            let a = Double(i) / Double(n) * 2 * .pi
            return P(x: 250 * sin(a), y: 250 * cos(a) - 250, ele: 12)
        }
        return gpx(pts)
    }

    /// 2 km due east. Flat at 30 m to 600 m, a 5% climb from 600 m to 1000 m
    /// (20 m gain), then flat at 50 m. Optional ±`jitter` m seeded noise on ele.
    static func hill(jitter: Double = 0, seed: UInt64 = 3) -> String {
        var rng = TestRNG(seed: seed)
        let pts = stride(from: 0.0, through: 2000, by: 10).map { x -> P in
            let base = x < 600 ? 30 : x < 1000 ? 30 + (x - 600) * 0.05 : 50
            return P(x: x, y: 0, ele: base + (jitter > 0 ? rng.uniform(-jitter...jitter) : 0))
        }
        return gpx(pts)
    }
    static let hillStart = 600.0, hillEnd = 1000.0, hillGain = 20.0

    /// 500 m north, a radius-10 m hairpin to the right, then 500 m south.
    /// The apex of the hairpin is at 500 + 10π/2 ≈ 515.7 m along the route.
    static var hairpin: String {
        var pts = stride(from: 0.0, through: 500, by: 10).map { P(x: 0, y: $0, ele: 5) }
        for i in 1..<12 {
            let a = Double(i) / 12 * .pi
            pts.append(P(x: 10 - 10 * cos(a), y: 500 + 10 * sin(a), ele: 5))
        }
        pts += stride(from: 500.0, through: 0, by: -10).map { P(x: 20, y: $0, ele: 5) }
        return gpx(pts)
    }
    static let hairpinApex = 500 + 10 * Double.pi / 2

    /// 3.01 km due east with two aid-station waypoints a little off the road and
    /// one far-away waypoint (parking) that isn't on the course.
    static var waypoints: String {
        let pts = stride(from: 0.0, through: 3010, by: 10).map { P(x: $0, y: 0, ele: 8) }
        return gpx(pts, waypoints: [
            ("Aid 2", 2000, -12),
            ("Aid 1", 1000, 15),
            ("Parking", 1500, 400),
        ])
    }

    /// 1 km east then straight back on the same road: legs overlap exactly.
    static var outAndBack: String {
        let out = stride(from: 0.0, through: 1000, by: 10).map { P(x: $0, y: 0, ele: 20) }
        let back = stride(from: 990.0, through: 0, by: -10).map { P(x: $0, y: 0, ele: 20) }
        return gpx(out + back)
    }

    /// Hand-written, no <ele> anywhere, with a namespace prefix and two segments.
    static let noElevation = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx:gpx version="1.1" creator="hand" xmlns:gpx="http://www.topografix.com/GPX/1/1">
      <gpx:trk>
        <gpx:name>No elevation</gpx:name>
        <gpx:trkseg>
          <gpx:trkpt lat="47.6062" lon="-122.3321"/>
          <gpx:trkpt lat="47.6071" lon="-122.3321"/>
          <gpx:trkpt lat="47.6080" lon="-122.3321"/>
        </gpx:trkseg>
        <gpx:trkseg>
          <gpx:trkpt lat="47.6089" lon="-122.3321"/>
          <gpx:trkpt lat="47.6098" lon="-122.3321"/>
        </gpx:trkseg>
      </gpx:trk>
    </gpx:gpx>
    """
}

/// SplitMix64, so fixture noise is the same every run.
struct TestRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform(_ range: ClosedRange<Double>) -> Double {
        Double.random(in: range, using: &self)
    }
}
