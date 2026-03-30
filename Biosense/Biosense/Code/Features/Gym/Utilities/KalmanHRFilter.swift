//
//  KalmanHRFilter.swift
//  Biosense
//
//  Extended Kalman Filter for workout heart rate estimation.
//  Replaces WorkoutHRFilter's three heuristic layers (slew-rate limiter,
//  harmonic detection, crash guard) with a unified probabilistic state
//  estimator.
//
//  State: [HR, dHR/dt]  (heart rate and its rate of change)
//  Observation: raw BPM reading with dynamic noise based on source quality,
//               cadence proximity, deviation from prediction, and packet age.
//
//  Key advantages over heuristic approach:
//  - Continuous blending instead of binary hold/pass decisions
//  - Deviation-from-prediction penalty catches PPG overread at low cadence
//  - Natural confidence decay during data gaps (no fixed hold timers)
//  - Multi-source fusion via sequential Kalman updates
//
//  Pure logic — no BLE or UI dependencies. Fully testable.
//

import Foundation

/// Result of processing a single tick through the Kalman HR filter.
struct KalmanFilterResult {
    let bpm: Int
    let confidence: Double
    let predictedBPM: Int
    /// Difference between raw measurement and Kalman prediction (BPM).
    let innovationBPM: Double
    /// Measurement noise variance (R) used for this reading.
    let measurementNoise: Double
    /// Kalman gain for HR state — how much the measurement was trusted (0–1).
    let kalmanGain: Double
    let cadenceSPM: Int
    /// Estimated rate of HR change (BPM/sec).
    let hrRate: Double
    /// Standard deviation of the HR state estimate.
    let stateUncertainty: Double
    /// Why the filter adjusted: describes the dominant noise penalty.
    let filterReason: String
    /// Whether any noise penalty was applied (reading was "corrected").
    let wasCorrected: Bool
}

/// Extended Kalman Filter for workout heart rate estimation.
final class KalmanHRFilter {

    // MARK: - Configuration

    /// Physiological HR bounds.
    static let minHR: Double = 40.0
    static let maxHR: Double = 210.0

    /// Maximum physiological rate of rise (BPM/sec) — sprint onset.
    static let maxRiseRate: Double = 4.0
    /// Maximum physiological rate of fall (BPM/sec) — active recovery in fit individual.
    static let maxFallRate: Double = 6.0

    /// Process model damping factor — dHR/dt decays toward 0 each tick.
    /// 0.95 means rate halves every ~14 seconds.
    static let rateDamping: Double = 0.95

    /// Base measurement noise variance (BPM²) for a clean, fresh 0x78 reading.
    static let baseNoiseVariance: Double = 4.0

    /// Process noise for HR state (BPM²/sec).
    static let processNoiseHR: Double = 2.0
    /// Process noise for rate state ((BPM/sec)²/sec).
    static let processNoiseRate: Double = 0.5

    /// Cadence proximity threshold (BPM) for noise penalty activation.
    static let cadenceProximityThreshold: Int = 15
    /// Sigmoid midpoint for cadence proximity penalty.
    static let cadenceProximitySigmoidMid: Double = 8.0
    /// Minimum cadence (SPM) to activate cadence-aware noise adjustment.
    static let minCadenceForAdjustment: Int = 100

    /// Deviation from prediction (BPM) above which noise is inflated.
    static let deviationThreshold: Double = 20.0

    // MARK: - HR Source

    enum HRSource: String {
        case phoneSport0x78 = "0x78"
        case realtime0x69 = "0x69"
        case sportRT0x73 = "0x78-rt"
        case none = "none"
    }

    // MARK: - State

    /// State estimate [HR, dHR/dt].
    private var x: [Double] = [0.0, 0.0]

    /// Error covariance matrix (2×2, row-major: [p00, p01, p10, p11]).
    private var P: [Double] = [100.0, 0.0, 0.0, 10.0]

    private var initialized = false
    private var previousTime: Date?

    // Source transition smoothing
    private var lastSource: HRSource?
    private var sourceTransitionTicks: Int = 0
    private static let transitionSmoothingTicks: Int = 3

    // Cadence estimation (same approach as WorkoutHRFilter)
    private var previousSteps: Int?
    private var previousStepTime: Date?
    private var recentCadenceSamples: [Int] = []
    private var lastKnownCadence: Int = 0
    private var lastKnownCadenceTime: Date?
    private static let cadenceSmoothingWindow: Int = 5
    private static let cadenceHoldSeconds: TimeInterval = 10.0

    // Phase 1: Cadence transition tracking (S-R1, S-R3)
    private var previousCadenceSPM: Int = 0
    private var cadenceTransitionTicksRemaining: Int = 0
    private var cadenceTransitionDirection: Int = 0  // +1 = walk→run, -1 = run→walk
    private static let cadenceTransitionThreshold: Int = 40
    private static let cadenceTransitionDuration: Int = 5

    // Statistics
    private(set) var totalReadings: Int = 0
    private(set) var correctedReadings: Int = 0
    private(set) var highNoiseReadings: Int = 0

    // MARK: - Public API

    /// Process a single HR reading through the Kalman filter.
    func process(rawBPM: Int, cumulativeSteps: Int, source: HRSource,
                 packetAge: TimeInterval, timestamp: Date) -> KalmanFilterResult? {
        totalReadings += 1
        let cadenceSPM = updateCadence(steps: cumulativeSteps, at: timestamp)

        // --- Initialization ---
        if !initialized && rawBPM > 0 {
            x = [Double(rawBPM), 0.0]
            P = [100.0, 0.0, 0.0, 10.0]
            initialized = true
            previousTime = timestamp
            lastSource = source
            return KalmanFilterResult(
                bpm: rawBPM, confidence: 0.5, predictedBPM: rawBPM,
                innovationBPM: 0, measurementNoise: Self.baseNoiseVariance,
                kalmanGain: 1.0, cadenceSPM: cadenceSPM, hrRate: 0,
                stateUncertainty: 10.0, filterReason: "init", wasCorrected: false
            )
        }

        guard initialized, let prevTime = previousTime else {
            return nil
        }

        let dt = max(0.5, min(5.0, timestamp.timeIntervalSince(prevTime)))
        previousTime = timestamp

        // === PREDICT ===
        let (qHR, qRate) = adaptiveProcessNoise(cadenceSPM: cadenceSPM, currentHR: x[0])
        predict(dt: dt, qHR: qHR, qRate: qRate)

        let predictedBPM = x[0]

        // === UPDATE ===
        if rawBPM > 0 {
            let transitionMultiplier = sourceTransitionPenalty(currentSource: source)
            let R = computeMeasurementNoise(
                rawBPM: rawBPM, cadenceSPM: cadenceSPM,
                source: source, packetAge: packetAge
            ) * transitionMultiplier

            let innovation = Double(rawBPM) - x[0]
            let K = update(measurement: Double(rawBPM), R: R)

            constrainState()

            let wasCorrected = R > Self.baseNoiseVariance * 3.0
            if wasCorrected {
                correctedReadings += 1
                highNoiseReadings += 1
            }

            let confidence = computeConfidence(kalmanGain: K[0], noise: R)
            let reason = dominantReason(
                cadenceSPM: cadenceSPM, rawBPM: rawBPM,
                source: source, packetAge: packetAge,
                deviation: abs(innovation), transitionMultiplier: transitionMultiplier
            )

            return KalmanFilterResult(
                bpm: Int(round(x[0])),
                confidence: confidence,
                predictedBPM: Int(round(predictedBPM)),
                innovationBPM: innovation,
                measurementNoise: R,
                kalmanGain: K[0],
                cadenceSPM: cadenceSPM,
                hrRate: x[1],
                stateUncertainty: sqrt(P[0]),
                filterReason: reason,
                wasCorrected: wasCorrected
            )
        } else {
            // No measurement — coast on prediction only
            constrainState()

            let pUncertainty = sqrt(P[0])
            let confidence = max(0.1, 1.0 - pUncertainty / 30.0)

            return KalmanFilterResult(
                bpm: Int(round(x[0])),
                confidence: confidence,
                predictedBPM: Int(round(predictedBPM)),
                innovationBPM: 0,
                measurementNoise: .infinity,
                kalmanGain: 0,
                cadenceSPM: cadenceSPM,
                hrRate: x[1],
                stateUncertainty: pUncertainty,
                filterReason: "coasting",
                wasCorrected: false
            )
        }
    }

    /// Reset all state for a new workout.
    func reset() {
        x = [0.0, 0.0]
        P = [100.0, 0.0, 0.0, 10.0]
        initialized = false
        previousTime = nil
        lastSource = nil
        sourceTransitionTicks = 0
        previousSteps = nil
        previousStepTime = nil
        recentCadenceSamples = []
        lastKnownCadence = 0
        lastKnownCadenceTime = nil
        previousCadenceSPM = 0
        cadenceTransitionTicksRemaining = 0
        cadenceTransitionDirection = 0
        totalReadings = 0
        correctedReadings = 0
        highNoiseReadings = 0
    }

    // MARK: - Kalman Mechanics

    /// Prediction step: propagate state and covariance forward by dt seconds.
    private func predict(dt: Double, qHR: Double, qRate: Double) {
        // Phase 1 (S-R3): Adaptive rate damping during cadence transitions.
        // When transitioning run→walk, aggressively damp the rate state so
        // dHR/dt doesn't carry positive momentum from the push phase.
        let effectiveDamping: Double
        if cadenceTransitionTicksRemaining > 0 && cadenceTransitionDirection < 0 {
            effectiveDamping = 0.85  // aggressive: expect HR to fall
        } else if cadenceTransitionTicksRemaining > 0 && cadenceTransitionDirection > 0 {
            effectiveDamping = 0.90  // moderate: expect HR to rise
        } else {
            effectiveDamping = Self.rateDamping  // 0.95 normal
        }

        // State prediction: x = F * x
        let hr = x[0] + x[1] * dt
        let rate = effectiveDamping * x[1]
        x = [hr, rate]

        // Covariance prediction: P = F * P * F^T + Q
        let f01 = dt
        let f11 = effectiveDamping

        // F * P
        let fp00 = P[0] + f01 * P[2]
        let fp01 = P[1] + f01 * P[3]
        let fp10 = f11 * P[2]
        let fp11 = f11 * P[3]

        // (F * P) * F^T
        P = [
            fp00 + fp01 * 0.0 + qHR * dt * dt,  // simplified: fp00*1 + fp01*0
            fp00 * f01 + fp01 * f11,
            fp10 + fp11 * 0.0,                    // simplified: fp10*1 + fp11*0
            fp10 * f01 + fp11 * f11 + qRate * dt
        ]
    }

    /// Update step: incorporate a measurement with noise variance R.
    /// Returns the Kalman gain vector [K0, K1].
    private func update(measurement: Double, R: Double) -> [Double] {
        // Innovation covariance: S = H * P * H^T + R = P[0] + R
        let S = P[0] + R
        guard S > 0 else { return [0, 0] }

        // Kalman gain: K = P * H^T / S
        let K0 = P[0] / S
        let K1 = P[2] / S

        // State update: x = x + K * innovation
        let innovation = measurement - x[0]
        x[0] += K0 * innovation
        x[1] += K1 * innovation

        // Covariance update: P = (I - K*H) * P  (Joseph form for stability)
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

    // MARK: - Measurement Noise Model

    /// Compute dynamic measurement noise variance R based on reading quality signals.
    private func computeMeasurementNoise(rawBPM: Int, cadenceSPM: Int,
                                          source: HRSource, packetAge: TimeInterval) -> Double {
        var R = Self.baseNoiseVariance

        // Phase 1 (P-R1): Cadence-proportional base noise scaling.
        // During running (SPM > 100), the ring's PPG systematically overreads
        // by 20-30 BPM due to motion artifact. With K even at 0.15, consecutive
        // biased readings accumulate and the prediction drifts up. We need R
        // high enough that K stays near 0.02-0.05 during running so the filter
        // relies almost entirely on its prediction and rate model.
        //
        // At SPM 118 (typical run): factor=1.8, R = 4 * (1+20*3.24) = 263
        // With P ≈ 10, K ≈ 10/(10+263) = 0.04. Filter trusts prediction 96%.
        if cadenceSPM > 100 {
            let cadenceFactor = Double(cadenceSPM - 100) / 10.0
            let cadenceNoiseMultiplier = 1.0 + 20.0 * cadenceFactor * cadenceFactor
            R *= cadenceNoiseMultiplier
        }

        // 1. Cadence proximity penalty (sigmoid, not binary)
        if cadenceSPM >= Self.minCadenceForAdjustment {
            let proximity = cadenceHarmonicDistance(bpm: rawBPM, cadenceSPM: cadenceSPM)
            if proximity < Self.cadenceProximityThreshold {
                let exponent = (Double(proximity) - Self.cadenceProximitySigmoidMid) * 0.5
                let penalty = 10.0 / (1.0 + exp(exponent))
                R += penalty * Self.baseNoiseVariance
            }
        }

        // 2. Source quality penalty
        switch source {
        case .phoneSport0x78: break
        case .realtime0x69:   R *= 2.0
        case .sportRT0x73:    R *= 1.5
        case .none:           R *= 10.0
        }

        // 3. Staleness penalty
        if packetAge > 2.0 {
            R *= (1.0 + pow(packetAge / 2.0, 2))
        }

        // 4. Deviation from prediction penalty — the key innovation.
        //    When the raw reading deviates significantly from the Kalman
        //    prediction, trust it less. This catches PPG overread at low
        //    cadence where no harmonic detection would trigger.
        if initialized {
            let deviation = abs(Double(rawBPM) - x[0])
            if deviation > Self.deviationThreshold {
                R *= (1.0 + deviation / Self.deviationThreshold)
            }
        }

        return R
    }

    /// Minimum distance from BPM to any cadence harmonic (1x, 0.5x, 2x).
    private func cadenceHarmonicDistance(bpm: Int, cadenceSPM: Int) -> Int {
        let d1x = abs(bpm - cadenceSPM)
        let d05x = abs(bpm - cadenceSPM / 2)
        let d2x = cadenceSPM * 2 < 250 ? abs(bpm - cadenceSPM * 2) : 999
        return min(d1x, min(d05x, d2x))
    }

    // MARK: - Adaptive Process Noise

    /// Adjust process noise based on exercise phase (inferred from cadence and HR).
    private func adaptiveProcessNoise(cadenceSPM: Int, currentHR: Double) -> (qHR: Double, qRate: Double) {
        // Phase 1 (S-R1): Detect cadence transitions (walk↔run).
        // When cadence changes by >40 SPM, boost process noise so the filter
        // can track the HR change instead of holding the old value.
        let cadenceDelta = cadenceSPM - previousCadenceSPM
        if abs(cadenceDelta) >= Self.cadenceTransitionThreshold {
            cadenceTransitionTicksRemaining = Self.cadenceTransitionDuration
            cadenceTransitionDirection = cadenceDelta > 0 ? 1 : -1
        } else if cadenceTransitionTicksRemaining > 0 {
            cadenceTransitionTicksRemaining -= 1
        }
        previousCadenceSPM = cadenceSPM

        // During a transition, boost process noise 5x to let the filter track rapidly
        let transitionBoost: Double = cadenceTransitionTicksRemaining > 0 ? 5.0 : 1.0

        // Phase 1 (P-R1 companion): Ultra-low process noise during running.
        // With high measurement noise (R ≈ 293 at SPM 118), we also need low
        // process noise to keep P small. Otherwise P grows and K drifts up,
        // letting biased measurements pull the state over sustained running.
        // qHR=0.1 → P converges to ~sqrt(0.1*293) ≈ 5.4 → K ≈ 0.02.
        if cadenceSPM > 100 {
            return (qHR: 0.1 * transitionBoost, qRate: 0.05 * transitionBoost)
        } else if currentHR > 120 && cadenceSPM < 60 {
            // Recovery phase — HR is high but exercise stopped, allow faster decay
            return (qHR: 4.0 * transitionBoost, qRate: 2.0 * transitionBoost)
        } else {
            return (qHR: 1.0 * transitionBoost, qRate: 0.3 * transitionBoost)
        }
    }

    // MARK: - Source Transition Smoothing

    /// Temporarily inflate noise when the HR source changes to prevent step discontinuities.
    private func sourceTransitionPenalty(currentSource: HRSource) -> Double {
        if let last = lastSource, last != currentSource {
            sourceTransitionTicks = Self.transitionSmoothingTicks
        } else if sourceTransitionTicks > 0 {
            sourceTransitionTicks -= 1
        }
        lastSource = currentSource

        if sourceTransitionTicks > 0 {
            return 1.0 + 4.0 * Double(sourceTransitionTicks) / Double(Self.transitionSmoothingTicks)
        }
        return 1.0
    }

    // MARK: - Physiological Constraints

    private func constrainState() {
        x[0] = max(Self.minHR, min(Self.maxHR, x[0]))
        x[1] = max(-Self.maxFallRate, min(Self.maxRiseRate, x[1]))
    }

    // MARK: - Confidence

    private func computeConfidence(kalmanGain: Double, noise: Double) -> Double {
        let noiseRatio = Self.baseNoiseVariance / max(noise, 0.01)
        let gainFactor = min(1.0, kalmanGain * 2.0)
        return max(0.1, min(1.0, (noiseRatio + gainFactor) / 2.0))
    }

    // MARK: - Filter Reason

    /// Identify the dominant noise penalty for telemetry tagging.
    private func dominantReason(cadenceSPM: Int, rawBPM: Int, source: HRSource,
                                 packetAge: TimeInterval, deviation: Double,
                                 transitionMultiplier: Double) -> String {
        var dominant = "clean"
        var maxPenalty = 0.0

        // Cadence intensity (P-R1)
        if cadenceSPM > 100 {
            let cadenceFactor = Double(cadenceSPM - 100) / 10.0
            let penalty = 20.0 * cadenceFactor * cadenceFactor
            if penalty > maxPenalty { maxPenalty = penalty; dominant = "cadence_intensity" }
        }

        // Cadence proximity
        if cadenceSPM >= Self.minCadenceForAdjustment {
            let proximity = cadenceHarmonicDistance(bpm: rawBPM, cadenceSPM: cadenceSPM)
            if proximity < Self.cadenceProximityThreshold {
                let exponent = (Double(proximity) - Self.cadenceProximitySigmoidMid) * 0.5
                let penalty = 10.0 / (1.0 + exp(exponent))
                if penalty > maxPenalty { maxPenalty = penalty; dominant = "cadence_harmonic" }
            }
        }

        // Deviation from prediction
        if deviation > Self.deviationThreshold {
            let penalty = deviation / Self.deviationThreshold
            if penalty > maxPenalty { maxPenalty = penalty; dominant = "deviation" }
        }

        // Source quality
        if source == .realtime0x69 && 2.0 > maxPenalty {
            maxPenalty = 2.0; dominant = "source_0x69"
        }

        // Staleness
        if packetAge > 2.0 {
            let penalty = pow(packetAge / 2.0, 2)
            if penalty > maxPenalty { maxPenalty = penalty; dominant = "stale" }
        }

        // Source transition
        if transitionMultiplier > 1.5 && (transitionMultiplier - 1.0) > maxPenalty {
            dominant = "source_transition"
        }

        return dominant
    }

    // MARK: - Cadence Estimation

    private func updateCadence(steps: Int, at timestamp: Date) -> Int {
        defer {
            previousSteps = steps
            previousStepTime = timestamp
        }
        guard let prevSteps = previousSteps, let prevTime = previousStepTime else {
            return heldCadence(at: timestamp)
        }
        let dt = timestamp.timeIntervalSince(prevTime)
        guard dt > 0.5 && dt < 3.0 else { return heldCadence(at: timestamp) }
        let deltaSteps = steps - prevSteps
        guard deltaSteps >= 0 else { return heldCadence(at: timestamp) }
        if deltaSteps == 0 { return heldCadence(at: timestamp) }

        let instantSPM = Int(Double(deltaSteps) / dt * 60.0)
        recentCadenceSamples.append(instantSPM)
        if recentCadenceSamples.count > Self.cadenceSmoothingWindow {
            recentCadenceSamples.removeFirst()
        }

        let cadence = smoothedCadence()
        if cadence > 0 {
            lastKnownCadence = cadence
            lastKnownCadenceTime = timestamp
        }
        return cadence
    }

    private func heldCadence(at timestamp: Date) -> Int {
        guard lastKnownCadence > 0, let lastTime = lastKnownCadenceTime else {
            return smoothedCadence()
        }
        return timestamp.timeIntervalSince(lastTime) <= Self.cadenceHoldSeconds
            ? lastKnownCadence : smoothedCadence()
    }

    private func smoothedCadence() -> Int {
        guard !recentCadenceSamples.isEmpty else { return 0 }
        let sorted = recentCadenceSamples.sorted()
        return sorted[sorted.count / 2]
    }
}
