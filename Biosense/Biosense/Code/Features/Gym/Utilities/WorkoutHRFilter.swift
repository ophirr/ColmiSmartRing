//
//  WorkoutHRFilter.swift
//  Biosense
//
//  Hybrid workout HR filter: slew-rate limiter + cadence harmonic detection
//  + cadence-aware crash guard.
//
//  Layer 1 — Slew-rate limiter: caps BPM change to ±maxSlewPerSecond per tick.
//            Prevents impossible single-tick spikes and cliffs.
//
//  Layer 2 — Cadence harmonic detection: if HR matches a cadence harmonic
//            (1x, 0.5x, 2x), the PPG likely locked onto step frequency.
//            Holds the pre-coupling trend to avoid displaying inflated HR.
//
//  Layer 3 — Cadence-aware crash guard: if HR drops sharply while stepping
//            cadence remains stable (still exercising), holds the recent
//            trend value instead of displaying the crash.
//
//  Pure logic — no BLE or UI dependencies. Fully testable.
//

import Foundation

/// Hybrid filter combining slew-rate limiting with cadence-aware plausibility.
/// Create one instance per workout session; call `process()` once per tick (~1 Hz).
final class WorkoutHRFilter {

    // MARK: - Configuration

    /// Maximum BPM change per second. Physiological max during exercise is
    /// ~3-4 BPM/sec at sprint onset. 3.0 provides reasonable smoothing while
    /// allowing real HR changes to converge within a few seconds.
    static let maxSlewPerSecond: Double = 3.0

    /// Minimum cadence (SPM) for the crash guard to activate.
    static let crashGuardMinCadence: Int = 100

    /// HR drop (BPM below recent trend) that triggers the crash guard
    /// while cadence remains stable.
    static let crashDropThreshold: Int = 20

    /// Cadence range (max - min of recent samples) below which cadence
    /// is considered "stable" for crash guard purposes.
    static let cadenceStableRange: Int = 20

    /// Number of recent output samples for trend estimation.
    static let trendWindow: Int = 8

    /// Maximum ticks the crash guard will hold before releasing.
    /// At 1 Hz this is 30 seconds — long enough to ride out a sensor glitch,
    /// short enough to not mask a real cooldown.
    static let crashGuardMaxHold: Int = 30

    /// Number of recent cadence samples for smoothing/stability.
    static let cadenceSmoothingWindow: Int = 5

    // Layer 2 — Harmonic detection config

    /// BPM proximity threshold for flagging cadence coupling.
    /// Slightly wider than CadenceRejectionFilter's 7 to account for
    /// slew limiting shifting values slightly.
    static let harmonicThresholdBPM: Int = 8

    /// Minimum cadence (SPM) to activate harmonic detection.
    /// Below ~110 SPM, cadence rarely overlaps exercise HR range.
    static let harmonicMinCadence: Int = 110

    /// Maximum ticks harmonic detection will hold before releasing.
    /// At 1 Hz this is 30 seconds. After this, if the reading still
    /// matches cadence, it might genuinely be the real HR.
    static let harmonicMaxHold: Int = 30

    // MARK: - State

    private var previousOutputBPM: Int?
    private var previousOutputTime: Date?

    /// Recent output BPM values for trend estimation (crash guard).
    private var recentOutputs: [Int] = []

    /// Cadence estimation state.
    private var recentCadenceSamples: [Int] = []
    private var previousSteps: Int?
    private var previousStepTime: Date?
    /// Last non-zero cadence and when it was computed. Cadence data from 0x78
    /// arrives intermittently — gaps don't mean the user stopped moving.
    /// We hold the last known cadence for up to `cadenceHoldSeconds` to avoid
    /// the harmonic filter flickering on/off during reporting gaps.
    private var lastKnownCadence: Int = 0
    private var lastKnownCadenceTime: Date?
    /// How long to hold the last known cadence during data gaps (seconds).
    private static let cadenceHoldSeconds: TimeInterval = 10.0

    /// Crash guard consecutive hold counter.
    private var crashGuardConsecutive: Int = 0

    /// Harmonic detection state.
    private var harmonicConsecutive: Int = 0
    /// The trend BPM snapshot taken when harmonic coupling was first detected.
    /// This is the "last known good" value before coupling inflated the reading.
    private var harmonicHeldBPM: Int?

    /// Running statistics.
    private(set) var totalReadings: Int = 0
    private(set) var correctedReadings: Int = 0
    // Breakdown by correction type.
    private(set) var slewLimitedCount: Int = 0
    private(set) var crashGuardedCount: Int = 0
    private(set) var harmonicCorrectedCount: Int = 0

    // MARK: - Public API

    /// Process a single HR reading.
    ///
    /// - Parameters:
    ///   - rawBPM: The reported HR from the ring.
    ///   - cumulativeSteps: Current cumulative step count (from 0x78).
    ///   - timestamp: Current tick time.
    /// - Returns: Filtered result with the same shape as CadenceFilterResult.
    func process(rawBPM: Int, cumulativeSteps: Int, timestamp: Date) -> CadenceFilterResult {
        totalReadings += 1

        let cadenceSPM = updateCadence(steps: cumulativeSteps, at: timestamp)

        guard rawBPM > 0 else {
            return CadenceFilterResult(
                bpm: 0, wasCorrected: false, confidence: 0.0,
                cadenceSPM: cadenceSPM, harmonicMatch: .none
            )
        }

        // --- Layer 1: Slew-rate limiter ---

        var outputBPM = rawBPM
        var wasCorrected = false
        var confidence = 1.0
        var slewDelta = 0
        var slewApplied = false
        var crashApplied = false
        var harmonicApplied = false
        var harmonicMatch: CadenceHarmonicMatch = .none

        if let prevBPM = previousOutputBPM, let prevTime = previousOutputTime {
            let dt = max(0.5, timestamp.timeIntervalSince(prevTime))
            let maxDelta = Int(Self.maxSlewPerSecond * dt)
            let delta = rawBPM - prevBPM

            if abs(delta) > maxDelta {
                slewDelta = delta - (delta > 0 ? maxDelta : -maxDelta)
                outputBPM = prevBPM + (delta > 0 ? maxDelta : -maxDelta)
                wasCorrected = true
                slewApplied = true
                confidence = 0.6

                slewLimitedCount += 1
                tLog("[HRFilter] SLEW raw=\(rawBPM) prev=\(prevBPM) "
                     + "dt=\(String(format: "%.1f", dt))s maxΔ=\(maxDelta) "
                     + "clamped=\(outputBPM) slewΔ=\(slewDelta)")
            }
        }

        // --- Layer 2: Cadence harmonic detection ---
        //
        // If the (post-slew) HR is within threshold of a cadence harmonic,
        // the PPG has likely locked onto step frequency. Hold the pre-coupling
        // trend value to avoid displaying an inflated reading.
        //
        // This catches the common failure mode where the ring reads 170 BPM
        // while cadence is 175 SPM — a 1x fundamental match that looks
        // plausible but is ~30 BPM above actual HR.

        let trendBPM = recentTrendBPM()

        if cadenceSPM >= Self.harmonicMinCadence {
            harmonicMatch = detectHarmonic(bpm: outputBPM, cadenceSPM: cadenceSPM)

            if harmonicMatch != .none {
                harmonicConsecutive += 1

                if harmonicConsecutive == 1 {
                    // First detection — snapshot the current trend as the held value.
                    // This captures the last known HR before coupling inflated it.
                    harmonicHeldBPM = trendBPM > 0 ? trendBPM : nil
                }

                if harmonicConsecutive <= Self.harmonicMaxHold, let held = harmonicHeldBPM {
                    wasCorrected = true
                    harmonicApplied = true
                    confidence = max(0.3, 0.7 - Double(harmonicConsecutive) * 0.015)

                    harmonicCorrectedCount += 1
                    tLog("[HRFilter] HARMONIC raw=\(rawBPM) slewed=\(outputBPM) "
                         + "cadence=\(cadenceSPM)SPM match=\(harmonicMatch.rawValue) "
                         + "held=\(held) consecutive=\(harmonicConsecutive)")

                    outputBPM = held
                } else {
                    // Exceeded max hold or no trend available — release with low confidence.
                    harmonicConsecutive = 0
                    harmonicHeldBPM = nil
                    confidence = 0.2
                    tLog("[HRFilter] HARMONIC released after \(Self.harmonicMaxHold)s "
                         + "raw=\(rawBPM) cadence=\(cadenceSPM)SPM")
                }
            } else {
                harmonicConsecutive = 0
                harmonicHeldBPM = nil
            }
        } else {
            harmonicConsecutive = 0
            harmonicHeldBPM = nil
        }

        // --- Layer 3: Cadence-aware crash guard ---

        if cadenceSPM >= Self.crashGuardMinCadence,
           trendBPM > 0,
           trendBPM - outputBPM > Self.crashDropThreshold,
           isCadenceStable()
        {
            if crashGuardConsecutive < Self.crashGuardMaxHold {
                crashGuardConsecutive += 1
                let held = trendBPM
                wasCorrected = true
                crashApplied = true
                // Confidence decays the longer we hold.
                confidence = max(0.3, 0.7 - Double(crashGuardConsecutive) * 0.015)

                crashGuardedCount += 1
                tLog("[HRFilter] CRASH_GUARD raw=\(rawBPM) slewed=\(outputBPM) "
                     + "trend=\(trendBPM) cadence=\(cadenceSPM)SPM "
                     + "held=\(held) consecutive=\(crashGuardConsecutive)")

                outputBPM = held
            } else {
                // Exceeded max hold — release with low confidence.
                crashGuardConsecutive = 0
                confidence = 0.2
                tLog("[HRFilter] CRASH_GUARD released after \(Self.crashGuardMaxHold)s "
                     + "raw=\(rawBPM) cadence=\(cadenceSPM)SPM")
            }
        } else {
            crashGuardConsecutive = 0
        }

        if wasCorrected { correctedReadings += 1 }

        let reason: String
        if harmonicApplied && slewApplied { reason = "harmonic+slew" }
        else if harmonicApplied { reason = "harmonic" }
        else if slewApplied && crashApplied { reason = "slew+crash" }
        else if slewApplied { reason = "slew" }
        else if crashApplied { reason = "crash_guard" }
        else { reason = "clean" }

        // --- Update state ---

        previousOutputBPM = outputBPM
        previousOutputTime = timestamp

        recentOutputs.append(outputBPM)
        if recentOutputs.count > Self.trendWindow {
            recentOutputs.removeFirst()
        }

        return CadenceFilterResult(
            bpm: outputBPM,
            wasCorrected: wasCorrected,
            confidence: confidence,
            cadenceSPM: cadenceSPM,
            harmonicMatch: harmonicMatch,
            slewDelta: slewDelta,
            trendBPM: trendBPM,
            filterReason: reason,
            crashGuardCount: crashGuardConsecutive
        )
    }

    /// Reset all state. Call when starting a new workout.
    func reset() {
        previousOutputBPM = nil
        previousOutputTime = nil
        recentOutputs = []
        recentCadenceSamples = []
        previousSteps = nil
        previousStepTime = nil
        lastKnownCadence = 0
        lastKnownCadenceTime = nil
        crashGuardConsecutive = 0
        harmonicConsecutive = 0
        harmonicHeldBPM = nil
        totalReadings = 0
        correctedReadings = 0
        slewLimitedCount = 0
        crashGuardedCount = 0
        harmonicCorrectedCount = 0
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
        guard dt > 0.5 && dt < 3.0 else {
            return heldCadence(at: timestamp)
        }

        let deltaSteps = steps - prevSteps
        guard deltaSteps >= 0 else {
            return heldCadence(at: timestamp)
        }

        // No new steps this tick — user might still be moving, hold last cadence.
        if deltaSteps == 0 {
            return heldCadence(at: timestamp)
        }

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

    /// Return the last known cadence if it's recent enough, otherwise 0.
    private func heldCadence(at timestamp: Date) -> Int {
        guard lastKnownCadence > 0, let lastTime = lastKnownCadenceTime else {
            return smoothedCadence()
        }
        let age = timestamp.timeIntervalSince(lastTime)
        if age <= Self.cadenceHoldSeconds {
            return lastKnownCadence
        }
        return smoothedCadence()
    }

    /// Median of recent cadence samples (robust to outliers).
    private func smoothedCadence() -> Int {
        guard !recentCadenceSamples.isEmpty else { return 0 }
        let sorted = recentCadenceSamples.sorted()
        return sorted[sorted.count / 2]
    }

    /// Whether recent cadence is stable (low variance).
    private func isCadenceStable() -> Bool {
        guard recentCadenceSamples.count >= 3 else { return false }
        let sorted = recentCadenceSamples.sorted()
        return (sorted.last! - sorted.first!) < Self.cadenceStableRange
    }

    // MARK: - Harmonic Detection

    /// Check whether bpm is within threshold of any cadence harmonic.
    private func detectHarmonic(bpm: Int, cadenceSPM: Int) -> CadenceHarmonicMatch {
        // 1x fundamental: HR ≈ cadence (e.g. 170 BPM ≈ 175 SPM)
        if abs(bpm - cadenceSPM) <= Self.harmonicThresholdBPM {
            return .fundamental
        }
        // 0.5x sub-harmonic: HR ≈ cadence/2 (e.g. 85 BPM ≈ 170/2)
        let half = cadenceSPM / 2
        if half > 40 && abs(bpm - half) <= Self.harmonicThresholdBPM {
            return .half
        }
        // 2x harmonic: HR ≈ cadence*2 (e.g. 240 BPM ≈ 120*2)
        let doubled = cadenceSPM * 2
        if doubled < 250 && abs(bpm - doubled) <= Self.harmonicThresholdBPM {
            return .double
        }
        return .none
    }

    // MARK: - Trend Estimation

    /// Median of recent output values — robust to individual outliers.
    private func recentTrendBPM() -> Int {
        guard recentOutputs.count >= 3 else { return 0 }
        let sorted = recentOutputs.sorted()
        return sorted[sorted.count / 2]
    }
}
