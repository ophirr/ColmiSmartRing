//
//  KalmanReplayTests.swift
//  BiosenseTests
//
//  Replay harness: feeds the 3/30/2026 workout telemetry through KalmanHRFilter
//  and compares output against 21-point OTF chest-strap ground truth.
//

import Testing
import Foundation
@testable import Biosense

// MARK: - Ground Truth Dataset

private struct GroundTruthPoint {
    let utcTime: String       // HH:MM:SS UTC
    let otfHR: Int            // OTF chest strap BPM
    let spm: Int              // cadence from screenshot
}

/// 21 ground truth points from 3/30/2026 OTF workout.
private let groundTruth: [GroundTruthPoint] = [
    .init(utcTime: "11:28:52", otfHR:  79, spm:  59),
    .init(utcTime: "11:30:07", otfHR:  91, spm:  59),
    .init(utcTime: "11:34:12", otfHR: 119, spm: 115),
    .init(utcTime: "11:35:54", otfHR: 138, spm: 119),
    .init(utcTime: "11:37:40", otfHR: 104, spm: 117),
    .init(utcTime: "11:39:36", otfHR: 137, spm: 116),
    .init(utcTime: "11:39:54", otfHR: 140, spm: 118),
    .init(utcTime: "11:40:39", otfHR: 146, spm: 171),
    .init(utcTime: "11:40:56", otfHR: 138, spm:  59),
    .init(utcTime: "11:41:41", otfHR: 126, spm:  59),
    .init(utcTime: "11:43:27", otfHR: 112, spm: 172),
    .init(utcTime: "11:44:24", otfHR: 134, spm: 118),
    .init(utcTime: "11:45:18", otfHR: 140, spm: 119),
    .init(utcTime: "11:45:47", otfHR: 134, spm: 117),
    .init(utcTime: "11:46:46", otfHR: 115, spm: 116),
    .init(utcTime: "11:47:25", otfHR: 106, spm:  58),
    .init(utcTime: "11:49:16", otfHR: 136, spm: 118),
    .init(utcTime: "11:50:29", otfHR: 143, spm: 117),
    .init(utcTime: "11:50:50", otfHR: 138, spm: 119),
    .init(utcTime: "11:51:33", otfHR: 124, spm: 119),
    .init(utcTime: "11:54:29", otfHR: 106, spm:  59),
]

// MARK: - CSV Tick Data

private struct WorkoutTick {
    let timestamp: Date
    let rawBPM: Int
    let steps: Int
    let cadenceSPM: Int
}

private func loadWorkoutTicks() -> [WorkoutTick] {
    let csvPath = "/Users/ophir/Claude/src/ColmiSmartRing/Biosense/3-30-2026/workout-ticks-pivoted.csv"
    guard let content = try? String(contentsOfFile: csvPath, encoding: .utf8) else { return [] }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]

    var ticks: [WorkoutTick] = []
    for line in content.components(separatedBy: "\n").dropFirst() {
        let cols = line.components(separatedBy: ",")
        guard cols.count >= 5, let date = formatter.date(from: cols[0]) else { continue }
        ticks.append(WorkoutTick(
            timestamp: date,
            rawBPM: Int(Double(cols[1]) ?? 0),
            steps: Int(Double(cols[4]) ?? 0),
            cadenceSPM: Int(Double(cols[3]) ?? 0)
        ))
    }
    return ticks
}

// MARK: - Replay Engine

private struct ReplayMetrics {
    let mae: Double
    let rmse: Double
    let bias: Double
    let overread15: Int
    let underread15: Int
    let within5: Int
    let within10: Int
    let matched: Int
}

private func replayAndEvaluate(filter: KalmanHRFilter, ticks: [WorkoutTick]) -> ReplayMetrics {
    // Run all ticks, record outputs by HH:MM:SS
    var outputs: [String: Int] = [:]
    let cal = Calendar(identifier: .gregorian)
    let utc = TimeZone(identifier: "UTC")!

    for tick in ticks {
        if let r = filter.process(rawBPM: tick.rawBPM, cumulativeSteps: tick.steps,
                                   source: .phoneSport0x78, packetAge: 0.5, timestamp: tick.timestamp) {
            let c = cal.dateComponents(in: utc, from: tick.timestamp)
            let key = String(format: "%02d:%02d:%02d", c.hour!, c.minute!, c.second!)
            outputs[key] = r.bpm
        }
    }

    // Match ground truth to outputs
    var ae = 0.0, se = 0.0, bias = 0.0
    var over15 = 0, under15 = 0, w5 = 0, w10 = 0, matched = 0

    for gt in groundTruth {
        var bpm: Int?
        let parts = gt.utcTime.split(separator: ":")
        let baseSec = Int(parts[2])!
        for offset in 0...3 {
            for d in [offset, -offset] {
                let s = baseSec + d
                guard s >= 0, s < 60 else { continue }
                let key = String(format: "%s:%s:%02d", String(parts[0]), String(parts[1]), s)
                if let b = outputs[key] { bpm = b; break }
            }
            if bpm != nil { break }
        }
        guard let filtBPM = bpm else { continue }
        matched += 1
        let delta = filtBPM - gt.otfHR
        ae += abs(Double(delta))
        se += Double(delta * delta)
        bias += Double(delta)
        if delta > 15 { over15 += 1 }
        if delta < -15 { under15 += 1 }
        if abs(delta) <= 5 { w5 += 1 }
        if abs(delta) <= 10 { w10 += 1 }
    }

    let n = Double(matched)
    return ReplayMetrics(mae: ae/n, rmse: sqrt(se/n), bias: bias/n,
                         overread15: over15, underread15: under15,
                         within5: w5, within10: w10, matched: matched)
}

// MARK: - Tests

struct KalmanReplayTests {

    @Test("Replay harness loads workout ticks from pivoted CSV")
    func loadTicks() {
        let ticks = loadWorkoutTicks()
        #expect(ticks.count > 1500)
        #expect(ticks.count < 1700)
    }

    @Test("KalmanHRFilter replay against 3/30 ground truth")
    func replayAgainstGroundTruth() {
        let ticks = loadWorkoutTicks()
        #expect(!ticks.isEmpty)

        let filter = KalmanHRFilter()
        let m = replayAndEvaluate(filter: filter, ticks: ticks)

        #expect(m.matched == 21, "Expected 21 ground truth matches, got \(m.matched)")

        // Phase 1 targets (pre-Phase 1 baseline was MAE=15.1, overread=9/21)
        #expect(m.mae < 13.0, "MAE=\(m.mae) should be < 13 (baseline was 15.1)")
        #expect(m.overread15 <= 6, "Overreads=\(m.overread15) should be <= 6 (baseline was 9)")

        // Regression guards — don't make walking accuracy worse
        #expect(m.underread15 <= 3, "Under-reads=\(m.underread15) should be <= 3")
    }
}
