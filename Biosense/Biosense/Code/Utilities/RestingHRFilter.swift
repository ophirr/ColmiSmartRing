//
//  RestingHRFilter.swift
//  Biosense
//
//  Kalman filter for resting/sleep heart rate artifact rejection.
//
//  During sleep and rest, HR changes slowly (< 1 BPM/sec). The Colmi R02's
//  PPG sensor produces erratic readings when the ring shifts on the finger
//  or during movement — jumps to 100-170 BPM that are physiologically
//  impossible at rest. This filter catches those artifacts using:
//
//  1. Tight rate-of-change constraints (max 1.5 BPM/sec rise, 2 BPM/sec fall)
//  2. Low process noise (HR is nearly constant during sleep)
//  3. Deviation-from-prediction penalty: readings far from the predicted HR
//     get high measurement noise, keeping Kalman gain near zero
//  4. Absolute bounds: 35-130 BPM for resting context
//
//  No cadence or motion data is needed — the filter relies entirely on
//  the statistical implausibility of large HR jumps at rest.
//
//  Pure logic — no BLE or UI dependencies. Fully testable.
//

import Foundation

/// Result of filtering a single resting HR reading.
struct RestingHRFilterResult {
    /// Filtered HR (BPM).
    let bpm: Int
    /// Raw input BPM before filtering.
    let rawBPM: Int
    /// Whether the raw reading was rejected/attenuated as an artifact.
    let wasFiltered: Bool
    /// Confidence in the output (0-1).
    let confidence: Double
    /// Kalman gain — how much the measurement was trusted.
    let kalmanGain: Double
    /// Measurement noise variance used.
    let measurementNoise: Double
    /// Deviation of raw from predicted (BPM).
    let innovation: Double
}

/// Kalman filter for resting and sleep heart rate.
final class RestingHRFilter {

    // MARK: - Configuration

    /// Physiological bounds for resting HR.
    static let minHR: Double = 35.0
    static let maxHR: Double = 130.0

    /// Max rise rate at rest (BPM/sec). Even a startle response is ~1-2 BPM/sec.
    static let maxRiseRate: Double = 1.5
    /// Max fall rate at rest (BPM/sec).
    static let maxFallRate: Double = 2.0

    /// Rate damping — dHR/dt decays toward 0 each tick.
    /// 0.90 = faster decay than workout (0.95) since resting HR is nearly constant.
    static let rateDamping: Double = 0.90

    /// Base measurement noise for a clean reading (BPM²).
    static let baseNoiseVariance: Double = 4.0

    /// Process noise — very low because resting HR barely changes.
    static let processNoiseHR: Double = 0.05   // BPM²/sec (vs 2.0 for workout)
    static let processNoiseRate: Double = 0.01  // (BPM/sec)²/sec (vs 0.5 for workout)

    /// Maximum covariance P[0] — prevents the filter from opening up after long
    /// gaps (e.g., 5-min slots in historical HR logs). Without this cap, P grows
    /// so large that the Kalman gain trusts even wildly wrong measurements.
    static let maxCovarianceHR: Double = 16.0   // ~4 BPM uncertainty max

    /// Deviation threshold — smaller than workout since large jumps are artifacts.
    static let deviationThreshold: Double = 10.0

    /// Deviation penalty multiplier — aggressive rejection of outliers.
    static let deviationPenaltyScale: Double = 10.0

    // MARK: - State

    /// State: [HR, dHR/dt]
    private var x: [Double] = [0.0, 0.0]

    /// Error covariance (2x2 row-major).
    private var P: [Double] = [100.0, 0.0, 0.0, 10.0]

    private var initialized = false
    private var previousTime: Date?
    private var previousHR: Double = 0.0

    // MARK: - Public API

    /// Process a single HR reading. Returns filtered result.
    /// - Parameters:
    ///   - rawBPM: Raw BPM from ring (0 = no reading).
    ///   - time: Timestamp of the reading.
    func process(rawBPM: Int, time: Date) -> RestingHRFilterResult {
        let dt: Double
        if let prev = previousTime {
            dt = max(0.1, min(300.0, time.timeIntervalSince(prev)))
        } else {
            dt = 1.0
        }
        previousTime = time

        // Initialize on first valid reading
        if !initialized && rawBPM > 0 {
            x = [Double(rawBPM), 0.0]
            P = [Self.baseNoiseVariance, 0.0, 0.0, 1.0]
            initialized = true
            previousHR = Double(rawBPM)
            return RestingHRFilterResult(
                bpm: rawBPM, rawBPM: rawBPM, wasFiltered: false,
                confidence: 1.0, kalmanGain: 1.0,
                measurementNoise: Self.baseNoiseVariance, innovation: 0.0
            )
        }

        // Predict
        predict(dt: dt)

        guard rawBPM > 0 else {
            // No measurement — coast
            constrainState(dt: dt)
            return RestingHRFilterResult(
                bpm: Int(x[0].rounded()), rawBPM: 0, wasFiltered: false,
                confidence: max(0.1, 1.0 - sqrt(P[0]) / 20.0),
                kalmanGain: 0, measurementNoise: 0, innovation: 0
            )
        }

        // Compute measurement noise
        let R = computeMeasurementNoise(rawBPM: rawBPM, dt: dt)

        // Update
        let innovation = Double(rawBPM) - x[0]
        let K = update(measurement: Double(rawBPM), R: R)

        constrainState(dt: dt)

        let wasFiltered = R > Self.baseNoiseVariance * 3.0
        let confidence = computeConfidence(noise: R)
        let outputBPM = Int(x[0].rounded())

        return RestingHRFilterResult(
            bpm: max(Int(Self.minHR), min(Int(Self.maxHR), outputBPM)),
            rawBPM: rawBPM,
            wasFiltered: wasFiltered,
            confidence: confidence,
            kalmanGain: K[0],
            measurementNoise: R,
            innovation: innovation
        )
    }

    /// Process an array of (bpm, time) readings. Convenience for batch filtering.
    func processLog(_ readings: [(bpm: Int, time: Date)]) -> [RestingHRFilterResult] {
        return readings.map { process(rawBPM: $0.bpm, time: $0.time) }
    }

    /// Reset filter state.
    func reset() {
        x = [0.0, 0.0]
        P = [100.0, 0.0, 0.0, 10.0]
        initialized = false
        previousTime = nil
        previousHR = 0.0
    }

    // MARK: - Kalman Mechanics

    private func predict(dt: Double) {
        let hr = x[0] + x[1] * dt
        let rate = Self.rateDamping * x[1]
        x = [hr, rate]

        let f01 = dt
        let f11 = Self.rateDamping

        let fp00 = P[0] + f01 * P[2]
        let fp01 = P[1] + f01 * P[3]
        let fp10 = f11 * P[2]
        let fp11 = f11 * P[3]

        let qHR = Self.processNoiseHR
        let qRate = Self.processNoiseRate

        P = [
            min(fp00 + qHR * dt * dt, Self.maxCovarianceHR),
            fp00 * f01 + fp01 * f11,
            fp10,
            fp10 * f01 + fp11 * f11 + qRate * dt
        ]
    }

    private func update(measurement: Double, R: Double) -> [Double] {
        let S = P[0] + R
        guard S > 0 else { return [0, 0] }

        let K0 = P[0] / S
        let K1 = P[2] / S

        let innovation = measurement - x[0]
        x[0] += K0 * innovation
        x[1] += K1 * innovation

        // Joseph form covariance update
        let ikh00 = 1.0 - K0
        let ikh10 = -K1

        let a00 = ikh00 * P[0]
        let a01 = ikh00 * P[1]
        let a10 = ikh10 * P[0] + P[2]
        let a11 = ikh10 * P[1] + P[3]

        P = [
            a00 * ikh00 + a01 * ikh10 + K0 * R * K0,
            a01 + K0 * R * K1,
            a10 * ikh00 + a11 * ikh10 + K1 * R * K0,
            a10 * 0.0 + a11 + K1 * R * K1
        ]

        return [K0, K1]
    }

    // MARK: - Measurement Noise

    private func computeMeasurementNoise(rawBPM: Int, dt: Double) -> Double {
        var R = Self.baseNoiseVariance

        guard initialized else { return R }

        // 1. Asymmetric deviation penalty — primary artifact detector.
        //    Upward spikes (55 → 150) are almost always artifacts.
        //    Downward drops (84 → 50) are often the ring getting a clean read
        //    after a noisy period, so penalize them much less.
        let predicted = x[0]
        let deviation = Double(rawBPM) - predicted
        if deviation > Self.deviationThreshold {
            // Upward spike: heavy penalty
            let factor = deviation / Self.deviationThreshold
            R *= (1.0 + Self.deviationPenaltyScale * factor * factor)
        } else if deviation < -Self.deviationThreshold * 2.0 {
            // Downward drop: mild penalty only for extreme drops (> 2x threshold)
            let factor = abs(deviation) / (Self.deviationThreshold * 2.0)
            R *= (1.0 + factor)
        }

        // 2. Out-of-resting-range penalty.
        //    Readings above 90 BPM during rest are suspicious; above 100 almost
        //    certainly artifacts. Quadratic penalty makes 120+ BPM nearly impossible.
        if rawBPM > 90 {
            let excess = Double(rawBPM - 90)
            R *= (1.0 + excess * excess / 25.0)
        }

        // 3. Staleness penalty — longer gaps mean more uncertainty,
        //    but cap it so the filter doesn't open up too much.
        if dt > 10.0 {
            R *= min(3.0, 1.0 + (dt / 30.0))
        }

        return R
    }

    // MARK: - Constraints

    private func constrainState(dt: Double) {
        if previousHR > 0 {
            let maxRise = Self.maxRiseRate * dt
            let maxFall = Self.maxFallRate * dt
            let upper = previousHR + maxRise
            let lower = previousHR - maxFall
            x[0] = max(lower, min(upper, x[0]))
        }
        previousHR = x[0]

        x[0] = max(Self.minHR, min(Self.maxHR, x[0]))
        x[1] = max(-Self.maxFallRate, min(Self.maxRiseRate, x[1]))
    }

    // MARK: - Confidence

    private func computeConfidence(noise: Double) -> Double {
        let noiseRatio = Self.baseNoiseVariance / max(noise, 0.01)
        return max(0.1, min(1.0, noiseRatio))
    }
}
