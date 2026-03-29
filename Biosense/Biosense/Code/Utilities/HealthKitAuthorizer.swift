//
//  HealthKitAuthorizer.swift
//  Biosense
//
//  Single centralized HealthKit authorization call. Requests ALL write and
//  read types up front so the user sees one dialog on first launch.
//

import Foundation
import HealthKit

@MainActor
final class HealthKitAuthorizer {
    static let shared = HealthKitAuthorizer()

    private let healthStore = HKHealthStore()
    private var didRequest = false

    /// All types the app writes to HealthKit.
    private static let writeTypes: Set<HKSampleType> = [
        // Activity
        HKQuantityType(.stepCount),
        HKQuantityType(.activeEnergyBurned),
        // Heart rate / vitals
        HKQuantityType(.heartRate),
        HKQuantityType(.oxygenSaturation),
        HKQuantityType(.bodyTemperature),
        HKQuantityType(.heartRateVariabilitySDNN),
        // Sleep
        HKCategoryType(.sleepAnalysis),
        // Gym
        HKObjectType.workoutType(),
    ]

    /// All types the app reads from HealthKit (Bioscribe).
    private static let readTypes: Set<HKObjectType> = [
        HKQuantityType(.stepCount),
        HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.bloodGlucose),
        // Gym dedup
        HKObjectType.workoutType(),
        HKQuantityType(.heartRate),
    ]

    /// Request all HealthKit permissions. Safe to call multiple times —
    /// no-ops after the first successful request.
    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        guard !didRequest else { return }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                healthStore.requestAuthorization(toShare: Self.writeTypes, read: Self.readTypes) { [weak self] success, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    self?.didRequest = true
                    continuation.resume(returning: ())
                }
            }
            tLog("[HealthKit] Authorization requested successfully")
        } catch {
            tLog("[HealthKit] Authorization request failed: \(error)")
        }
    }
}
