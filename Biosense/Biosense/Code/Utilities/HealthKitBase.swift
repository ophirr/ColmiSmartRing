import Foundation
import HealthKit

/// Shared HealthKit helpers for saving samples and querying data.
/// Authorization is handled centrally by HealthKitAuthorizer.
final class HealthKitBase {
    let healthStore = HKHealthStore()

    /// Save an array of quantity samples to the Health Store.
    func saveSamples(_ samples: [HKSample]) async throws {
        guard !samples.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.save(samples) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard success else {
                    continuation.resume(throwing: HealthKitBaseError.saveFailed)
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    /// Query samples of a given type within a date range.
    /// Returns results sorted by end date ascending.
    func querySamples(
        type: HKSampleType,
        start: Date,
        end: Date,
        limit: Int = HKObjectQueryNoLimit
    ) async throws -> [HKSample] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKSample], Error>) in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: limit,
                sortDescriptors: [sortDescriptor]
            ) { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: results ?? [])
            }
            healthStore.execute(query)
        }
    }

    enum HealthKitBaseError: LocalizedError {
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .saveFailed: return "Failed to save samples to HealthKit"
            }
        }
    }
}
