//
//  DemoDataGenerator.swift
//  Halo
//
//  Generates realistic synthetic biometric data for testing the app
//  and InfluxDB pipeline without a physical ring.
//
//  Physiological model:
//  - Circadian rhythm modulates resting HR (lower at night, higher midday)
//  - HRV inversely correlates with HR
//  - SpO2 is stable 96–99% with occasional dips
//  - Stress correlates loosely with HR elevation
//  - Activity tag influences all parameters
//

import Foundation
import SwiftData

@MainActor
final class DemoDataGenerator {
    static let shared = DemoDataGenerator()

    private var timer: Timer?
    private var modelContext: ModelContext?
    private var ringSessionManager: RingSessionManager?
    private let influx = InfluxDBWriter.shared

    /// Emit interval in seconds.
    private let emitInterval: TimeInterval = 10

    /// Running state for smooth Brownian-style drift.
    private var baseHR: Double = 112
    private var baseHRV: Double = 45
    private var baseSpO2: Double = 97.5
    private var baseStress: Double = 35
    private var demoBatteryLevel: Int = 78

    private(set) var isRunning = false
    private(set) var samplesGenerated: Int = 0

    private init() {}

    // MARK: - Lifecycle

    func start(modelContext: ModelContext, ringSessionManager: RingSessionManager) {
        guard !isRunning else { return }
        self.modelContext = modelContext
        self.ringSessionManager = ringSessionManager
        isRunning = true
        samplesGenerated = 0

        // Activate demo ring state
        ringSessionManager.demoModeActive = true
        ringSessionManager.currentBatteryInfo = BatteryInfo(batteryLevel: demoBatteryLevel, charging: false)
        ringSessionManager.hrLogIntervalMinutes = ringSessionManager.hrLogIntervalMinutes ?? 5
        ringSessionManager.hrLogEnabled = ringSessionManager.hrLogEnabled ?? true

        debugPrint("[Demo] Started — emitting every \(Int(emitInterval))s")

        // Backfill today's HR log so the chart has data immediately
        backfillTodayHR(context: modelContext)

        // Emit immediately, then on timer
        emitSample()
        timer = Timer.scheduledTimer(withTimeInterval: emitInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.emitSample()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        influx.flush()

        // Deactivate demo ring state
        ringSessionManager?.demoModeActive = false
        ringSessionManager?.currentBatteryInfo = nil
        ringSessionManager?.realTimeHeartRateBPM = nil
        ringSessionManager?.realTimeBloodOxygenPercent = nil

        debugPrint("[Demo] Stopped — \(samplesGenerated) samples generated")
    }

    // MARK: - Sample Generation

    private func emitSample() {
        let now = Date()
        let tag = influx.activeTag
        let defaults = UserDefaults.standard

        // Read tracking toggles (default true for fresh installs)
        let hrEnabled = defaults.object(forKey: "trackingSetting.heartRate") == nil || defaults.bool(forKey: "trackingSetting.heartRate")
        let hrvEnabled = defaults.object(forKey: "trackingSetting.hrv") == nil || defaults.bool(forKey: "trackingSetting.hrv")
        let spo2Enabled = defaults.object(forKey: "trackingSetting.bloodOxygen") == nil || defaults.bool(forKey: "trackingSetting.bloodOxygen")
        let stressEnabled = defaults.object(forKey: "trackingSetting.pressure") == nil || defaults.bool(forKey: "trackingSetting.pressure")

        // --- Compute physiologically correlated values ---

        let circadian = circadianFactor(for: now)     // 0.0 (deep night) → 1.0 (afternoon)
        let tagModifier = activityModifier(for: tag)   // multiplier based on activity

        // Heart rate: drift + circadian + activity
        baseHR = drift(baseHR, min: 48, max: 180, step: 1.5)
        let hr = clamp(baseHR + circadian * 12 + tagModifier.hrOffset + jitter(2), min: 45, max: 190)
        let bpm = Int(round(hr))

        // HRV: inversely correlated with HR
        baseHRV = drift(baseHRV, min: 10, max: 120, step: 2.0)
        let hrvNatural = 120.0 - hr * 0.8  // inverse relationship
        let hrv = clamp((baseHRV + hrvNatural) / 2.0 + tagModifier.hrvOffset + jitter(3), min: 8, max: 130)

        // SpO2: very stable, slight circadian dip at night
        baseSpO2 = drift(baseSpO2, min: 94, max: 100, step: 0.2)
        let spo2 = clamp(baseSpO2 - (1.0 - circadian) * 0.5 + tagModifier.spo2Offset + jitter(0.3), min: 90, max: 100)

        // Stress: correlates with HR elevation above resting
        baseStress = drift(baseStress, min: 5, max: 95, step: 2.5)
        let stressFromHR = max(0, (hr - 65) * 0.5)
        let stress = clamp((baseStress + stressFromHR) / 2.0 + tagModifier.stressOffset + jitter(3), min: 1, max: 100)

        // Feed real-time HR and SpO2 for gym mode and metrics real-time cards
        ringSessionManager?.realTimeHeartRateBPM = bpm
        ringSessionManager?.realTimeBloodOxygenPercent = Int(round(spo2))

        // --- Write to InfluxDB (respecting toggles) ---
        if hrEnabled {
            influx.writeHeartRates([(bpm: bpm, time: now)])
        }
        if hrvEnabled {
            influx.writeHRV(value: round(hrv * 10) / 10, time: now)
        }
        if spo2Enabled {
            influx.writeSpO2(value: round(spo2 * 10) / 10, time: now)
        }
        if stressEnabled {
            influx.writeStress(value: round(stress * 10) / 10, time: now)
        }

        // --- Write to SwiftData (for local charts, respecting toggles) ---
        if let ctx = modelContext {
            if hrvEnabled {
                ctx.insert(StoredHRVSample(timestamp: now, value: round(hrv * 10) / 10))
            }
            if spo2Enabled {
                ctx.insert(StoredBloodOxygenSample(timestamp: now, value: round(spo2 * 10) / 10))
            }
            if stressEnabled {
                ctx.insert(StoredStressSample(timestamp: now, value: round(stress * 10) / 10))
            }
            if hrEnabled {
                upsertHeartRateLog(bpm: bpm, time: now, context: ctx)
            }
            try? ctx.save()
        }

        // Simulate slow battery drain (~1% per 5 minutes)
        samplesGenerated += 1
        if samplesGenerated % 30 == 0 {
            demoBatteryLevel = max(5, demoBatteryLevel - 1)
            ringSessionManager?.currentBatteryInfo = BatteryInfo(batteryLevel: demoBatteryLevel, charging: false)
        }

        if samplesGenerated % 6 == 0 {
            let active = [hrEnabled ? "HR:\(bpm)" : nil,
                          hrvEnabled ? "HRV:\(String(format:"%.1f", hrv))" : nil,
                          spo2Enabled ? "SpO2:\(String(format:"%.1f", spo2))" : nil,
                          stressEnabled ? "Stress:\(String(format:"%.1f", stress))" : nil]
                .compactMap { $0 }.joined(separator: " ")
            debugPrint("[Demo] #\(samplesGenerated) \(active) tag:\(tag.displayName) bat:\(demoBatteryLevel)%")
        }
    }

    // MARK: - Heart Rate Log Upsert

    /// Updates today's 288-slot HR log (one slot per 5 min, matching firmware format).
    private func upsertHeartRateLog(bpm: Int, time: Date, context: ModelContext) {
        let dayStart = Calendar.current.startOfDay(for: time)
        let minutesSinceMidnight = Int(time.timeIntervalSince(dayStart) / 60)
        let slotIndex = min(minutesSinceMidnight / 5, 287)

        let descriptor = FetchDescriptor<StoredHeartRateLog>(
            predicate: #Predicate<StoredHeartRateLog> { $0.dayStart == dayStart }
        )
        if let existing = (try? context.fetch(descriptor))?.first {
            // Update the specific 5-min slot
            if slotIndex < existing.heartRates.count {
                existing.heartRates[slotIndex] = bpm
            }
            existing.timestamp = time
        } else {
            // Create a full 288-slot array (zeros = no reading)
            var rates = [Int](repeating: 0, count: 288)
            rates[slotIndex] = bpm
            context.insert(StoredHeartRateLog(
                timestamp: time,
                heartRates: rates,
                size: 288,
                index: 0,
                range: 5
            ))
        }
    }

    // MARK: - Backfill

    /// Populate today's HR log with realistic values for all elapsed 5-min slots.
    /// Also backfills HRV, SpO2, and Stress at hourly intervals.
    private func backfillTodayHR(context: ModelContext) {
        let now = Date()
        let dayStart = Calendar.current.startOfDay(for: now)
        let minutesSinceMidnight = Int(now.timeIntervalSince(dayStart) / 60)
        let slotsToFill = min(minutesSinceMidnight / 5, 287)

        guard slotsToFill > 0 else { return }

        // Build 288-slot HR array
        var rates = [Int](repeating: 0, count: 288)
        var hr = 62.0  // start low (nighttime)
        for slot in 0...slotsToFill {
            let slotTime = dayStart.addingTimeInterval(TimeInterval(slot * 5 * 60))
            let circ = circadianFactor(for: slotTime)
            hr = drift(hr, min: 48, max: 95, step: 1.2)
            let bpm = Int(round(hr + circ * 12 + jitter(2)))
            rates[slot] = max(45, min(120, bpm))
        }

        let descriptor = FetchDescriptor<StoredHeartRateLog>(
            predicate: #Predicate<StoredHeartRateLog> { $0.dayStart == dayStart }
        )
        if let existing = (try? context.fetch(descriptor))?.first {
            existing.heartRates = rates
            existing.timestamp = now
        } else {
            context.insert(StoredHeartRateLog(
                timestamp: now,
                heartRates: rates,
                size: 288,
                index: 0,
                range: 5
            ))
        }

        // Backfill HRV, SpO2, Stress at hourly intervals
        let hoursToFill = minutesSinceMidnight / 60
        var bfHRV = 45.0
        var bfSpO2 = 97.5
        var bfStress = 30.0
        for hour in 0..<hoursToFill {
            let t = dayStart.addingTimeInterval(TimeInterval(hour * 3600))
            let circ = circadianFactor(for: t)

            bfHRV = drift(bfHRV, min: 15, max: 100, step: 3)
            let hrvVal = round(clamp(bfHRV + (1.0 - circ) * 10, min: 10, max: 120) * 10) / 10
            context.insert(StoredHRVSample(timestamp: t, value: hrvVal))

            bfSpO2 = drift(bfSpO2, min: 95, max: 99.5, step: 0.3)
            let spo2Val = round(clamp(bfSpO2 - (1.0 - circ) * 0.5, min: 92, max: 100) * 10) / 10
            context.insert(StoredBloodOxygenSample(timestamp: t, value: spo2Val))

            bfStress = drift(bfStress, min: 10, max: 80, step: 3)
            let stressVal = round(clamp(bfStress + circ * 10, min: 5, max: 90) * 10) / 10
            context.insert(StoredStressSample(timestamp: t, value: stressVal))
        }

        try? context.save()

        // Also send backfill to InfluxDB
        let hrReadings = rates.enumerated().compactMap { slot, bpm -> (bpm: Int, time: Date)? in
            guard bpm > 0 else { return nil }
            return (bpm: bpm, time: dayStart.addingTimeInterval(TimeInterval(slot * 5 * 60)))
        }
        influx.writeHeartRates(hrReadings)
        influx.flush()

        debugPrint("[Demo] Backfilled \(slotsToFill) HR slots + \(hoursToFill)h of HRV/SpO2/Stress")
    }

    // MARK: - Physiological Models

    /// Circadian factor: 0 at 3AM, 1 at 2PM, smooth sine curve.
    private func circadianFactor(for date: Date) -> Double {
        let calendar = Calendar.current
        let hour = Double(calendar.component(.hour, from: date))
        let minute = Double(calendar.component(.minute, from: date))
        let fractionalHour = hour + minute / 60.0
        // Peak at 14:00 (2PM), trough at 03:00
        let phase = (fractionalHour - 3.0) / 24.0 * 2.0 * .pi
        return (sin(phase) + 1.0) / 2.0
    }

    /// Activity-dependent modifiers for each vital.
    private func activityModifier(for tag: ActivityTag) -> (hrOffset: Double, hrvOffset: Double, spo2Offset: Double, stressOffset: Double) {
        switch tag {
        case .none:       return (0, 0, 0, 0)
        case .resting:    return (-8, 10, 0.3, -10)
        case .sleeping:   return (-15, 15, -0.3, -15)
        case .meditating: return (-10, 20, 0.2, -20)
        case .exercising: return (35, -15, -0.5, 15)
        case .running:    return (55, -20, -0.8, 20)
        case .fun1:       return (10, -3, 0, 5)
        case .fun2:       return (15, -5, 0, 8)
        case .fun3:       return (20, -8, -0.2, 12)
        }
    }

    // MARK: - Math Helpers

    /// Brownian drift: random walk with mean reversion.
    private func drift(_ value: Double, min: Double, max: Double, step: Double) -> Double {
        let mid = (min + max) / 2.0
        let reversion = (mid - value) * 0.02  // gentle pull toward center
        let noise = Double.random(in: -step...step)
        return clamp(value + noise + reversion, min: min, max: max)
    }

    private func jitter(_ magnitude: Double) -> Double {
        Double.random(in: -magnitude...magnitude)
    }

    private func clamp(_ value: Double, min: Double, max: Double) -> Double {
        Swift.min(Swift.max(value, min), max)
    }
}
