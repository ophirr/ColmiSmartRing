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

    /// Write a batch of heart rate readings from the ring's historical HR log.
    /// Each (bpm, time) pair becomes a point sample. Uses SyncIdentifier for dedup.
    func writeHeartRateLog(_ readings: [(bpm: Int, time: Date)]) async {
        let valid = readings.filter { $0.bpm > 0 && $0.bpm <= 220 }
        guard !valid.isEmpty, HKHealthStore.isHealthDataAvailable() else { return }

        do {
            try await requestAuthorizationIfNeeded()
            let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
            let unit = HKUnit.count().unitDivided(by: .minute())
            let samples = valid.map { reading in
                HKQuantitySample(
                    type: hrType,
                    quantity: HKQuantity(unit: unit, doubleValue: Double(reading.bpm)),
                    start: reading.time,
                    end: reading.time,
                    metadata: [
                        HKMetadataKeySyncIdentifier: "biosense.hr.log.\(Int(reading.time.timeIntervalSince1970))",
                        HKMetadataKeySyncVersion: 1
                    ]
                )
            }
            try await save(samples)
            tLog("[HealthKit/HR] HR log batch: \(samples.count) readings written")
        } catch {
            tLog("[HealthKit/HR] HR log batch failed: \(error)")
        }
    }

    /// Write a batch of SpO2 readings from the ring's historical blood oxygen data.
    func writeSpO2Series(_ readings: [(percent: Double, time: Date)]) async {
        let valid = readings.filter { $0.percent >= 80 && $0.percent <= 100 }
        guard !valid.isEmpty, HKHealthStore.isHealthDataAvailable() else { return }

        do {
            try await requestAuthorizationIfNeeded()
            let spo2Type = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation)!
            let samples = valid.map { reading in
                HKQuantitySample(
                    type: spo2Type,
                    quantity: HKQuantity(unit: .percent(), doubleValue: reading.percent / 100.0),
                    start: reading.time,
                    end: reading.time,
                    metadata: [
                        HKMetadataKeySyncIdentifier: "biosense.spo2.log.\(Int(reading.time.timeIntervalSince1970))",
                        HKMetadataKeySyncVersion: 1
                    ]
                )
            }
            try await save(samples)
            tLog("[HealthKit/SpO2] SpO2 series batch: \(samples.count) readings written")
        } catch {
            tLog("[HealthKit/SpO2] SpO2 series batch failed: \(error)")
        }
    }

    /// Write a batch of HRV (SDNN) readings from the ring's historical data.
    func writeHRVSeries(_ readings: [(sdnn: Double, time: Date)]) async {
        let valid = readings.filter { $0.sdnn > 0 && $0.sdnn < 500 }
        guard !valid.isEmpty, HKHealthStore.isHealthDataAvailable() else { return }

        do {
            try await requestAuthorizationIfNeeded()
            let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!
            let unit = HKUnit.secondUnit(with: .milli)
            let samples = valid.map { reading in
                HKQuantitySample(
                    type: hrvType,
                    quantity: HKQuantity(unit: unit, doubleValue: reading.sdnn),
                    start: reading.time,
                    end: reading.time,
                    metadata: [
                        HKMetadataKeySyncIdentifier: "biosense.hrv.log.\(Int(reading.time.timeIntervalSince1970))",
                        HKMetadataKeySyncVersion: 1
                    ]
                )
            }
            try await save(samples)
            tLog("[HealthKit/HRV] HRV series batch: \(samples.count) readings written")
        } catch {
            tLog("[HealthKit/HRV] HRV series batch failed: \(error)")
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
        let hrvType = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.requestAuthorization(toShare: [hrType, spo2Type, tempType, hrvType], read: []) { [weak self] success, error in
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
