//
//  AppleHealthGymWriter.swift
//  Halo
//
//  Writes completed gym sessions to Apple Health as:
//  1. HKWorkout — the session (type: .traditionalStrengthTraining)
//  2. HKQuantitySample (heartRate) — every BPM reading, timestamped
//
//  After saving, workouts appear in Health app → Browse → Workouts
//  and HR data feeds into Heart → Heart Rate charts.
//

import Foundation
import HealthKit

@MainActor
final class AppleHealthGymWriter {
    private let healthStore = HKHealthStore()
    private var didRequestAuthorization = false

    /// Write a completed gym session to HealthKit.
    /// Call this when the user taps "Save" after stopping a workout.
    func writeGymSession(_ session: StoredGymSession) async {
        guard HKHealthStore.isHealthDataAvailable() else {
            tLog("[HealthKit/Gym] Health data not available on this device")
            return
        }

        do {
            try await requestAuthorizationIfNeeded()

            // 1. Build and save the workout
            let workout = try await saveWorkout(session)
            tLog("[HealthKit/Gym] Workout saved: \(workout.uuid)")

            // 2. Build HR samples and associate with workout
            let hrSamples = makeHeartRateSamples(session)
            if !hrSamples.isEmpty {
                try await associate(samples: hrSamples, with: workout)
                tLog("[HealthKit/Gym] \(hrSamples.count) HR samples associated with workout")
            }

        } catch {
            tLog("[HealthKit/Gym] Failed to write: \(error)")
        }
    }

    // MARK: - Authorization

    private func requestAuthorizationIfNeeded() async throws {
        guard !didRequestAuthorization else { return }

        let workoutType = HKObjectType.workoutType()
        let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate)!
        let energyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!

        // Types we want to write
        let shareTypes: Set<HKSampleType> = [workoutType, heartRateType, energyType]
        // Types we want to read (for deduplication checks if needed later)
        let readTypes: Set<HKObjectType> = [workoutType, heartRateType]

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.requestAuthorization(toShare: shareTypes, read: readTypes) { [weak self] success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard success else {
                    continuation.resume(throwing: HealthGymError.authorizationDenied)
                    return
                }
                self?.didRequestAuthorization = true
                continuation.resume(returning: ())
            }
        }
    }

    // MARK: - Workout

    private func saveWorkout(_ session: StoredGymSession) async throws -> HKWorkout {
        // Estimate calories: rough formula based on average HR and duration
        // MET-based: Calories ≈ duration(min) × (avgHR / 70) × 3.5 × weight(kg) / 200
        // We use a simplified version since we don't have weight. ~6 cal/min average for strength training.
        let durationMinutes = session.durationSeconds / 60.0
        let calMultiplier = session.avgBPM > 0 ? Double(session.avgBPM) / 130.0 : 1.0
        let estimatedCalories = durationMinutes * 6.0 * calMultiplier

        let energyBurned = HKQuantity(unit: .kilocalorie(), doubleValue: estimatedCalories)

        let metadata: [String: Any] = [
            HKMetadataKeySyncIdentifier: "halo.gym.\(Int(session.startTime.timeIntervalSince1970))",
            HKMetadataKeySyncVersion: 1,
            HKMetadataKeyIndoorWorkout: true
        ]

        let workout = HKWorkout(
            activityType: .traditionalStrengthTraining,
            start: session.startTime,
            end: session.endTime,
            duration: session.durationSeconds,
            totalEnergyBurned: energyBurned,
            totalDistance: nil,
            metadata: metadata
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.save(workout) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard success else {
                    continuation.resume(throwing: HealthGymError.saveFailed)
                    return
                }
                continuation.resume(returning: ())
            }
        }

        return workout
    }

    // MARK: - Heart Rate Samples

    private func makeHeartRateSamples(_ session: StoredGymSession) -> [HKQuantitySample] {
        let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let unit = HKUnit.count().unitDivided(by: .minute()) // beats per minute

        let sortedSamples = session.samples.sorted { $0.timestamp < $1.timestamp }

        return sortedSamples.compactMap { sample in
            guard sample.bpm > 0 else { return nil }

            let quantity = HKQuantity(unit: unit, doubleValue: Double(sample.bpm))
            let metadata: [String: Any] = [
                HKMetadataKeySyncIdentifier: "halo.gym.hr.\(Int(sample.timestamp.timeIntervalSince1970))",
                HKMetadataKeySyncVersion: 1
            ]

            return HKQuantitySample(
                type: hrType,
                quantity: quantity,
                start: sample.timestamp,
                end: sample.timestamp,
                metadata: metadata
            )
        }
    }

    /// Associate HR samples with the workout so Health app shows them together.
    private func associate(samples: [HKQuantitySample], with workout: HKWorkout) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.add(samples, to: workout) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard success else {
                    continuation.resume(throwing: HealthGymError.associationFailed)
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    // MARK: - Errors

    enum HealthGymError: LocalizedError {
        case authorizationDenied
        case saveFailed
        case associationFailed

        var errorDescription: String? {
            switch self {
            case .authorizationDenied: return "HealthKit authorization was denied"
            case .saveFailed: return "Failed to save workout to HealthKit"
            case .associationFailed: return "Failed to associate HR samples with workout"
            }
        }
    }
}
