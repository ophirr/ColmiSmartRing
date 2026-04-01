//
//  RestingHRComputer.swift
//  Biosense
//
//  Computes resting heart rate from overnight HR logs overlaid with sleep windows.
//  Pure function — no SwiftData dependency, takes arrays as input for testability.
//

import Foundation

struct RestingHRResult {
    let restingBPM: Int
    let confidence: Double   // 0.5–1.0 based on sample count
    let sampleCount: Int
}

struct RestingHRComputer {

    /// Minimum valid readings during sleep to produce an estimate.
    private static let minSamples = 20

    /// Compute resting HR for a single night by overlaying sleep timing onto the HR log.
    /// Returns nil if insufficient data.
    static func compute(hrLog: StoredHeartRateLog, sleepDay: StoredSleepDay) -> RestingHRResult? {
        let log = hrLog.toHeartRateLog()
        let hrs = log.heartRates
        let range = max(hrLog.range, 1)
        let slotsPerDay = (24 * 60) / range

        guard hrs.count >= slotsPerDay else { return nil }

        // sleepStart and sleepEnd are minute-of-day in local time.
        // The HR log is already rotated to local time by toHeartRateLog().
        let startMinute = Int(sleepDay.sleepStart)
        let endMinute = Int(sleepDay.sleepEnd)

        let startSlot = startMinute / range
        let endSlot = endMinute / range

        // Collect HR values during sleep window
        var sleepHRValues: [Int] = []

        if startSlot <= endSlot {
            // Same-day sleep (e.g., nap): slots startSlot..<endSlot
            for i in startSlot..<min(endSlot, slotsPerDay) {
                let hr = hrs[i]
                if hr > 0 { sleepHRValues.append(hr) }
            }
        } else {
            // Overnight sleep: startSlot..end of day, then 0..<endSlot
            for i in startSlot..<slotsPerDay {
                let hr = hrs[i]
                if hr > 0 { sleepHRValues.append(hr) }
            }
            // Next day's early morning — use the same log (slots wrap within one log day)
            for i in 0..<min(endSlot, slotsPerDay) {
                let hr = hrs[i]
                if hr > 0 { sleepHRValues.append(hr) }
            }
        }

        guard sleepHRValues.count >= minSamples else { return nil }

        // 5th percentile — more robust than absolute minimum (catches sensor glitches)
        sleepHRValues.sort()
        let percentileIndex = max(0, Int(Double(sleepHRValues.count) * 0.05))
        let restingBPM = sleepHRValues[percentileIndex]

        // Confidence: 1.0 at 60+ samples, linear to 0.5 at minSamples
        let confidence = min(1.0, 0.5 + 0.5 * Double(sleepHRValues.count - minSamples) / Double(60 - minSamples))

        return RestingHRResult(
            restingBPM: restingBPM,
            confidence: confidence,
            sampleCount: sleepHRValues.count
        )
    }

    /// Compute 7-day median resting HR from multiple nights.
    /// Returns nil if fewer than 3 valid nights.
    static func weeklyMedian(hrLogs: [StoredHeartRateLog], sleepDays: [StoredSleepDay]) -> RestingHRResult? {
        // Match logs to sleep days by calendar date
        var results: [RestingHRResult] = []

        for sleepDay in sleepDays {
            let sleepDate = sleepDay.sleepDate
            if let matchingLog = hrLogs.first(where: {
                Calendar.current.isDate($0.dayStart, inSameDayAs: sleepDate)
            }) {
                if let result = compute(hrLog: matchingLog, sleepDay: sleepDay) {
                    results.append(result)
                }
            }
        }

        guard results.count >= 3 else { return nil }

        let sorted = results.sorted { $0.restingBPM < $1.restingBPM }
        let median = sorted[sorted.count / 2]
        let avgConfidence = results.reduce(0.0) { $0 + $1.confidence } / Double(results.count)

        return RestingHRResult(
            restingBPM: median.restingBPM,
            confidence: avgConfidence,
            sampleCount: results.reduce(0) { $0 + $1.sampleCount }
        )
    }
}
