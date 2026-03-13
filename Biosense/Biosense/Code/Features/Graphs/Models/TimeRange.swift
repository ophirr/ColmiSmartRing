//
//  TimeRange.swift
//  Biosense
//
//  Time range selection for metrics charts (day / week / month).
//

import Foundation

enum TimeRange: String, CaseIterable, Identifiable {
    case day, week, month
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .day:   return String(localized: "Day")
        case .week:  return String(localized: "Week")
        case .month: return String(localized: "Month")
        }
    }
}
