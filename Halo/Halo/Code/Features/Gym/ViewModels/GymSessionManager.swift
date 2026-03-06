//
//  GymSessionManager.swift
//  Halo
//
//  Manages a live gym workout session. Wraps RingSessionManager's real-time HR
//  stream with session state, timing, zone tracking, HR history, and haptics.
//

import Foundation
import SwiftUI
import UIKit

/// In-memory HR sample during a live workout.
struct LiveHRSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let bpm: Int
    let zone: HRZone
}

enum GymWorkoutState {
    case idle
    case active
    case paused
    case finished
}

@Observable
@MainActor
class GymSessionManager {
    // MARK: - Public state

    var workoutState: GymWorkoutState = .idle
    var currentBPM: Int = 0
    var currentZone: HRZone = .rest
    var elapsedSeconds: Double = 0
    var samples: [LiveHRSample] = []
    var peakBPM: Int = 0

    /// Zone time accumulators (seconds). Indexed by HRZone rawValue.
    var zoneTimeSeconds: [Double] = Array(repeating: 0, count: 6)

    /// Zone config — persisted in UserDefaults.
    var zoneConfig: HRZoneConfig {
        didSet {
            if let data = try? JSONEncoder().encode(zoneConfig) {
                UserDefaults.standard.set(data, forKey: Self.zoneConfigKey)
            }
        }
    }

    /// Which finger the ring is worn on — persisted in UserDefaults.
    var ringFinger: RingFinger {
        didSet {
            UserDefaults.standard.set(ringFinger.rawValue, forKey: Self.ringFingerKey)
        }
    }

    /// Whether haptic feedback fires on zone changes.
    var hapticsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(hapticsEnabled, forKey: Self.hapticsKey)
        }
    }

    /// True when the ring is connected and streaming HR data.
    var isReceivingData: Bool { currentBPM > 0 }

    // MARK: - Private

    private static let zoneConfigKey = "gymZoneConfig"
    private static let ringFingerKey = "gymRingFinger"
    private static let hapticsKey = "gymHapticsEnabled"
    private static let hrPollInterval: TimeInterval = 1.0
    private static let continueInterval: TimeInterval = 4.0

    private weak var ringManager: RingSessionManager?
    private var timerTask: Task<Void, Never>?
    private var continueTask: Task<Void, Never>?
    private var workoutStartTime: Date?
    private var pauseAccumulated: TimeInterval = 0
    private var lastPauseStart: Date?
    private var lastSampleTime: Date?
    private var lastZoneTickTime: Date?

    // Haptics
    private let hapticEngine = UIImpactFeedbackGenerator(style: .heavy)
    private let hapticLight = UIImpactFeedbackGenerator(style: .light)
    private let hapticNotification = UINotificationFeedbackGenerator()
    private var previousZone: HRZone = .rest

    init(ringManager: RingSessionManager) {
        self.ringManager = ringManager

        // Load persisted zone config
        if let data = UserDefaults.standard.data(forKey: Self.zoneConfigKey),
           let config = try? JSONDecoder().decode(HRZoneConfig.self, from: data) {
            self.zoneConfig = config
        } else {
            self.zoneConfig = .default
        }

        // Load persisted finger
        if let raw = UserDefaults.standard.string(forKey: Self.ringFingerKey),
           let finger = RingFinger(rawValue: raw) {
            self.ringFinger = finger
        } else {
            self.ringFinger = .index
        }

        // Load haptics preference
        if UserDefaults.standard.object(forKey: Self.hapticsKey) != nil {
            self.hapticsEnabled = UserDefaults.standard.bool(forKey: Self.hapticsKey)
        } else {
            self.hapticsEnabled = true
        }

        // Pre-warm haptic engines
        hapticEngine.prepare()
        hapticLight.prepare()
    }

    // MARK: - Workout lifecycle

    func startWorkout() {
        guard workoutState == .idle || workoutState == .finished else { return }
        resetState()
        workoutState = .active
        workoutStartTime = Date()
        lastZoneTickTime = Date()
        previousZone = .rest

        // Start real-time HR streaming from ring (skip in demo mode)
        if ringManager?.demoModeActive != true {
            ringManager?.startRealTimeStreaming(type: .heartRate)
        }

        // Start timer loop
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.hrPollInterval * 1_000_000_000))
                guard let self, !Task.isCancelled else { break }
                self.tick()
            }
        }

        // Send "continue" commands to keep the ring streaming
        continueTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.continueInterval * 1_000_000_000))
                guard let self, !Task.isCancelled else { break }
                if self.workoutState == .active && self.ringManager?.demoModeActive != true {
                    self.ringManager?.continueRealTimeStreaming(type: .heartRate)
                }
            }
        }

        // Start haptic
        if hapticsEnabled {
            hapticNotification.notificationOccurred(.success)
        }
    }

    func pauseWorkout() {
        guard workoutState == .active else { return }
        workoutState = .paused
        lastPauseStart = Date()
        if ringManager?.demoModeActive != true {
            ringManager?.stopRealTimeStreaming(type: .heartRate)
        }
        continueTask?.cancel()

        if hapticsEnabled {
            hapticLight.impactOccurred()
        }
    }

    func resumeWorkout() {
        guard workoutState == .paused else { return }
        if let pauseStart = lastPauseStart {
            pauseAccumulated += Date().timeIntervalSince(pauseStart)
        }
        lastPauseStart = nil
        workoutState = .active
        lastZoneTickTime = Date()

        if ringManager?.demoModeActive != true {
            ringManager?.startRealTimeStreaming(type: .heartRate)
        }

        continueTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.continueInterval * 1_000_000_000))
                guard let self, !Task.isCancelled else { break }
                if self.workoutState == .active && self.ringManager?.demoModeActive != true {
                    self.ringManager?.continueRealTimeStreaming(type: .heartRate)
                }
            }
        }

        if hapticsEnabled {
            hapticLight.impactOccurred()
        }
    }

    func stopWorkout() -> CompletedWorkout? {
        guard workoutState == .active || workoutState == .paused else { return nil }

        if ringManager?.demoModeActive != true {
            ringManager?.stopRealTimeStreaming(type: .heartRate)
        }
        timerTask?.cancel()
        continueTask?.cancel()
        timerTask = nil
        continueTask = nil
        workoutState = .finished

        if hapticsEnabled {
            hapticNotification.notificationOccurred(.warning)
        }

        guard let start = workoutStartTime else { return nil }
        let end = Date()

        let validSamples = samples.filter { $0.bpm > 0 }
        let avgBPM = validSamples.isEmpty ? 0 : validSamples.reduce(0) { $0 + $1.bpm } / validSamples.count

        return CompletedWorkout(
            startTime: start,
            endTime: end,
            durationSeconds: elapsedSeconds,
            maxHR: zoneConfig.maxHR,
            avgBPM: avgBPM,
            peakBPM: peakBPM,
            zoneTimeSeconds: zoneTimeSeconds,
            samples: samples
        )
    }

    func resetToIdle() {
        timerTask?.cancel()
        continueTask?.cancel()
        timerTask = nil
        continueTask = nil
        workoutState = .idle
    }

    // MARK: - Timer tick

    private func tick() {
        guard workoutState == .active, let start = workoutStartTime else { return }
        elapsedSeconds = Date().timeIntervalSince(start) - pauseAccumulated

        // Read latest HR from ring manager
        if let bpm = ringManager?.realTimeHeartRateBPM, bpm > 0 {
            currentBPM = bpm
            let newZone = zoneConfig.zone(for: bpm)

            // Zone transition haptic
            if newZone != previousZone && hapticsEnabled {
                fireZoneHaptic(from: previousZone, to: newZone)
            }

            currentZone = newZone
            previousZone = newZone

            if bpm > peakBPM { peakBPM = bpm }

            // Record sample (~1 per second)
            let now = Date()
            if lastSampleTime == nil || now.timeIntervalSince(lastSampleTime!) >= 0.9 {
                let sample = LiveHRSample(timestamp: now, bpm: bpm, zone: currentZone)
                samples.append(sample)
                lastSampleTime = now
            }

            // Accumulate zone time
            if let lastTick = lastZoneTickTime {
                let delta = now.timeIntervalSince(lastTick)
                zoneTimeSeconds[currentZone.rawValue] += delta
            }
            lastZoneTickTime = now
        } else {
            // No reading yet — still accumulate time in current zone
            let now = Date()
            if let lastTick = lastZoneTickTime {
                let delta = now.timeIntervalSince(lastTick)
                zoneTimeSeconds[currentZone.rawValue] += delta
            }
            lastZoneTickTime = now
        }
    }

    // MARK: - Haptics

    private func fireZoneHaptic(from oldZone: HRZone, to newZone: HRZone) {
        let goingUp = newZone.rawValue > oldZone.rawValue

        if newZone == .zone5 {
            // Entering Zone 5 (All Out) — strong double tap
            hapticEngine.impactOccurred(intensity: 1.0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.hapticEngine.impactOccurred(intensity: 1.0)
            }
        } else if newZone == .zone4 && goingUp {
            // Entering Zone 4 (Hard) going up — strong single
            hapticEngine.impactOccurred(intensity: 0.9)
        } else if goingUp {
            // Moving up any other zone — medium tap
            hapticEngine.impactOccurred(intensity: newZone.hapticIntensity)
        } else {
            // Dropping down — gentle tap
            hapticLight.impactOccurred(intensity: 0.4)
        }

        // Re-prepare for next use
        hapticEngine.prepare()
        hapticLight.prepare()
    }

    // MARK: - Helpers

    var formattedElapsed: String {
        let total = Int(elapsedSeconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    var avgBPM: Int {
        let valid = samples.filter { $0.bpm > 0 }
        guard !valid.isEmpty else { return 0 }
        return valid.reduce(0) { $0 + $1.bpm } / valid.count
    }

    /// Last N samples for the sparkline.
    func recentSamples(count: Int = 60) -> [LiveHRSample] {
        Array(samples.suffix(count))
    }

    private func resetState() {
        currentBPM = 0
        currentZone = .rest
        elapsedSeconds = 0
        samples = []
        peakBPM = 0
        zoneTimeSeconds = Array(repeating: 0, count: 6)
        pauseAccumulated = 0
        lastPauseStart = nil
        workoutStartTime = nil
        lastSampleTime = nil
        lastZoneTickTime = nil
        previousZone = .rest
    }
}

/// Data transfer object for a completed workout, before SwiftData persistence.
struct CompletedWorkout {
    let startTime: Date
    let endTime: Date
    let durationSeconds: Double
    let maxHR: Int
    let avgBPM: Int
    let peakBPM: Int
    let zoneTimeSeconds: [Double]
    let samples: [LiveHRSample]

    func toStoredSession() -> StoredGymSession {
        let storedSamples = samples.map { GymHRSample(timestamp: $0.timestamp, bpm: $0.bpm) }
        return StoredGymSession(
            startTime: startTime,
            endTime: endTime,
            durationSeconds: durationSeconds,
            maxHR: maxHR,
            avgBPM: avgBPM,
            peakBPM: peakBPM,
            zoneTimeSeconds: zoneTimeSeconds,
            samples: storedSamples
        )
    }
}
