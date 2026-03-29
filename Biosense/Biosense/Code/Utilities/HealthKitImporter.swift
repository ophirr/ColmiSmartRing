//
//  HealthKitImporter.swift
//  Biosense
//
//  Reads glucose and phone step count data from HealthKit, persists to
//  SwiftData, and fans out to InfluxDB.  Counterpart to the existing
//  AppleHealth*Writer classes.
//

import Foundation
import HealthKit
import SwiftData

@MainActor
final class HealthKitImporter {
    private let base = HealthKitBase()
    private let modelContext: ModelContext
    private let influx = InfluxDBWriter.shared

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Public

    /// Import glucose and phone step data from HealthKit.
    /// Authorization is requested once on first call; subsequent calls just query.
    func importAll() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            tLog("[HealthKitImporter] HealthKit not available")
            return
        }
        tLog("[HealthKitImporter] Starting import")
        // Read authorization is requested via AppleHealthActivityWriter's auth flow
        // (which includes our read types). We don't call requestAuthorization here
        // to avoid conflicting auth dialogs.
        await importGlucose()
        await importPhoneActivity()
        tLog("[HealthKitImporter] Import complete")
    }

    // MARK: - Glucose

    private func importGlucose() async {
        let anchor = latestStoredTimestamp(StoredGlucoseSample.self, keyPath: \.timestamp)
            ?? Date().addingTimeInterval(-7 * 86400)
        let glucoseType = HKQuantityType(.bloodGlucose)
        do {
            let samples = try await base.querySamples(type: glucoseType, start: anchor, end: Date())
            let ownBundle = Bundle.main.bundleIdentifier ?? ""
            let external = samples.compactMap { $0 as? HKQuantitySample }
                .filter { $0.sourceRevision.source.bundleIdentifier != ownBundle }

            let existing = (try? modelContext.fetch(FetchDescriptor<StoredGlucoseSample>())) ?? []
            var inserted = 0

            for sample in external {
                let mgdl = sample.quantity.doubleValue(for: HKUnit(from: "mg/dL"))
                let ts = sample.startDate

                // Dedup: skip if we already have a sample within 30 seconds
                let dominated = existing.contains { abs($0.timestamp.timeIntervalSince(ts)) < 30 }
                guard !dominated else { continue }

                let stored = StoredGlucoseSample(
                    timestamp: ts,
                    valueMgdl: mgdl,
                    sourceBundle: sample.sourceRevision.source.bundleIdentifier ?? "unknown"
                )
                modelContext.insert(stored)
                influx.writeGlucose(valueMgdl: mgdl, source: "healthkit", time: ts)
                inserted += 1
            }

            if inserted > 0 {
                try? modelContext.save()
            }
            tLog("[HealthKitImporter] Glucose: imported \(inserted) samples since \(anchor)")
        } catch {
            tLog("[HealthKitImporter] Glucose query failed: \(error)")
        }
    }

    // MARK: - Phone Steps

    private func importPhoneActivity() async {
        let anchor = latestStoredTimestamp(StoredPhoneStepSample.self, keyPath: \.timestamp)
            ?? Date().addingTimeInterval(-7 * 86400)
        let calendar = Calendar.current

        // Query steps, distance, and calories from iPhone pedometer
        do {
            let stepSamples = try await queryPhoneSamples(type: HKQuantityType(.stepCount), since: anchor)
            let distSamples = try await queryPhoneSamples(type: HKQuantityType(.distanceWalkingRunning), since: anchor)
            let calSamples = try await queryPhoneSamples(type: HKQuantityType(.activeEnergyBurned), since: anchor)

            // Aggregate each metric into hourly buckets
            var stepBuckets: [Date: Int] = [:]
            for s in stepSamples {
                let h = calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour], from: s.startDate))!
                stepBuckets[h, default: 0] += Int(s.quantity.doubleValue(for: .count()))
            }
            var distBuckets: [Date: Double] = [:]
            for s in distSamples {
                let h = calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour], from: s.startDate))!
                distBuckets[h, default: 0] += s.quantity.doubleValue(for: .meterUnit(with: .kilo))
            }
            var calBuckets: [Date: Int] = [:]
            for s in calSamples {
                let h = calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour], from: s.startDate))!
                calBuckets[h, default: 0] += Int(s.quantity.doubleValue(for: .kilocalorie()))
            }

            let allHours = Set(stepBuckets.keys).union(distBuckets.keys).union(calBuckets.keys)
            let existing = (try? modelContext.fetch(FetchDescriptor<StoredPhoneStepSample>())) ?? []
            var upserted = 0

            for hourStart in allHours {
                let steps = stepBuckets[hourStart] ?? 0
                let dist = distBuckets[hourStart] ?? 0
                let cals = calBuckets[hourStart] ?? 0

                if let match = existing.first(where: { $0.timestamp == hourStart }) {
                    var changed = false
                    if steps > match.steps { match.steps = steps; changed = true }
                    if dist > match.distanceKm { match.distanceKm = dist; changed = true }
                    if cals > match.calories { match.calories = cals; changed = true }
                    if changed { upserted += 1 }
                } else {
                    modelContext.insert(StoredPhoneStepSample(timestamp: hourStart, steps: steps, distanceKm: dist, calories: cals))
                    upserted += 1
                }
            }

            if upserted > 0 {
                try? modelContext.save()
            }
            tLog("[HealthKitImporter] Phone activity: upserted \(upserted) hourly buckets, \(stepSamples.count) step samples since \(anchor)")
        } catch {
            tLog("[HealthKitImporter] Phone activity query failed: \(error)")
        }
    }

    /// Query a single HealthKit type filtered to iPhone pedometer sources.
    private func queryPhoneSamples(type: HKQuantityType, since anchor: Date) async throws -> [HKQuantitySample] {
        let samples = try await base.querySamples(type: type, start: anchor, end: Date())
        return samples.compactMap { $0 as? HKQuantitySample }
            .filter { isIPhonePedometerSource($0.sourceRevision) }
    }

    // MARK: - Helpers

    /// Returns true for iPhone pedometer steps only.
    /// iPhone pedometer data comes from com.apple.health with productType "iPhone*".
    /// This excludes Apple Watch, ring writes, Fitbit, Garmin, etc.
    private func isIPhonePedometerSource(_ source: HKSourceRevision) -> Bool {
        // iPhone pedometer bundle: "com.apple.health" or "com.apple.health.<UUID>"
        guard source.source.bundleIdentifier.hasPrefix("com.apple.health") else { return false }
        guard let productType = source.productType, productType.hasPrefix("iPhone") else { return false }
        return true
    }

    private func latestStoredTimestamp<T: PersistentModel>(_ type: T.Type, keyPath: KeyPath<T, Date>) -> Date? {
        var descriptor = FetchDescriptor<T>(sortBy: [SortDescriptor(keyPath, order: .reverse)])
        descriptor.fetchLimit = 1
        let results = (try? modelContext.fetch(descriptor)) ?? []
        return results.first?[keyPath: keyPath]
    }
}
