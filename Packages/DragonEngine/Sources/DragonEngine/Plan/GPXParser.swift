//  GPXParser.swift
//  Reads a GPX file into a Course with Foundation's XMLParser: every
//  trk/trkseg/trkpt (with optional <ele>), joined in order, plus <wpt>
//  waypoints with their <name>. Namespace prefixes are ignored.

import Foundation

public enum GPXError: Error, Equatable {
    case malformed(String)
    case noTrackPoints
}

public enum GPXParser {
    public static func parse(_ data: Data) throws -> Course {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw GPXError.malformed(parser.parserError?.localizedDescription ?? "unknown XML error")
        }
        guard !delegate.track.isEmpty else { throw GPXError.noTrackPoints }
        return Course(track: delegate.track, waypoints: delegate.waypoints)
    }

    public static func parse(_ string: String) throws -> Course {
        try parse(Data(string.utf8))
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var track: [TrackPoint] = []
        var waypoints: [Waypoint] = []

        private var inTrack = false
        private var point: TrackPoint?
        private var waypoint: Waypoint?
        private var text = ""

        private static func local(_ name: String) -> String {
            name.split(separator: ":").last.map(String.init)?.lowercased() ?? name.lowercased()
        }

        private static func coordinate(_ attrs: [String: String]) -> (Double, Double)? {
            guard let lat = attrs["lat"].flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
                  let lon = attrs["lon"].flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
                  (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
            return (lat, lon)
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            text = ""
            switch Delegate.local(elementName) {
            case "trk":
                inTrack = true
            case "trkpt" where inTrack:
                if let (lat, lon) = Delegate.coordinate(attributeDict) {
                    point = TrackPoint(latitude: lat, longitude: lon)
                }
            case "wpt":
                if let (lat, lon) = Delegate.coordinate(attributeDict) {
                    waypoint = Waypoint(name: "", latitude: lat, longitude: lon)
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch Delegate.local(elementName) {
            case "ele":
                if point != nil { point?.elevation = Double(value) }
            case "name":
                if waypoint != nil { waypoint?.name = value }
            case "trkpt":
                if let p = point { track.append(p) }
                point = nil
            case "wpt":
                if let w = waypoint { waypoints.append(w) }
                waypoint = nil
            case "trk":
                inTrack = false
            default:
                break
            }
            text = ""
        }
    }
}
