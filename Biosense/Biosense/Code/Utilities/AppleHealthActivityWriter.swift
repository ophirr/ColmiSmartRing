import Foundation
import HealthKit

@MainActor
final class AppleHealthActivityWriter {
    private let base = HealthKitBase()

    private static let shareTypes: Set<HKSampleType> = [
        HKQuantityType.quantityType(forIdentifier: .stepCount)!,
        HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!,
    ]

    func writeActivitySample(timestamp: Date, steps: Int, calories: Int) async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        guard steps > 0 || calories > 0 else { return }

        do {
            try await base.authorize(toShare: Self.shareTypes)
            let samples = makeSamples(timestamp: timestamp, steps: steps, calories: calories)
            guard !samples.isEmpty else { return }
            try await base.saveSamples(samples)
            tLog("[HealthKit] Activity samples written: \(samples.count)")
        } catch {
            tLog("[HealthKit] Failed to write activity samples: \(error)")
        }
    }

    private func makeSamples(timestamp: Date, steps: Int, calories: Int) -> [HKQuantitySample] {
        let end = timestamp.addingTimeInterval(15 * 60)
        var samples: [HKQuantitySample] = []

        if steps > 0 {
            let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount)!
            let quantity = HKQuantity(unit: HKUnit.count(), doubleValue: Double(steps))
            samples.append(
                HKQuantitySample(
                    type: stepType, quantity: quantity,
                    start: timestamp, end: end,
                    metadata: [
                        HKMetadataKeySyncIdentifier: "halo.activity.steps.\(Int(timestamp.timeIntervalSince1970))",
                        HKMetadataKeySyncVersion: 1
                    ]
                )
            )
        }

        if calories > 0 {
            let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!
            let quantity = HKQuantity(unit: HKUnit.kilocalorie(), doubleValue: Double(calories))
            samples.append(
                HKQuantitySample(
                    type: energyType, quantity: quantity,
                    start: timestamp, end: end,
                    metadata: [
                        HKMetadataKeySyncIdentifier: "halo.activity.kcal.\(Int(timestamp.timeIntervalSince1970))",
                        HKMetadataKeySyncVersion: 1
                    ]
                )
            )
        }

        return samples
    }
}
