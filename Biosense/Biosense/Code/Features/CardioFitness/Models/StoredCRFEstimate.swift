//
//  StoredCRFEstimate.swift
//  Biosense
//
//  Persisted cardio fitness estimate (one per day) and HR recovery data.
//

import Foundation
import SwiftData

// MARK: - CRF Estimate

@Model
final class StoredCRFEstimate {
    var date: Date
    /// Internal VO2max estimate in ml/kg/min. Never displayed to user as a raw number.
    var vo2maxEstimate: Double
    var restingBPM: Int
    /// Heart rate recovery at 60s (nil if no HRR data for this estimate).
    var hrr60: Int?
    /// 0 = low (suppressed), 1 = medium (Uth only), 2 = high (Uth + HRR)
    var confidence: Int
    /// "uth" or "uth+hrr"
    var source: String

    init(date: Date, vo2maxEstimate: Double, restingBPM: Int, hrr60: Int? = nil, confidence: Int, source: String) {
        self.date = Calendar.current.startOfDay(for: date)
        self.vo2maxEstimate = vo2maxEstimate
        self.restingBPM = restingBPM
        self.hrr60 = hrr60
        self.confidence = confidence
        self.source = source
    }
}

// MARK: - HR Recovery

@Model
final class StoredHRRecovery {
    /// Links to the StoredGymSession via its start time.
    var sessionStartTime: Date
    /// HR at the moment the workout was stopped.
    var peakWorkoutBPM: Int
    /// When recovery recording began.
    var recoveryStartTime: Date
    /// BPM values at 1-second intervals. Index = seconds since recoveryStartTime. 0 = missing.
    var samples: [Int]
    /// Actual recording duration (up to 180).
    var durationSeconds: Int

    init(sessionStartTime: Date, peakWorkoutBPM: Int, recoveryStartTime: Date, samples: [Int], durationSeconds: Int) {
        self.sessionStartTime = sessionStartTime
        self.peakWorkoutBPM = peakWorkoutBPM
        self.recoveryStartTime = recoveryStartTime
        self.samples = samples
        self.durationSeconds = durationSeconds
    }
}
