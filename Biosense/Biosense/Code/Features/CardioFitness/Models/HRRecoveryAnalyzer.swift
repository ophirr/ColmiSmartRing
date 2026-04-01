//
//  HRRecoveryAnalyzer.swift
//  Biosense
//
//  Analyzes post-workout heart rate recovery curves to extract fitness-correlated
//  metrics (HRR60, exponential decay tau). Pure computation, no SwiftData dependency.
//

import Foundation

enum HRRQuality: Int {
    case poor = 0      // Failed quality gates
    case fair = 1      // Marginal data
    case good = 2      // Solid recovery curve
}

struct HRRecoveryResult {
    let hrr60: Int         // HR drop in first 60 seconds
    let tau: Double        // Exponential decay time constant (lower = fitter)
    let rSquared: Double   // Goodness of exponential fit
    let quality: HRRQuality
}

struct HRRecoveryAnalyzer {

    /// Minimum fraction of HRmax the workout must reach for meaningful HRR.
    private static let minIntensityFraction = 0.75
    /// Minimum valid (non-zero) samples in 180s window.
    private static let minValidSamples = 120
    /// Minimum R-squared for the exponential fit to be considered reliable.
    private static let minRSquared = 0.5

    /// Analyze a recovery recording. Returns nil if data is too poor to analyze.
    static func analyze(_ recovery: StoredHRRecovery, restingBPM: Int, hrMax: Int) -> HRRecoveryResult? {
        // Quality gate: workout intensity
        let minPeakHR = Int(Double(hrMax) * minIntensityFraction)
        guard recovery.peakWorkoutBPM >= minPeakHR else { return nil }

        // Quality gate: sample completeness
        let validSamples = recovery.samples.filter { $0 > 0 }
        guard validSamples.count >= minValidSamples else { return nil }

        // Compute HRR60: drop from peak to HR at 60s
        let hrAt60 = averageBPM(in: recovery.samples, from: 55, to: 65)
        guard let hrAt60 else { return nil }
        let hrr60 = recovery.peakWorkoutBPM - hrAt60

        // Fit exponential decay: HR(t) = restingBPM + (peak - restingBPM) * exp(-t/tau)
        // Linearize: ln(HR(t) - restingBPM) = ln(peak - restingBPM) - t/tau
        let peakDelta = Double(recovery.peakWorkoutBPM - restingBPM)
        guard peakDelta > 10 else { return nil } // Peak must be meaningfully above resting

        var xValues: [Double] = []  // time in seconds
        var yValues: [Double] = []  // ln(HR - restingBPM)

        for (i, bpm) in recovery.samples.enumerated() {
            guard bpm > 0 else { continue }
            let delta = Double(bpm - restingBPM)
            guard delta > 0 else { continue }
            xValues.append(Double(i))
            yValues.append(log(delta))
        }

        guard xValues.count >= 30 else { return nil }

        // Simple linear regression on (x, y) to get slope = -1/tau
        let (slope, _, rSquared) = linearRegression(x: xValues, y: yValues)

        guard slope < 0 else { return nil } // HR should be decreasing
        let tau = -1.0 / slope

        // Clamp tau to physiological range (20s to 600s)
        let clampedTau = min(600, max(20, tau))

        let quality: HRRQuality
        if rSquared >= 0.7 && validSamples.count >= 150 {
            quality = .good
        } else if rSquared >= minRSquared {
            quality = .fair
        } else {
            quality = .poor
        }

        // Reject if fit is too poor
        guard rSquared >= minRSquared else { return nil }

        return HRRecoveryResult(hrr60: hrr60, tau: clampedTau, rSquared: rSquared, quality: quality)
    }

    // MARK: - Helpers

    /// Average BPM in a time window (inclusive bounds), skipping zeros.
    private static func averageBPM(in samples: [Int], from: Int, to: Int) -> Int? {
        let slice = samples.indices.filter { $0 >= from && $0 <= to && samples[$0] > 0 }
        guard !slice.isEmpty else { return nil }
        let sum = slice.reduce(0) { $0 + samples[$1] }
        return sum / slice.count
    }

    /// Simple linear regression. Returns (slope, intercept, rSquared).
    private static func linearRegression(x: [Double], y: [Double]) -> (slope: Double, intercept: Double, rSquared: Double) {
        let n = Double(x.count)
        let sumX = x.reduce(0, +)
        let sumY = y.reduce(0, +)
        let sumXY = zip(x, y).reduce(0) { $0 + $1.0 * $1.1 }
        let sumX2 = x.reduce(0) { $0 + $1 * $1 }

        let denominator = n * sumX2 - sumX * sumX
        guard abs(denominator) > 1e-10 else { return (0, 0, 0) }

        let slope = (n * sumXY - sumX * sumY) / denominator
        let intercept = (sumY - slope * sumX) / n

        // R-squared
        let meanY = sumY / n
        let ssTotal = y.reduce(0) { $0 + ($1 - meanY) * ($1 - meanY) }
        let ssResidual = zip(x, y).reduce(0) { acc, pair in
            let predicted = slope * pair.0 + intercept
            return acc + (pair.1 - predicted) * (pair.1 - predicted)
        }
        let rSquared = ssTotal > 0 ? 1.0 - ssResidual / ssTotal : 0

        return (slope, intercept, rSquared)
    }
}
