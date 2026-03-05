//
//  InfluxDBWriter.swift
//  Halo
//
//  Streams ring data to InfluxDB Cloud via HTTP line protocol.
//  Batches points and flushes on a timer or when a threshold is reached.
//

import Foundation

// MARK: - Configuration

struct InfluxDBConfig {
    let url: String
    let org: String
    let bucket: String
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

    var writeURL: URL? {
        URL(string: "\(url)/api/v2/write?org=\(org)&bucket=\(bucket)&precision=s")
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
    private let flushInterval: TimeInterval = 30
    private var flushTimer: Timer?
    private var totalWritten: Int = 0
    private var totalErrors: Int = 0

    /// Current activity tag applied to all writes.
    var activeTag: ActivityTag = .none {
        didSet {
            UserDefaults.standard.set(activeTag.rawValue, forKey: "influxdb.activeTag")
            debugPrint("[InfluxDB] Tag changed → \(activeTag.displayName)")
        }
    }

    /// Whether the writer is configured and active.
    var isEnabled: Bool { config != nil }
    var stats: String { "Written: \(totalWritten) | Errors: \(totalErrors) | Buffered: \(buffer.count)" }

    private init() {}

    /// Load config from UserDefaults and start the flush timer.
    func start() {
        // Restore saved tag
        if let savedTag = UserDefaults.standard.string(forKey: "influxdb.activeTag"),
           let tag = ActivityTag(rawValue: savedTag) {
            activeTag = tag
        }
        config = InfluxDBConfig.saved
        guard config != nil else {
            debugPrint("[InfluxDB] No config found — cloud sync disabled. Set influxdb.token in UserDefaults.")
            return
        }
        debugPrint("[InfluxDB] Started — writing to \(config!.bucket)@\(config!.url)")
        startFlushTimer()
    }

    /// Configure and start with explicit values. Saves to UserDefaults.
    func configure(url: String, org: String, bucket: String, token: String) {
        let cfg = InfluxDBConfig(url: url, org: org, bucket: bucket, token: token)
        cfg.save()
        config = cfg
        debugPrint("[InfluxDB] Configured — writing to \(bucket)@\(url)")
        startFlushTimer()
    }

    func stop() {
        flushTimer?.invalidate()
        flushTimer = nil
        flush()
        config = nil
        debugPrint("[InfluxDB] Stopped")
    }

    // MARK: - Write points

    /// Enqueue a single line-protocol string. Auto-flushes at batchSize.
    func write(_ lineProtocol: String) {
        guard config != nil else { return }
        buffer.append(lineProtocol)
        if buffer.count >= batchSize {
            flush()
        }
    }

    /// Enqueue multiple line-protocol strings.
    func write(_ lines: [String]) {
        guard config != nil else { return }
        buffer.append(contentsOf: lines)
        if buffer.count >= batchSize {
            flush()
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
        guard let config, !buffer.isEmpty else { return }
        guard let url = config.writeURL else {
            debugPrint("[InfluxDB] Invalid write URL")
            return
        }

        let body = buffer.joined(separator: "\n")
        let count = buffer.count
        buffer.removeAll(keepingCapacity: true)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)

        // Fire-and-forget with error logging
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error {
                    self?.totalErrors += count
                    debugPrint("[InfluxDB] Write failed (\(count) points): \(error.localizedDescription)")
                    return
                }
                if let http = response as? HTTPURLResponse {
                    if http.statusCode == 204 {
                        self?.totalWritten += count
                        debugPrint("[InfluxDB] Wrote \(count) points (total: \(self?.totalWritten ?? 0))")
                    } else {
                        self?.totalErrors += count
                        let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "no body"
                        debugPrint("[InfluxDB] Write error HTTP \(http.statusCode): \(body)")
                    }
                }
            }
        }
        task.resume()
    }

    // MARK: - Helpers

    private func epochSeconds(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970)
    }

    private func startFlushTimer() {
        flushTimer?.invalidate()
        flushTimer = Timer.scheduledTimer(withTimeInterval: flushInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.flush()
            }
        }
    }
}
