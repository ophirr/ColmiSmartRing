//
//  InfluxDBWriter.swift
//  Halo
//
//  Streams ring data to InfluxDB Cloud via HTTP line protocol.
//  Batches points and flushes after a short coalesce delay (~2 s) to fit
//  inside the ~10 s BLE background wakeup window iOS grants.
//

import Foundation
import UIKit

// MARK: - Configuration

struct InfluxDBConfig {
    let url: String
    let org: String
    let bucket: String
    let demoBucket: String
    let token: String

    /// Default config — reads from UserDefaults, falling back to Secrets.swift defaults.
    static var saved: InfluxDBConfig? {
        let defaults = UserDefaults.standard
        let token = defaults.string(forKey: "influxdb.token") ?? Secrets.influxDBToken
        guard !token.isEmpty else { return nil }
        return InfluxDBConfig(
            url: defaults.string(forKey: "influxdb.url") ?? Secrets.influxDBURL,
            org: defaults.string(forKey: "influxdb.org") ?? Secrets.influxDBOrg,
            bucket: defaults.string(forKey: "influxdb.bucket") ?? Secrets.influxDBBucket,
            demoBucket: Secrets.influxDBDemoBucket,
            token: token
        )
    }

    /// Persist config to UserDefaults.
    func save() {
        let defaults = UserDefaults.standard
        defaults.set(url, forKey: "influxdb.url")
        defaults.set(org, forKey: "influxdb.org")
        defaults.set(bucket, forKey: "influxdb.bucket")
        defaults.set(token, forKey: "influxdb.token")
    }

    func writeURL(demo: Bool) -> URL? {
        let b = demo ? demoBucket : bucket
        return URL(string: "\(url)/api/v2/write?org=\(org)&bucket=\(b)&precision=s")
    }
}

// MARK: - Activity Tags

enum ActivityTag: String, CaseIterable, Identifiable {
    case none       = "none"
    case resting    = "resting"
    case sleeping   = "sleeping"
    case meditating = "meditating"
    case exercising = "exercising"
    case running    = "running"
    case fun1       = "fun_1"
    case fun2       = "fun_2"
    case fun3       = "fun_3"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:       return "None"
        case .resting:    return "Resting"
        case .sleeping:   return "Sleeping"
        case .meditating: return "Meditating"
        case .exercising: return "Exercising"
        case .running:    return "Running"
        case .fun1:       return "Fun (1)"
        case .fun2:       return "Fun (2)"
        case .fun3:       return "Fun (3)"
        }
    }

    var icon: String {
        switch self {
        case .none:       return "tag.slash"
        case .resting:    return "figure.seated.seatbelt"
        case .sleeping:   return "moon.zzz"
        case .meditating: return "figure.mind.and.body"
        case .exercising: return "figure.strengthtraining.traditional"
        case .running:    return "figure.run"
        case .fun1:       return "sparkles"
        case .fun2:       return "star"
        case .fun3:       return "flame"
        }
    }

    /// Line protocol tag fragment — empty string when no tag is active.
    var lineProtocolSuffix: String {
        self == .none ? "" : ",activity=\(rawValue)"
    }
}

// MARK: - Writer

@MainActor
final class InfluxDBWriter {
    static let shared = InfluxDBWriter()

    private var config: InfluxDBConfig?
    private var buffer: [String] = []
    private let batchSize = 50
    /// Coalesce delay: after the first write, wait this long for more writes
    /// before flushing.  Short enough to fit inside the ~10 s BLE wakeup window
    /// iOS grants in background.
    private let coalesceInterval: TimeInterval = 2
    private var coalesceWorkItem: DispatchWorkItem?
    private var totalWritten: Int = 0
    private var totalErrors: Int = 0

    /// Current activity tag applied to all writes.
    var activeTag: ActivityTag = .none {
        didSet {
            UserDefaults.standard.set(activeTag.rawValue, forKey: "influxdb.activeTag")
            tLog("[InfluxDB] Tag changed → \(activeTag.displayName)")
        }
    }

    /// Whether the writer is configured and active.
    var isEnabled: Bool { config != nil }
    var demoMode = false
    var stats: String {
        let bucket = demoMode ? "demo" : "prod"
        return "[\(bucket)] Written: \(totalWritten) | Errors: \(totalErrors) | Buffered: \(buffer.count)"
    }

    private init() {}

    /// Load config from UserDefaults and start the flush timer.
    func start() {
        // Always start with no activity tag
        activeTag = .none
        config = InfluxDBConfig.saved
        guard config != nil else {
            tLog("[InfluxDB] No config found — cloud sync disabled. Set influxdb.token in UserDefaults.")
            return
        }
        tLog("[InfluxDB] Started — writing to \(config!.bucket)@\(config!.url)")
    }

    /// Configure and start with explicit values. Saves to UserDefaults.
    func configure(url: String, org: String, bucket: String, token: String) {
        let cfg = InfluxDBConfig(url: url, org: org, bucket: bucket, demoBucket: Secrets.influxDBDemoBucket, token: token)
        cfg.save()
        config = cfg
        tLog("[InfluxDB] Configured — writing to \(bucket)@\(url)")
    }

    func stop() {
        coalesceWorkItem?.cancel()
        coalesceWorkItem = nil
        flush()
        config = nil
        tLog("[InfluxDB] Stopped")
    }

    // MARK: - Write points

    /// Enqueue a single line-protocol string.
    /// Flushes immediately at batchSize, otherwise after a short coalesce delay
    /// so that background BLE wakeups don't miss the flush window.
    func write(_ lineProtocol: String) {
        guard config != nil else {
            tLog("[InfluxDB] ⚠️ write() skipped — no config (not started)")
            return
        }
        buffer.append(lineProtocol)
        if buffer.count >= batchSize {
            flush()
        } else {
            scheduleCoalesceFlush()
        }
    }

    /// Enqueue multiple line-protocol strings.
    func write(_ lines: [String]) {
        guard config != nil else {
            tLog("[InfluxDB] ⚠️ write(\(lines.count)) skipped — no config (not started)")
            return
        }
        buffer.append(contentsOf: lines)
        if buffer.count >= batchSize {
            flush()
        } else {
            scheduleCoalesceFlush()
        }
    }

    // MARK: - Convenience writers for ring data types

    /// Tag fragment for line protocol, e.g. ",activity=meditating"
    private var tag: String { activeTag.lineProtocolSuffix }

    func writeHeartRates(_ readings: [(bpm: Int, time: Date)]) {
        let lines = readings.map { reading in
            "heart_rate,source=colmi_r02\(tag) bpm=\(reading.bpm)i \(epochSeconds(reading.time))"
        }
        write(lines)
    }

    func writeHRV(value: Double, time: Date) {
        write("hrv,source=colmi_r02\(tag) ms=\(value) \(epochSeconds(time))")
    }

    func writeStress(value: Double, time: Date) {
        write("stress,source=colmi_r02\(tag) level=\(value) \(epochSeconds(time))")
    }

    func writeSpO2(value: Double, time: Date) {
        write("spo2,source=colmi_r02\(tag) percent=\(value) \(epochSeconds(time))")
    }

    func writeTemperature(celsius: Double, time: Date) {
        let rounded = (celsius * 10).rounded() / 10  // one decimal place
        write("body_temp,source=colmi_r02\(tag) celsius=\(rounded) \(epochSeconds(time))")
    }

    func writeActivity(steps: Int, calories: Int, distanceKm: Double, time: Date) {
        write("activity,source=colmi_r02\(tag) steps=\(steps)i,calories=\(calories)i,distance_km=\(distanceKm) \(epochSeconds(time))")
    }

    func writeSleep(stage: String, durationMinutes: Int, time: Date) {
        write("sleep,source=colmi_r02\(tag),stage=\(stage) duration_min=\(durationMinutes)i \(epochSeconds(time))")
    }

    func writeGymHR(bpm: Int, sessionID: String, time: Date) {
        write("gym_hr,source=colmi_r02\(tag),session_id=\(sessionID) bpm=\(bpm)i \(epochSeconds(time))")
    }

    func writeBattery(level: Int, charging: Bool, time: Date) {
        write("battery,source=colmi_r02\(tag) level=\(level)i,charging=\(charging ? "true" : "false") \(epochSeconds(time))")
    }

    // MARK: - Flush

    func flush() {
        coalesceWorkItem?.cancel()
        coalesceWorkItem = nil
        guard let config, !buffer.isEmpty else { return }
        guard let url = config.writeURL(demo: demoMode) else {
            tLog("[InfluxDB] Invalid write URL")
            return
        }

        let body = buffer.joined(separator: "\n")
        let count = buffer.count
        let measurements = Set(buffer.compactMap { $0.components(separatedBy: ",").first })
        tLog("[InfluxDB] Flushing \(count) points (\(measurements.sorted().joined(separator: ", "))) to \(demoMode ? "demo" : "prod")")
        buffer.removeAll(keepingCapacity: true)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)

        // Request background execution time so iOS doesn't suspend us mid-POST.
        var bgTaskID = UIBackgroundTaskIdentifier.invalid
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "InfluxDB Flush") {
            // Expiration handler — if iOS reclaims the time, just end the task.
            UIApplication.shared.endBackgroundTask(bgTaskID)
            bgTaskID = .invalid
        }

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error {
                    self?.totalErrors += count
                    tLog("[InfluxDB] Write failed (\(count) points): \(error.localizedDescription)")
                } else if let http = response as? HTTPURLResponse {
                    if http.statusCode == 204 {
                        self?.totalWritten += count
                        tLog("[InfluxDB] Wrote \(count) points (total: \(self?.totalWritten ?? 0))")
                    } else {
                        self?.totalErrors += count
                        let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "no body"
                        tLog("[InfluxDB] Write error HTTP \(http.statusCode): \(body)")
                    }
                }
                // Release the background task assertion.
                if bgTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskID)
                    bgTaskID = .invalid
                }
            }
        }
        task.resume()
    }

    // MARK: - Helpers

    private func epochSeconds(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970)
    }

    /// Schedule a flush after a short coalesce delay.  If a flush is already
    /// scheduled, this is a no-op — the pending flush will pick up the new
    /// points.  The 2 s delay lets multiple writes from a single BLE sync
    /// batch together while still fitting inside the ~10 s background window.
    private func scheduleCoalesceFlush() {
        guard coalesceWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.coalesceWorkItem = nil
            self?.flush()
        }
        coalesceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + coalesceInterval, execute: item)
    }
}
