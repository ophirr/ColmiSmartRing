import Foundation
import HealthKit

/// Writes heart rate, SpO2, HRV, and temperature samples to Apple Health
/// from spot-checks and periodic readings (outside of gym workouts which
/// have their own writer).
final class AppleHealthHeartRateWriter {
    private let base = HealthKitBase()

    // MARK: - Single-reading writes (spot-checks / real-time)

    /// Write a single heart rate reading to HealthKit.
    func writeHeartRate(bpm: Int, time: Date) async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        guard bpm > 0, bpm <= 220 else { return }

        do {

            let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
            let unit = HKUnit.count().unitDivided(by: .minute())
            let sample = HKQuantitySample(
                type: hrType,
                quantity: HKQuantity(unit: unit, doubleValue: Double(bpm)),
                start: time, end: time,
                metadata: syncMeta("halo.hr.\(Int(time.timeIntervalSince1970))")
            )
            try await base.saveSamples([sample])
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

            let spo2Type = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation)!
            let sample = HKQuantitySample(
                type: spo2Type,
                quantity: HKQuantity(unit: .percent(), doubleValue: Double(percent) / 100.0),
                start: time, end: time,
                metadata: syncMeta("halo.spo2.\(Int(time.timeIntervalSince1970))")
            )
            try await base.saveSamples([sample])
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

            let tempType = HKQuantityType.quantityType(forIdentifier: .bodyTemperature)!
            let sample = HKQuantitySample(
                type: tempType,
                quantity: HKQuantity(unit: .degreeCelsius(), doubleValue: celsius),
                start: time, end: time,
                metadata: syncMeta("halo.temp.\(Int(time.timeIntervalSince1970))")
            )
            try await base.saveSamples([sample])
            tLog("[HealthKit/Temp] Body temperature \(celsius)°C written")
        } catch {
            tLog("[HealthKit/Temp] Failed to write temperature: \(error)")
        }
    }

    // MARK: - Batch writes (historical syncs)

    /// Write a batch of heart rate readings from the ring's historical HR log.
    func writeHeartRateLog(_ readings: [(bpm: Int, time: Date)]) async {
        let valid = readings.filter { $0.bpm > 0 && $0.bpm <= 220 }
        guard !valid.isEmpty, HKHealthStore.isHealthDataAvailable() else { return }

        do {

            let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
            let unit = HKUnit.count().unitDivided(by: .minute())
            let samples = valid.map { reading in
                HKQuantitySample(
                    type: hrType,
                    quantity: HKQuantity(unit: unit, doubleValue: Double(reading.bpm)),
                    start: reading.time, end: reading.time,
                    metadata: syncMeta("biosense.hr.log.\(Int(reading.time.timeIntervalSince1970))")
                )
            }
            try await base.saveSamples(samples)
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

            let spo2Type = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation)!
            let samples = valid.map { reading in
                HKQuantitySample(
                    type: spo2Type,
                    quantity: HKQuantity(unit: .percent(), doubleValue: reading.percent / 100.0),
                    start: reading.time, end: reading.time,
                    metadata: syncMeta("biosense.spo2.log.\(Int(reading.time.timeIntervalSince1970))")
                )
            }
            try await base.saveSamples(samples)
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

            let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!
            let unit = HKUnit.secondUnit(with: .milli)
            let samples = valid.map { reading in
                HKQuantitySample(
                    type: hrvType,
                    quantity: HKQuantity(unit: unit, doubleValue: reading.sdnn),
                    start: reading.time, end: reading.time,
                    metadata: syncMeta("biosense.hrv.log.\(Int(reading.time.timeIntervalSince1970))")
                )
            }
            try await base.saveSamples(samples)
            tLog("[HealthKit/HRV] HRV series batch: \(samples.count) readings written")
        } catch {
            tLog("[HealthKit/HRV] HRV series batch failed: \(error)")
        }
    }

    // MARK: - Helpers

    private func syncMeta(_ identifier: String) -> [String: Any] {
        [
            HKMetadataKeySyncIdentifier: identifier,
            HKMetadataKeySyncVersion: 1
        ]
    }
}
