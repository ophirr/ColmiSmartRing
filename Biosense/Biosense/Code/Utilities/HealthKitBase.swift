import Foundation
import HealthKit

/// Shared HealthKit helpers used by the concrete writers (HR, Sleep, Activity).
/// Eliminates duplicated authorization & save boilerplate.
///
/// Usage: create a subclass or embed an instance and call `authorize(toShare:)`
/// once, then `saveSamples(_:)` for each batch.
///
/// **Not** used by `AppleHealthGymWriter` which has workout-specific needs
/// (workout + associated samples, read permissions, custom error types).
final class HealthKitBase {
    let healthStore = HKHealthStore()
    private var didRequestAuthorization = false

    /// Request write-only authorization for the given sample types.
    /// No-ops after the first successful call.
    func authorize(toShare types: Set<HKSampleType>) async throws {
        guard !didRequestAuthorization else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.requestAuthorization(toShare: types, read: []) { [weak self] success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard success else {
                    continuation.resume(throwing: HealthKitBaseError.authorizationDenied)
                    return
                }
                self?.didRequestAuthorization = true
                continuation.resume(returning: ())
            }
        }
    }

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

    enum HealthKitBaseError: LocalizedError {
        case authorizationDenied
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .authorizationDenied: return "HealthKit authorization was denied"
            case .saveFailed: return "Failed to save samples to HealthKit"
            }
        }
    }
}
