import Foundation
import HealthKit

/// Writes heart rate and SpO2 samples to Apple Health from spot-checks
/// and periodic readings (outside of gym workouts which have their own writer).
final class AppleHealthHeartRateWriter {
    private let healthStore = HKHealthStore()
    private var didRequestAuthorization = false

    /// Write a single heart rate reading to HealthKit.
    func writeHeartRate(bpm: Int, time: Date) async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        guard bpm > 0, bpm <= 220 else { return }

        do {
            try await requestAuthorizationIfNeeded()
            let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
            let unit = HKUnit.count().unitDivided(by: .minute())
            let quantity = HKQuantity(unit: unit, doubleValue: Double(bpm))
            let metadata: [String: Any] = [
                HKMetadataKeySyncIdentifier: "halo.hr.\(Int(time.timeIntervalSince1970))",
                HKMetadataKeySyncVersion: 1
            ]
            let sample = HKQuantitySample(
                type: hrType,
                quantity: quantity,
                start: time,
                end: time,
                metadata: metadata
            )
            try await save([sample])
            tLog("[HealthKit/HR] Heart rate \(bpm) bpm written")
        } catch {
            tLog("[HealthKit/HR] Failed to write heart rate: \(error)")
        }
    }

    /// Write a single SpO2 reading to HealthKit.
    func writeSpO2(percent: Int, time: Date) async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        guard percent > 0, percent <= 100 else { return }

        do {
            try await requestAuthorizationIfNeeded()
            let spo2Type = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation)!
            let quantity = HKQuantity(unit: .percent(), doubleValue: Double(percent) / 100.0)
            let metadata: [String: Any] = [
                HKMetadataKeySyncIdentifier: "halo.spo2.\(Int(time.timeIntervalSince1970))",
                HKMetadataKeySyncVersion: 1
            ]
            let sample = HKQuantitySample(
                type: spo2Type,
                quantity: quantity,
                start: time,
                end: time,
                metadata: metadata
            )
            try await save([sample])
            tLog("[HealthKit/SpO2] SpO2 \(percent)% written")
        } catch {
            tLog("[HealthKit/SpO2] Failed to write SpO2: \(error)")
        }
    }

    /// Write a single body temperature reading to HealthKit.
    func writeTemperature(celsius: Double, time: Date) async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        guard celsius > 30.0, celsius < 45.0 else { return }

        do {
            try await requestAuthorizationIfNeeded()
            let tempType = HKQuantityType.quantityType(forIdentifier: .bodyTemperature)!
            let quantity = HKQuantity(unit: .degreeCelsius(), doubleValue: celsius)
            let metadata: [String: Any] = [
                HKMetadataKeySyncIdentifier: "halo.temp.\(Int(time.timeIntervalSince1970))",
                HKMetadataKeySyncVersion: 1
            ]
            let sample = HKQuantitySample(
                type: tempType,
                quantity: quantity,
                start: time,
                end: time,
                metadata: metadata
            )
            try await save([sample])
            tLog("[HealthKit/Temp] Body temperature \(celsius)°C written")
        } catch {
            tLog("[HealthKit/Temp] Failed to write temperature: \(error)")
        }
    }

    // MARK: - Private

    private func requestAuthorizationIfNeeded() async throws {
        guard !didRequestAuthorization else { return }
        let hrType = HKObjectType.quantityType(forIdentifier: .heartRate)!
        let spo2Type = HKObjectType.quantityType(forIdentifier: .oxygenSaturation)!
        let tempType = HKObjectType.quantityType(forIdentifier: .bodyTemperature)!
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.requestAuthorization(toShare: [hrType, spo2Type, tempType], read: []) { [weak self] success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard success else {
                    continuation.resume(throwing: NSError(domain: "AppleHealthHeartRateWriter", code: 1))
                    return
                }
                self?.didRequestAuthorization = true
                continuation.resume(returning: ())
            }
        }
    }

    private func save(_ samples: [HKQuantitySample]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.save(samples) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard success else {
                    continuation.resume(throwing: NSError(domain: "AppleHealthHeartRateWriter", code: 2))
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }
}
