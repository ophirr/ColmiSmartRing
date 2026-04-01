//
//  CardioFitnessEstimator.swift
//  Biosense
//
//  Combines resting HR (Uth formula) and heart rate recovery to produce
//  a cardio fitness trend estimate. Never exposes raw VO2max numbers to UI.
//

import Foundation

enum CardioFitnessTrend: String {
    case improving
    case stable
    case declining
    case insufficientData
}

enum CRFConfidence: Int {
    case low = 0       // Suppress display
    case medium = 1    // Uth only
    case high = 2      // Uth + HRR
}

struct CRFEstimate {
    let vo2max: Double            // Internal, never shown to user
    let restingBPM: Int
    let hrr60: Int?
    let confidence: CRFConfidence
    let source: String            // "uth" or "uth+hrr"
    let trend: CardioFitnessTrend
    let dataPointCount: Int       // How many days of data inform this estimate
}

struct CardioFitnessEstimator {

    /// Trend threshold in ml/kg/min — changes smaller than this are "stable".
    private static let trendThreshold = 1.0

    /// Produce a CRF estimate from available data.
    /// - Parameters:
    ///   - profile: User profile (must be complete for HRmax)
    ///   - restingHR: 7-day median resting HR result (nil if insufficient sleep data)
    ///   - hrrResults: Recent HRR analyses (from last 14 days)
    ///   - previousEstimates: Historical estimates for trend computation
    static func estimate(
        profile: UserProfile,
        restingHR: RestingHRResult?,
        hrrResults: [HRRecoveryResult],
        previousEstimates: [StoredCRFEstimate]
    ) -> CRFEstimate? {
        guard profile.isComplete, let rhr = restingHR else { return nil }

        let hrMax = Double(profile.predictedHRmax)
        let hrRest = Double(rhr.restingBPM)

        guard hrRest > 30 && hrRest < hrMax else { return nil }

        // Uth formula baseline: VO2max = 15.3 * (HRmax / HRrest)
        let uthEstimate = 15.3 * (hrMax / hrRest)

        // HRR adjustment (if available)
        let goodHRR = hrrResults.filter { $0.quality != .poor }
        let vo2max: Double
        let source: String
        let confidence: CRFConfidence

        if let avgHRR60 = goodHRR.isEmpty ? nil : Double(goodHRR.reduce(0) { $0 + $1.hrr60 }) / Double(goodHRR.count) {
            // HRR-adjusted estimate: HRR60 of ~30 is average fitness.
            // Each +5 HRR60 above 30 adds ~1 ml/kg/min; each -5 below 30 subtracts ~1.
            let hrrAdjustment = (avgHRR60 - 30.0) / 5.0
            vo2max = uthEstimate + hrrAdjustment
            source = "uth+hrr"
            confidence = .high
        } else {
            vo2max = uthEstimate
            source = "uth"
            confidence = .medium
        }

        // Trend: compare current week vs previous week
        let trend = computeTrend(currentEstimate: vo2max, previousEstimates: previousEstimates)

        return CRFEstimate(
            vo2max: vo2max,
            restingBPM: rhr.restingBPM,
            hrr60: goodHRR.isEmpty ? nil : goodHRR.reduce(0) { $0 + $1.hrr60 } / goodHRR.count,
            confidence: confidence,
            source: source,
            trend: trend,
            dataPointCount: previousEstimates.count + 1
        )
    }

    /// Compare current estimate against the rolling average from the previous 7 days.
    private static func computeTrend(currentEstimate: Double, previousEstimates: [StoredCRFEstimate]) -> CardioFitnessTrend {
        let calendar = Calendar.current
        let now = Date()

        // Get estimates from 7-14 days ago for comparison
        let previousWeek = previousEstimates.filter { est in
            guard let daysAgo = calendar.dateComponents([.day], from: est.date, to: now).day else { return false }
            return daysAgo >= 7 && daysAgo < 14 && est.confidence >= 1
        }

        guard !previousWeek.isEmpty else { return .insufficientData }

        let previousAvg = previousWeek.reduce(0.0) { $0 + $1.vo2maxEstimate } / Double(previousWeek.count)
        let delta = currentEstimate - previousAvg

        if delta > trendThreshold {
            return .improving
        } else if delta < -trendThreshold {
            return .declining
        } else {
            return .stable
        }
    }
}
