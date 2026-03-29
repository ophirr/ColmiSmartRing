//
//  SwiftDataModels.swift
//  Biosense
//
//  SwiftData models for persisting sleep and heart rate data from the ring.
//

import Foundation
import SwiftData

// MARK: - Sleep

/// One period within a stored sleep day (e.g. 30 min deep sleep).
@Model
final class StoredSleepPeriod {
    var sleepTypeRaw: Int
    var minutes: Int
    /// Absolute start timestamp for this segment, computed from sleep start + cumulative minutes.
    var startTimestamp: Date

    var sleepType: SleepType {
        get { SleepType(rawValue: UInt8(sleepTypeRaw)) ?? .noData }
        set { sleepTypeRaw = Int(newValue.rawValue) }
    }

    var day: StoredSleepDay?

    init(type: SleepType, minutes: Int, startTimestamp: Date) {
        self.sleepTypeRaw = Int(type.rawValue)
        self.minutes = minutes
        self.startTimestamp = startTimestamp
    }

    init(sleepTypeRaw: Int, minutes: Int, startTimestamp: Date) {
        self.sleepTypeRaw = sleepTypeRaw
        self.minutes = minutes
        self.startTimestamp = startTimestamp
    }
}

/// One day's sleep stored in SwiftData. Maps from Big Data SleepDay.
@Model
final class StoredSleepDay {
    var daysAgo: Int
    var sleepStart: Int
    var sleepEnd: Int
    var syncDate: Date
    /// The actual calendar date of this sleep night (start-of-day). Used for deduplication
    /// so that data is preserved across syncs instead of being overwritten by `daysAgo` shifts.
    /// Default value allows lightweight migration from older schema without this field.
    var nightDate: Date = Date.distantPast

    @Relationship(deleteRule: .cascade, inverse: \StoredSleepPeriod.day)
    var periods: [StoredSleepPeriod] = []

    init(daysAgo: Int, sleepStart: Int, sleepEnd: Int, syncDate: Date = Date(), nightDate: Date? = nil, periods: [StoredSleepPeriod]) {
        self.daysAgo = daysAgo
        self.sleepStart = sleepStart
        self.sleepEnd = sleepEnd
        self.syncDate = syncDate
        let calendar = Calendar.current
        self.nightDate = nightDate ?? calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: syncDate)) ?? syncDate
        self.periods = periods
        for p in periods {
            p.day = self
        }
    }

    /// Calendar date of this sleep night. Now backed by stored `nightDate` field.
    var sleepDate: Date {
        nightDate
    }

    /// Convert to the in-memory SleepDay struct for use with existing graph views.
    func toSleepDay() -> SleepDay {
        // Reconstruct timeline in true chronological order based on persisted segment timestamps.
        let storedPeriods = periods
            .sorted { lhs, rhs in
                if lhs.startTimestamp != rhs.startTimestamp { return lhs.startTimestamp < rhs.startTimestamp }
                return String(describing: lhs.persistentModelID) < String(describing: rhs.persistentModelID)
            }
            .map { SleepPeriod(type: sleepType(from: $0.sleepTypeRaw), minutes: UInt8($0.minutes)) }
        return SleepDay(
            daysAgo: UInt8(daysAgo),
            curDayBytes: 0,
            sleepStart: Int16(sleepStart),
            sleepEnd: Int16(sleepEnd),
            periods: storedPeriods
        )
    }

    private func sleepType(from raw: Int) -> SleepType {
        SleepType(rawValue: UInt8(raw)) ?? .noData
    }
}

// MARK: - Heart rate

/// Stored heart rate log from the ring (one day's 5‑minute readings).
@Model
final class StoredHeartRateLog {
    var timestamp: Date
    /// Start of day for this log (for deduplication: one log per calendar day).
    var dayStart: Date
    var heartRates: [Int]
    var size: Int
    var index: Int
    var range: Int

    init(timestamp: Date, heartRates: [Int], size: Int, index: Int, range: Int) {
        self.timestamp = timestamp
        self.dayStart = Calendar.current.startOfDay(for: timestamp)
        self.heartRates = heartRates
        self.size = size
        self.index = index
        self.range = range
    }

    /// Create from the in-memory HeartRateLog (e.g. after parsing BLE response).
    static func from(_ log: HeartRateLog) -> StoredHeartRateLog {
        StoredHeartRateLog(
            timestamp: log.timestamp,
            heartRates: log.heartRates,
            size: log.size,
            index: log.index,
            range: log.range
        )
    }

    /// Convert to HeartRateLog for use with heartRatesWithTimes() and UI.
    /// The ring stores data in UTC-indexed slots (slot 0 = 00:00 UTC), but the chart
    /// anchors at local midnight. We rotate the array by the UTC offset so that
    /// e.g. UTC slot 216 (18:00 UTC = 11:00 PDT) displays at the 11:00 position.
    func toHeartRateLog() -> HeartRateLog {
        let effectiveRange = max(range, 1)
        let slotsPerDay = (24 * 60) / effectiveRange  // 288 at 5-min, 1440 at 1-min

        // UTC offset in seconds (positive = east of UTC, negative = west).
        // For PDT (UTC-7): offsetSeconds = -25200 → shift = -84 slots → rotate right by 84
        let offsetSeconds = TimeZone.current.secondsFromGMT(for: dayStart)
        let shiftSlots = offsetSeconds / (effectiveRange * 60)

        var shifted = heartRates
        if shiftSlots != 0 && shifted.count >= slotsPerDay {
            // Ensure we work with exactly slotsPerDay entries
            shifted = Array(shifted.prefix(slotsPerDay))
            // Rotate: positive shift moves data forward (east of UTC), negative moves back (west)
            let normalizedShift = ((shiftSlots % slotsPerDay) + slotsPerDay) % slotsPerDay
            if normalizedShift > 0 {
                let tail = Array(shifted.suffix(normalizedShift))
                let head = Array(shifted.prefix(shifted.count - normalizedShift))
                shifted = tail + head
            }
        }

        // Zero out future slots for today so the chart doesn't show stale/zero data ahead of now.
        if Calendar.current.isDateInToday(dayStart) {
            let totalMinutes = Int(Date().timeIntervalSince(Calendar.current.startOfDay(for: Date())) / 60)
            let slotsElapsed = totalMinutes / effectiveRange
            for i in slotsElapsed..<shifted.count {
                shifted[i] = 0
            }
        }

        return HeartRateLog(
            heartRates: shifted,
            timestamp: dayStart,
            size: size,
            index: index,
            range: range
        )
    }
}

// MARK: - Activity / Metrics samples

/// Stored activity sample for one timestamp (steps, distance, calories).
@Model
final class StoredActivitySample {
    var timestamp: Date
    var steps: Int
    var distanceKm: Double
    var calories: Int

    init(timestamp: Date, steps: Int, distanceKm: Double, calories: Int) {
        self.timestamp = timestamp
        self.steps = steps
        self.distanceKm = distanceKm
        self.calories = calories
    }
}

/// Stored HRV sample for one timestamp.
@Model
final class StoredHRVSample {
    var timestamp: Date
    var value: Double

    init(timestamp: Date, value: Double) {
        self.timestamp = timestamp
        self.value = value
    }
}

/// Stored blood oxygen sample for one timestamp.
@Model
final class StoredBloodOxygenSample {
    var timestamp: Date
    var value: Double

    init(timestamp: Date, value: Double) {
        self.timestamp = timestamp
        self.value = value
    }
}

/// Stored stress sample for one timestamp.
@Model
final class StoredStressSample {
    var timestamp: Date
    var value: Double

    init(timestamp: Date, value: Double) {
        self.timestamp = timestamp
        self.value = value
    }
}

// MARK: - HealthKit-imported samples

/// Glucose reading imported from HealthKit (e.g., Stelo CGM).
@Model
final class StoredGlucoseSample {
    var timestamp: Date
    var valueMgdl: Double
    var sourceBundle: String

    init(timestamp: Date, valueMgdl: Double, sourceBundle: String) {
        self.timestamp = timestamp
        self.valueMgdl = valueMgdl
        self.sourceBundle = sourceBundle
    }
}

/// Phone activity imported from HealthKit (iPhone pedometer).
@Model
final class StoredPhoneStepSample {
    var timestamp: Date   // start of hour bucket
    var steps: Int
    var distanceKm: Double = 0
    var calories: Int = 0

    init(timestamp: Date, steps: Int, distanceKm: Double = 0, calories: Int = 0) {
        self.timestamp = timestamp
        self.steps = steps
        self.distanceKm = distanceKm
        self.calories = calories
    }
}
