//
//  TimeRange.swift
//  Biosense
//
//  Time range selection for metrics charts.
//

import Foundation

enum TimeRange: String, CaseIterable, Identifiable {
    case hour1, hour6, hour12, day, week, month
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hour1:  return String(localized: "1H")
        case .hour6:  return String(localized: "6H")
        case .hour12: return String(localized: "12H")
        case .day:    return String(localized: "Day")
        case .week:   return String(localized: "Week")
        case .month:  return String(localized: "Month")
        }
    }

    /// Whether this range shows sub-day (non-aggregated) data.
    var isSubDay: Bool {
        switch self {
        case .hour1, .hour6, .hour12, .day: return true
        case .week, .month: return false
        }
    }

    /// Duration in seconds for sub-day ranges.
    var durationSeconds: TimeInterval {
        switch self {
        case .hour1:  return 3_600
        case .hour6:  return 21_600
        case .hour12: return 43_200
        case .day:    return 86_400
        case .week:   return 604_800
        case .month:  return 2_592_000 // ~30 days, approximate
        }
    }
}
