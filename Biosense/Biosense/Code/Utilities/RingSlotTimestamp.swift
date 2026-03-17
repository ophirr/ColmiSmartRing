//
//  RingSlotTimestamp.swift
//  Biosense
//
//  Single source of truth for UTC slot-to-timestamp conversion.
//  The ring stores all periodic measurements (HR, HRV, Stress, SpO2)
//  as slot arrays indexed from UTC midnight. This enum owns the UTC
//  calendar and all anchor arithmetic so there is exactly one place
//  to get wrong (or right).
//

import Foundation

enum RingSlotTimestamp {
    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// UTC start-of-day for a given date.
    static func utcStartOfDay(for date: Date = Date()) -> Date {
        utcCalendar.startOfDay(for: date)
    }

    /// Absolute timestamp for slot index in a UTC-midnight-anchored array.
    /// Used by HR log (288 slots × 5 min) and HRV/Stress split-series.
    static func date(slot: Int, rangeMinutes: Int, utcDayStart: Date? = nil) -> Date {
        let anchor = utcDayStart ?? utcStartOfDay()
        return anchor.addingTimeInterval(TimeInterval(slot * max(rangeMinutes, 1) * 60))
    }

    /// Absolute timestamp for a (daysAgo, hour) pair — SpO2 format.
    /// The ring reports SpO2 as 24 hourly pairs per day, indexed from UTC midnight.
    static func date(daysAgo: Int, hour: Int, referenceDate: Date = Date()) -> Date {
        let todayUTC = utcStartOfDay(for: referenceDate)
        let dayUTC = utcCalendar.date(byAdding: .day, value: -daysAgo, to: todayUTC) ?? todayUTC
        return utcCalendar.date(bySettingHour: max(0, min(23, hour)), minute: 0, second: 0, of: dayUTC) ?? dayUTC
    }
}
