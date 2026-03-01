//
//  HRZone.swift
//  Halo
//
//  Heart rate zone model. Supports two modes:
//  1. Exact OTF boundaries (default) — matches your Orangetheory HR zones screen
//  2. Percentage-based — recalculates from max HR if you change it
//

import SwiftUI

struct HRZoneConfig: Codable, Equatable {
    var maxHR: Int

    /// Custom zone boundaries: [zone1Low, zone2Low, zone3Low, zone4Low, zone5Low]
    /// When nil, uses percentage-based calculation.
    /// Default for 178 max HR: exact OTF values from your profile.
    var customBoundaries: [Int]?

    /// Percentage floors used when customBoundaries is nil.
    /// Zone 1: 50-60%, Zone 2: 61-70%, Zone 3: 71-84%, Zone 4: 84-92%, Zone 5: 92-100%
    static let percentFloors: [Double] = [0.50, 0.612, 0.708, 0.843, 0.921]

    /// Default config: 178 max HR with exact OTF boundaries from your screenshot.
    static let `default` = HRZoneConfig(
        maxHR: 178,
        customBoundaries: [89, 109, 126, 150, 164]
    )

    /// The 5 lower-bound BPMs for zones 1-5.
    var zoneLowerBounds: [Int] {
        if let custom = customBoundaries, custom.count == 5 {
            return custom
        }
        return Self.percentFloors.map { Int(Double(maxHR) * $0) }
    }

    func zone(for bpm: Int) -> HRZone {
        guard bpm > 0 else { return .rest }
        let bounds = zoneLowerBounds
        if bpm >= bounds[4] { return .zone5 }
        if bpm >= bounds[3] { return .zone4 }
        if bpm >= bounds[2] { return .zone3 }
        if bpm >= bounds[1] { return .zone2 }
        if bpm >= bounds[0] { return .zone1 }
        return .rest
    }

    func bpmRange(for zone: HRZone) -> ClosedRange<Int> {
        let bounds = zoneLowerBounds
        switch zone {
        case .rest:
            return 0...max(0, bounds[0] - 1)
        case .zone1:
            return bounds[0]...max(bounds[0], bounds[1] - 1)
        case .zone2:
            return bounds[1]...max(bounds[1], bounds[2] - 1)
        case .zone3:
            return bounds[2]...max(bounds[2], bounds[3] - 1)
        case .zone4:
            return bounds[3]...max(bounds[3], bounds[4] - 1)
        case .zone5:
            return bounds[4]...maxHR
        }
    }

    /// Recalculate from a new max HR. If the user changes max HR, we switch to
    /// percentage-based unless their custom boundaries still make sense.
    func withMaxHR(_ newMax: Int) -> HRZoneConfig {
        if newMax == 178 {
            // Restore exact OTF defaults for 178
            return .default
        }
        // For any other max HR, use percentage-based
        return HRZoneConfig(maxHR: newMax, customBoundaries: nil)
    }
}

/// Which finger the ring is worn on. Affects PPG signal quality notes.
enum RingFinger: String, Codable, CaseIterable, Identifiable {
    case index = "Index"
    case middle = "Middle"
    case ring = "Ring"

    var id: String { rawValue }

    var sensorNote: String {
        switch self {
        case .index:
            return "Strong signal. Index fingers have high blood flow and consistent skin contact. Great for workouts."
        case .middle:
            return "Strong signal. Middle fingers are the most stable fit for most hand shapes. Excellent all-around choice."
        case .ring:
            return "Good signal. Ring fingers work well but may have slightly looser fit. Make sure it doesn't spin during exercise."
        }
    }

    var fitTip: String {
        switch self {
        case .index:
            return "Wear on the non-dominant hand to avoid bumping it on equipment."
        case .middle:
            return "Most people get the best overnight readings on the middle finger."
        case .ring:
            return "If it spins freely, size down — the sensor must maintain consistent skin contact."
        }
    }
}

enum HRZone: Int, CaseIterable, Codable {
    case rest = 0
    case zone1 = 1
    case zone2 = 2
    case zone3 = 3
    case zone4 = 4
    case zone5 = 5

    var label: String {
        switch self {
        case .rest:  return "Rest"
        case .zone1: return "Zone 1"
        case .zone2: return "Zone 2"
        case .zone3: return "Zone 3"
        case .zone4: return "Zone 4"
        case .zone5: return "Zone 5"
        }
    }

    var subtitle: String {
        switch self {
        case .rest:  return "Below 50%"
        case .zone1: return "Very Light"
        case .zone2: return "Light"
        case .zone3: return "Moderate"
        case .zone4: return "Hard"
        case .zone5: return "All Out"
        }
    }

    var color: Color {
        switch self {
        case .rest:  return .gray.opacity(0.5)
        case .zone1: return Color(red: 0.6, green: 0.6, blue: 0.6)   // Gray
        case .zone2: return Color(red: 0.0, green: 0.55, blue: 0.85)  // Blue
        case .zone3: return Color(red: 0.2, green: 0.75, blue: 0.2)   // Green
        case .zone4: return Color(red: 1.0, green: 0.55, blue: 0.0)   // Orange
        case .zone5: return Color(red: 0.9, green: 0.1, blue: 0.1)    // Red
        }
    }

    /// Darker variant for background gradients (dark mode).
    var darkColor: Color {
        switch self {
        case .rest:  return Color(red: 0.15, green: 0.15, blue: 0.15)
        case .zone1: return Color(red: 0.25, green: 0.25, blue: 0.25)
        case .zone2: return Color(red: 0.0, green: 0.2, blue: 0.4)
        case .zone3: return Color(red: 0.05, green: 0.3, blue: 0.05)
        case .zone4: return Color(red: 0.45, green: 0.2, blue: 0.0)
        case .zone5: return Color(red: 0.4, green: 0.0, blue: 0.0)
        }
    }

    /// Lighter variant for background gradients (light mode).
    var lightColor: Color {
        switch self {
        case .rest:  return Color(red: 0.94, green: 0.94, blue: 0.94)
        case .zone1: return Color(red: 0.90, green: 0.90, blue: 0.90)
        case .zone2: return Color(red: 0.85, green: 0.92, blue: 1.0)
        case .zone3: return Color(red: 0.85, green: 0.96, blue: 0.85)
        case .zone4: return Color(red: 1.0, green: 0.92, blue: 0.82)
        case .zone5: return Color(red: 1.0, green: 0.88, blue: 0.88)
        }
    }

    /// Haptic intensity for zone transitions.
    var hapticIntensity: CGFloat {
        switch self {
        case .rest:  return 0.2
        case .zone1: return 0.3
        case .zone2: return 0.5
        case .zone3: return 0.7
        case .zone4: return 0.9
        case .zone5: return 1.0
        }
    }
}
