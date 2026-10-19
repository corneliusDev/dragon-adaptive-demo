//  DistanceUnit.swift
//  The engine works in metres and seconds. This only exists so callers can ask
//  for things "per mile" or "every kilometre"; turning numbers into "8:00 /mi"
//  strings is render/UI work.

import Foundation

public enum DistanceUnit: String, Sendable, CaseIterable {
    case miles
    case kilometers

    public static let metersPerMile = 1609.344
    public static let metersPerKilometer = 1000.0

    public var meters: Double {
        switch self {
        case .miles: return DistanceUnit.metersPerMile
        case .kilometers: return DistanceUnit.metersPerKilometer
        }
    }
}
