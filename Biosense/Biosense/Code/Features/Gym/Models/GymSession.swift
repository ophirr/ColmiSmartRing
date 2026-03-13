//
//  GymSession.swift
//  Biosense
//
//  SwiftData model for storing completed gym workout sessions.
//  Each session stores timestamped HR readings for post-workout analysis.
//

import Foundation
import SwiftData

/// A single heart rate sample recorded during a gym session.
@Model
final class GymHRSample {
    var timestamp: Date
    var bpm: Int

    var session: StoredGymSession?

    init(timestamp: Date, bpm: Int) {
        self.timestamp = timestamp
        self.bpm = bpm
    }
}

/// A completed gym workout session with all HR data.
@Model
final class StoredGymSession {
    /// When the workout started.
    var startTime: Date
    /// When the workout ended.
    var endTime: Date
    /// Total duration in seconds.
    var durationSeconds: Double
    /// Max HR configured at time of workout.
    var maxHR: Int
    /// Summary stats.
    var avgBPM: Int
    var peakBPM: Int
    /// Optional user-provided label (e.g. "Leg Day", "HIIT").
    var label: String?

    /// Time spent in each zone (seconds). Indexed by HRZone rawValue (0-5).
    var zoneTimeSeconds: [Double]

    @Relationship(deleteRule: .cascade, inverse: \GymHRSample.session)
    var samples: [GymHRSample] = []

    init(
        startTime: Date,
        endTime: Date,
        durationSeconds: Double,
        maxHR: Int,
        avgBPM: Int,
        peakBPM: Int,
        label: String? = nil,
        zoneTimeSeconds: [Double] = Array(repeating: 0, count: 6),
        samples: [GymHRSample] = []
    ) {
        self.startTime = startTime
        self.endTime = endTime
        self.durationSeconds = durationSeconds
        self.maxHR = maxHR
        self.avgBPM = avgBPM
        self.peakBPM = peakBPM
        self.label = label
        self.zoneTimeSeconds = zoneTimeSeconds
        self.samples = samples
        for s in samples {
            s.session = self
        }
    }

    /// Formatted duration string "MM:SS" or "H:MM:SS".
    var formattedDuration: String {
        let total = Int(durationSeconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
