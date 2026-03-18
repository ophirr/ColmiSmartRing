//
//  BatteryEstimator.swift
//  Biosense
//
//  Computes battery life estimates from observed drain history.
//  Stores recent battery samples in UserDefaults and calculates
//  drain rate (% per hour) from non-charging samples.
//

import Foundation

/// Tracks battery level over time and estimates remaining life
/// from the observed drain rate.
final class BatteryEstimator {

    /// Persisted battery sample: level + timestamp.
    private struct Sample: Codable {
        let level: Int
        let charging: Bool
        let time: Date
    }

    private static let storageKey = "batteryDrainHistory"
    /// Keep up to 7 days of samples (~10,080 at 1/min).
    private static let maxSamples = 10_080
    /// Minimum non-charging samples needed for a reliable estimate.
    private static let minSamplesForEstimate = 30
    /// Minimum time span (hours) of drain data needed.
    private static let minHoursForEstimate: Double = 1.0

    private var samples: [Sample] = []

    init() {
        loadSamples()
    }

    // MARK: - Record

    /// Record a new battery reading. Call on every keepalive response.
    func record(level: Int, charging: Bool) {
        let sample = Sample(level: level, charging: charging, time: Date())
        samples.append(sample)

        // Trim old samples
        if samples.count > Self.maxSamples {
            samples.removeFirst(samples.count - Self.maxSamples)
        }

        saveSamples()
    }

    // MARK: - Estimate

    /// Returns an estimated battery life string based on observed drain rate.
    /// Falls back to nil if insufficient data.
    func estimatedTimeRemaining(currentLevel: Int) -> String? {
        let drainRate = computeDrainRatePerHour()
        guard let rate = drainRate, rate > 0.1 else { return nil }

        let hoursRemaining = Double(currentLevel) / rate

        if hoursRemaining < 1.0 {
            return "< 1h left"
        } else if hoursRemaining < 24 {
            return "~\(Int(hoursRemaining))h left"
        } else {
            let days = hoursRemaining / 24.0
            if days < 1.5 {
                return "~\(Int(hoursRemaining))h left"
            } else {
                return String(format: "~%.1fd left", days)
            }
        }
    }

    /// Returns the drain rate in %/hour, or nil if insufficient data.
    func computeDrainRatePerHour() -> Double? {
        // Only use non-charging samples for drain calculation.
        let drainSamples = samples.filter { !$0.charging }
        guard drainSamples.count >= Self.minSamplesForEstimate else { return nil }

        // Find drain segments: consecutive non-charging periods where level decreases.
        // Use a simple approach: look at the overall level drop over the time span.
        guard let first = drainSamples.first, let last = drainSamples.last else { return nil }

        let hoursElapsed = last.time.timeIntervalSince(first.time) / 3600.0
        guard hoursElapsed >= Self.minHoursForEstimate else { return nil }

        let levelDrop = first.level - last.level
        guard levelDrop > 0 else { return nil }  // Level went up or stayed same — charging mixed in

        return Double(levelDrop) / hoursElapsed
    }

    /// Returns a human-readable drain rate string, e.g. "2.1%/hr".
    func drainRateString() -> String? {
        guard let rate = computeDrainRatePerHour() else { return nil }
        return String(format: "%.1f%%/hr", rate)
    }

    /// Returns estimated total battery life (full charge to empty) in days.
    func estimatedTotalLifeDays() -> Double? {
        guard let rate = computeDrainRatePerHour(), rate > 0.1 else { return nil }
        return 100.0 / rate / 24.0
    }

    // MARK: - Persistence

    private func loadSamples() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([Sample].self, from: data) else {
            samples = []
            return
        }
        // Trim samples older than 7 days
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        samples = decoded.filter { $0.time > cutoff }
    }

    private func saveSamples() {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
