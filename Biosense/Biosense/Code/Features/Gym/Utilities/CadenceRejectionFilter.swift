//
//  CadenceRejectionFilter.swift
//  Biosense
//
//  Detects and corrects PPG cadence coupling during running workouts.
//  Cadence coupling occurs when the HR sensor locks onto step frequency
//  (typically 160-180 SPM), inflating the displayed HR by +10-20 BPM.
//
//  Pure logic — no BLE or UI dependencies. Fully testable.
//

import Foundation

/// Result of filtering a single HR reading through cadence rejection.
struct CadenceFilterResult {
    /// The output HR value (corrected if coupling detected, raw otherwise).
    let bpm: Int
    /// Whether this reading was detected as cadence-coupled and corrected.
    let wasCorrected: Bool
    /// Confidence in the output value (1.0 = clean reading, <0.5 = uncertain/corrected).
    let confidence: Double
    /// Instantaneous cadence in SPM derived from step deltas.
    let cadenceSPM: Int
    /// Which harmonic matched, if any.
    let harmonicMatch: CadenceHarmonicMatch
    /// How many BPM the slew-rate limiter clamped (0 = no clamping).
    let slewDelta: Int
    /// The filter's recent trend estimate (median of recent outputs). 0 if insufficient data.
    let trendBPM: Int
    /// Why the filter corrected: "clean", "slew", "crash_guard", or "both".
    let filterReason: String
    /// How many consecutive ticks the crash guard has been holding (0 = not active).
    let crashGuardCount: Int

    init(bpm: Int, wasCorrected: Bool, confidence: Double,
         cadenceSPM: Int, harmonicMatch: CadenceHarmonicMatch,
         slewDelta: Int = 0, trendBPM: Int = 0, filterReason: String = "clean",
         crashGuardCount: Int = 0) {
        self.bpm = bpm
        self.wasCorrected = wasCorrected
        self.confidence = confidence
        self.cadenceSPM = cadenceSPM
        self.harmonicMatch = harmonicMatch
        self.slewDelta = slewDelta
        self.trendBPM = trendBPM
        self.filterReason = filterReason
        self.crashGuardCount = crashGuardCount
    }
}

/// Which cadence harmonic the HR reading matched.
enum CadenceHarmonicMatch: String {
    case none = "none"
    case fundamental = "1x"     // HR ≈ cadence
    case half = "0.5x"          // HR ≈ cadence/2
    case double = "2x"          // HR ≈ cadence*2
}

/// Stateful filter that detects cadence coupling and provides corrected HR.
/// Create one instance per workout session; call `process()` once per tick (~1 Hz).
final class CadenceRejectionFilter {

    // MARK: - Configuration

    /// BPM proximity threshold for flagging cadence coupling.
    static let defaultThresholdBPM: Int = 7

    /// Minimum cadence (SPM) to activate filtering.
    /// 140 SPM is a slow jog; walking cadence (~100-120) rarely overlaps HR range.
    static let activationCadenceSPM: Int = 114

    /// Consecutive flagged seconds before held HR starts decaying.
    static let holdDecayOnsetSeconds: Int = 15

    /// Maximum hold duration before passing through raw at low confidence.
    static let maxHoldSeconds: Int = 60

    /// Number of recent step-delta samples for smoothed cadence estimation.
    static let cadenceSmoothingWindow: Int = 5

    // MARK: - State

    private let thresholdBPM: Int

    /// Last known good (unflagged) HR reading.
    private var lastGoodBPM: Int?
    private var lastGoodTime: Date?
    /// How many consecutive ticks have been flagged.
    private var consecutiveFlaggedCount: Int = 0

    /// Ring buffer of recent instantaneous cadence values for smoothing.
    private var recentCadenceSamples: [Int] = []
    /// Previous cumulative step count for computing deltas.
    private var previousSteps: Int?
    /// Previous tick timestamp.
    private var previousStepTime: Date?

    /// Running statistics.
    private(set) var totalReadings: Int = 0
    private(set) var flaggedReadings: Int = 0

    // MARK: - Init

    init(thresholdBPM: Int = CadenceRejectionFilter.defaultThresholdBPM) {
        self.thresholdBPM = thresholdBPM
    }

    // MARK: - Public API

    /// Process a single HR reading against the current cadence estimate.
    ///
    /// - Parameters:
    ///   - rawBPM: The reported HR from the ring (0x69 stream).
    ///   - cumulativeSteps: Current cumulative step count from 0x78.
    ///   - timestamp: Current tick time.
    /// - Returns: Possibly corrected HR with metadata.
    func process(rawBPM: Int, cumulativeSteps: Int, timestamp: Date) -> CadenceFilterResult {
        totalReadings += 1

        let cadenceSPM = updateCadence(steps: cumulativeSteps, at: timestamp)

        // Below running cadence or no HR — pass through
        guard cadenceSPM >= Self.activationCadenceSPM, rawBPM > 0 else {
            if rawBPM > 0 {
                lastGoodBPM = rawBPM
                lastGoodTime = timestamp
                consecutiveFlaggedCount = 0
            }
            return CadenceFilterResult(
                bpm: rawBPM,
                wasCorrected: false,
                confidence: rawBPM > 0 ? 1.0 : 0.0,
                cadenceSPM: cadenceSPM,
                harmonicMatch: .none
            )
        }

        let harmonicMatch = detectCoupling(rawBPM: rawBPM, cadenceSPM: cadenceSPM)

        if harmonicMatch == .none {
            // Clean reading
            lastGoodBPM = rawBPM
            lastGoodTime = timestamp
            consecutiveFlaggedCount = 0
            return CadenceFilterResult(
                bpm: rawBPM,
                wasCorrected: false,
                confidence: 1.0,
                cadenceSPM: cadenceSPM,
                harmonicMatch: .none
            )
        }

        // Cadence coupling detected
        consecutiveFlaggedCount += 1
        flaggedReadings += 1

        let (correctedBPM, confidence) = computeCorrectedHR(rawBPM: rawBPM)

        tLog("[CadenceFilter] FLAGGED rawHR=\(rawBPM) cadence=\(cadenceSPM)SPM "
             + "harmonic=\(harmonicMatch.rawValue) "
             + "corrected=\(correctedBPM) conf=\(String(format: "%.2f", confidence)) "
             + "consecutive=\(consecutiveFlaggedCount) "
             + "lastGood=\(lastGoodBPM ?? 0)")

        return CadenceFilterResult(
            bpm: correctedBPM,
            wasCorrected: true,
            confidence: confidence,
            cadenceSPM: cadenceSPM,
            harmonicMatch: harmonicMatch
        )
    }

    /// Reset all state. Call when starting a new workout.
    func reset() {
        lastGoodBPM = nil
        lastGoodTime = nil
        consecutiveFlaggedCount = 0
        recentCadenceSamples = []
        previousSteps = nil
        previousStepTime = nil
        totalReadings = 0
        flaggedReadings = 0
    }

    // MARK: - Cadence Estimation

    /// Update cadence estimate from cumulative step count.
    /// Returns smoothed cadence in steps per minute.
    private func updateCadence(steps: Int, at timestamp: Date) -> Int {
        defer {
            previousSteps = steps
            previousStepTime = timestamp
        }

        guard let prevSteps = previousSteps, let prevTime = previousStepTime else {
            return 0
        }

        let dt = timestamp.timeIntervalSince(prevTime)
        guard dt > 0.5 && dt < 3.0 else {
            return smoothedCadence()
        }

        let deltaSteps = steps - prevSteps
        guard deltaSteps >= 0 else {
            return smoothedCadence()
        }

        let instantSPM = Int(Double(deltaSteps) / dt * 60.0)

        recentCadenceSamples.append(instantSPM)
        if recentCadenceSamples.count > Self.cadenceSmoothingWindow {
            recentCadenceSamples.removeFirst()
        }

        return smoothedCadence()
    }

    /// Median of recent cadence samples (robust to outliers).
    private func smoothedCadence() -> Int {
        guard !recentCadenceSamples.isEmpty else { return 0 }
        let sorted = recentCadenceSamples.sorted()
        return sorted[sorted.count / 2]
    }

    // MARK: - Coupling Detection

    /// Check whether rawBPM is within threshold of any cadence harmonic.
    private func detectCoupling(rawBPM: Int, cadenceSPM: Int) -> CadenceHarmonicMatch {
        if abs(rawBPM - cadenceSPM) < thresholdBPM {
            return .fundamental
        }
        let half = cadenceSPM / 2
        if half > 40 && abs(rawBPM - half) < thresholdBPM {
            return .half
        }
        let double = cadenceSPM * 2
        if double < 250 && abs(rawBPM - double) < thresholdBPM {
            return .double
        }
        return .none
    }

    // MARK: - Correction

    /// Compute the corrected HR when coupling is detected.
    /// Three phases: hold → decay blend → pass-through.
    private func computeCorrectedHR(rawBPM: Int) -> (bpm: Int, confidence: Double) {
        guard let goodBPM = lastGoodBPM else {
            // No baseline yet — pass through raw with low confidence.
            return (rawBPM, 0.3)
        }

        if consecutiveFlaggedCount <= Self.holdDecayOnsetSeconds {
            // Hold phase: output last good HR with gradually decreasing confidence.
            let holdFraction = Double(consecutiveFlaggedCount) / Double(Self.holdDecayOnsetSeconds)
            let confidence = max(0.5, 1.0 - holdFraction * 0.5)
            return (goodBPM, confidence)
        }

        if consecutiveFlaggedCount > Self.maxHoldSeconds {
            // Exceeded max hold: pass through raw with very low confidence.
            return (rawBPM, 0.1)
        }

        // Decay phase: blend from lastGoodBPM toward 85% of raw BPM.
        // Rationale: true HR during sustained running is probably elevated
        // but not as high as cadence.
        let decayProgress = Double(consecutiveFlaggedCount - Self.holdDecayOnsetSeconds)
            / Double(Self.maxHoldSeconds - Self.holdDecayOnsetSeconds)
        let target = Int(Double(rawBPM) * 0.85)
        let blended = goodBPM + Int(Double(target - goodBPM) * decayProgress)
        let confidence = max(0.2, 0.5 - decayProgress * 0.3)

        return (blended, confidence)
    }
}
