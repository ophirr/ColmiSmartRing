//
//  WorkoutInfluxImporter.swift
//  Biosense
//
//  One-time import of missing workout sessions from InfluxDB into SwiftData.
//  Workouts between March 30 and the fix date (April 5) were recorded to
//  InfluxDB but not saved to SwiftData due to a UI bug where the save
//  dialog never appeared.
//

import Foundation
import SwiftData

@MainActor
enum WorkoutInfluxImporter {

    /// Import missing workouts from InfluxDB. Checks existing StoredGymSession
    /// dates and only imports sessions that don't already exist.
    static func importMissingSessions(context: ModelContext) async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: AppSettings.CloudSync.enabled) else {
            tLog("[WorkoutImport] InfluxDB not enabled, skipping")
            return
        }
        guard !defaults.bool(forKey: "workoutImportCompleted") else {
            tLog("[WorkoutImport] Already completed, skipping")
            return
        }

        tLog("[WorkoutImport] Checking for missing workouts in InfluxDB...")

        // Get existing session start times to avoid duplicates
        let existingDescriptor = FetchDescriptor<StoredGymSession>()
        let existing = (try? context.fetch(existingDescriptor)) ?? []
        let existingDates = Set(existing.map { Calendar.current.startOfDay(for: $0.startTime) })
        tLog("[WorkoutImport] Found \(existing.count) existing sessions")

        // Query InfluxDB for workout sessions since March 30
        guard let sessions = await fetchWorkoutSessions() else {
            tLog("[WorkoutImport] Failed to fetch from InfluxDB")
            return
        }

        var imported = 0
        let zoneConfig = HRZoneConfig.default

        for session in sessions {
            let sessionDay = Calendar.current.startOfDay(for: session.startTime)
            if existingDates.contains(sessionDay) {
                tLog("[WorkoutImport] Skipping \(session.sessionID) — already exists")
                continue
            }

            // Build StoredGymSession from InfluxDB data
            let samples = session.ticks.compactMap { tick -> GymHRSample? in
                guard tick.bpm > 0 else { return nil }
                return GymHRSample(
                    timestamp: tick.time,
                    bpm: tick.bpm,
                    cadenceFiltered: tick.cadenceFiltered
                )
            }

            let validBPMs = session.ticks.map(\.bpm).filter { $0 > 0 }
            let avgBPM = validBPMs.isEmpty ? 0 : validBPMs.reduce(0, +) / validBPMs.count
            let peakBPM = validBPMs.max() ?? 0

            // Compute zone times from per-tick data (1 tick ≈ 1 second)
            var zoneSeconds = Array(repeating: 0.0, count: 6)
            for tick in session.ticks where tick.bpm > 0 {
                let zone = zoneConfig.zone(for: tick.bpm)
                zoneSeconds[zone.rawValue] += 1.0
            }

            let lastSteps = session.ticks.last(where: { $0.steps > 0 })?.steps
            let lastDistance = session.ticks.last(where: { $0.distanceM > 0 })?.distanceM

            let stored = StoredGymSession(
                startTime: session.startTime,
                endTime: session.endTime,
                durationSeconds: session.endTime.timeIntervalSince(session.startTime),
                maxHR: zoneConfig.maxHR,
                avgBPM: avgBPM,
                peakBPM: peakBPM,
                sportRTSteps: lastSteps,
                sportDistanceM: lastDistance,
                zoneTimeSeconds: zoneSeconds,
                samples: samples
            )

            context.insert(stored)
            imported += 1
            tLog("[WorkoutImport] Imported \(session.sessionID): \(samples.count) samples, avg \(avgBPM) bpm, peak \(peakBPM)")
        }

        if imported > 0 {
            try? context.save()
            tLog("[WorkoutImport] Saved \(imported) imported workouts")
        } else {
            tLog("[WorkoutImport] No missing workouts to import")
        }

        defaults.set(true, forKey: "workoutImportCompleted")
    }

    // MARK: - InfluxDB Query

    private struct WorkoutSession {
        let sessionID: String
        let startTime: Date
        let endTime: Date
        let ticks: [WorkoutTick]
    }

    private struct WorkoutTick {
        let time: Date
        let bpm: Int
        let rawBPM: Int
        let steps: Int
        let distanceM: Int
        let cadenceFiltered: Bool
    }

    private static func fetchWorkoutSessions() async -> [WorkoutSession]? {
        let url = UserDefaults.standard.string(forKey: AppSettings.InfluxDB.url)
            ?? "https://us-east-1-1.aws.cloud2.influxdata.com"
        let org = UserDefaults.standard.string(forKey: AppSettings.InfluxDB.org) ?? "FunCo"
        guard let token = KeychainHelper.read(service: "com.biosense.ring.influxdb", account: "token") else {
            tLog("[WorkoutImport] No InfluxDB token")
            return nil
        }

        let bucket = UserDefaults.standard.string(forKey: AppSettings.InfluxDB.bucket) ?? "ringie-prod"

        // Query all workout ticks since March 30
        let flux = """
        from(bucket: "\(bucket)")
          |> range(start: 2026-03-30T00:00:00Z)
          |> filter(fn: (r) => r._measurement == "workout")
          |> filter(fn: (r) => r._field == "bpm" or r._field == "raw_bpm" or r._field == "steps" or r._field == "distance_m" or r._field == "cadence_filtered")
          |> pivot(rowKey: ["_time"], columnKey: ["_field"], valueColumn: "_value")
          |> group(columns: ["session_id"])
          |> sort(columns: ["_time"])
          |> yield(name: "workouts")
        """

        let queryURL = URL(string: "\(url)/api/v2/query?org=\(org)")!
        var request = URLRequest(url: queryURL)
        request.httpMethod = "POST"
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.flux", forHTTPHeaderField: "Content-Type")
        request.setValue("application/csv", forHTTPHeaderField: "Accept")
        request.httpBody = flux.data(using: .utf8)
        request.timeoutInterval = 60

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let csv = String(data: data, encoding: .utf8) else {
            tLog("[WorkoutImport] InfluxDB query failed")
            return nil
        }

        return parseWorkoutCSV(csv)
    }

    private static func parseWorkoutCSV(_ csv: String) -> [WorkoutSession] {
        var sessionMap: [String: [WorkoutTick]] = [:]

        // InfluxDB annotated CSV: split by double newline into tables
        let tables = csv.components(separatedBy: "\r\n\r\n")
        for table in tables {
            let lines = table.components(separatedBy: "\r\n")
            let dataLines = lines.filter { !$0.isEmpty && !$0.hasPrefix("#") }
            guard dataLines.count >= 2 else { continue }

            // Parse header
            let header = dataLines[0].components(separatedBy: ",")
            let timeIdx = header.firstIndex(of: "_time")
            let bpmIdx = header.firstIndex(of: "bpm")
            let rawBpmIdx = header.firstIndex(of: "raw_bpm")
            let stepsIdx = header.firstIndex(of: "steps")
            let distIdx = header.firstIndex(of: "distance_m")
            let filtIdx = header.firstIndex(of: "cadence_filtered")
            let sidIdx = header.firstIndex(of: "session_id")

            guard let ti = timeIdx, let si = sidIdx else { continue }

            for line in dataLines.dropFirst() {
                let cols = line.components(separatedBy: ",")
                guard cols.count > max(ti, si) else { continue }

                let timeStr = cols[ti]
                let sessionID = cols[si]
                guard !sessionID.isEmpty, sessionID != "session_id" else { continue }

                guard let time = ISO8601DateFormatter().date(from: timeStr) else { continue }

                let bpm = bpmIdx.flatMap { Int(cols[$0]) } ?? 0
                let rawBpm = rawBpmIdx.flatMap { Int(cols[$0]) } ?? 0
                let steps = stepsIdx.flatMap { Int(cols[$0]) } ?? 0
                let dist = distIdx.flatMap { Int(cols[$0]) } ?? 0
                let filt = filtIdx.map { cols[$0] == "true" } ?? false

                let tick = WorkoutTick(time: time, bpm: bpm, rawBPM: rawBpm, steps: steps, distanceM: dist, cadenceFiltered: filt)
                sessionMap[sessionID, default: []].append(tick)
            }
        }

        // Convert to WorkoutSession array
        return sessionMap.compactMap { sessionID, ticks in
            let sorted = ticks.sorted { $0.time < $1.time }
            guard let first = sorted.first, let last = sorted.last else { return nil }
            // Skip sessions with < 60 seconds of data (partial/aborted)
            guard last.time.timeIntervalSince(first.time) >= 60 else { return nil }
            return WorkoutSession(sessionID: sessionID, startTime: first.time, endTime: last.time, ticks: sorted)
        }.sorted { $0.startTime < $1.startTime }
    }
}

