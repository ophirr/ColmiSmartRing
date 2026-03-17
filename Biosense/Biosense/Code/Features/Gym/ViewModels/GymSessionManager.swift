//
//  GymSessionManager.swift
//  Biosense
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

    private static let zoneConfigKey = AppSettings.Gym.zoneConfig
    private static let ringFingerKey = AppSettings.Gym.ringFinger
    private static let hapticsKey = AppSettings.Gym.hapticsEnabled
    private static let hrPollInterval: TimeInterval = 1.0

    /// Aggressive watchdog: the ring's firmware silently stops 0x69 packets
    /// after a brief measurement (~5 s of valid HR) without sending CMD_STOP.
    /// When the stream was recently active (packets flowing ≤ 5 s ago), we
    /// detect silence quickly (streamSilenceThreshold = 8 s).  After a
    /// restart we allow a longer grace period (streamColdStartThreshold = 40 s)
    /// for the PPG warmup cycle before deciding the stream died again.
    private static let streamSilenceThreshold: TimeInterval = 8.0
    private static let streamColdStartThreshold: TimeInterval = 40.0

    private weak var ringManager: RingSessionManager?
    private var timerTask: Task<Void, Never>?
    private var continueTask: Task<Void, Never>?
    private var workoutStartTime: Date?
    private var pauseAccumulated: TimeInterval = 0
    private var lastPauseStart: Date?
    private var lastSampleTime: Date?
    private var lastZoneTickTime: Date?

    /// Tracks whether we already sent a watchdog restart for the current silence.
    /// Reset when fresh HR packets arrive.
    private var watchdogFired = false
    /// When the last watchdog restart was issued.  Used to apply the longer
    /// cold-start threshold immediately after a restart (PPG warmup takes ~25-33 s).
    private var lastWatchdogRestartTime: Date?

    /// When the last command-30 continue keepalive was sent.
    private var lastContinueKeepAliveTime: Date?
    /// How often to send a command-30 continue to keep the PPG sensor alive.
    private static let continueKeepAliveInterval: TimeInterval = 15.0

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
        // Cancel any orphaned tasks from a previous session before resetting.
        timerTask?.cancel()
        continueTask?.cancel()
        resetState()
        workoutState = .active
        workoutStartTime = Date()
        lastZoneTickTime = Date()
        previousZone = .rest

        // Tag all data as exercising during workout
        InfluxDBWriter.shared.activeTag = .exercising

        // Clear stale HR so the warmup indicator shows until the ring locks on fresh data.
        ringManager?.realTimeHeartRateBPM = nil

        // Tell RingSessionManager to enter workout mode — this transitions the
        // sensor state, stops any active spot-check/stream, and starts the
        // real-time HR stream for the workout.
        ringManager?.enterWorkoutMode()

        // Start timer loop
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.hrPollInterval * 1_000_000_000))
                guard let self, !Task.isCancelled else { break }
                self.tick()
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

        if hapticsEnabled {
            hapticLight.impactOccurred()
        }
    }

    func stopWorkout() -> CompletedWorkout? {
        guard workoutState == .active || workoutState == .paused else { return nil }

        timerTask?.cancel()
        continueTask?.cancel()
        timerTask = nil
        continueTask = nil
        workoutState = .finished

        // Exit workout mode — stops the real-time HR stream and returns
        // the sensor to idle so periodic spot-checks resume.
        ringManager?.exitWorkoutMode()

        // Clear activity tag so periodic sync resumes normally
        InfluxDBWriter.shared.activeTag = .none

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
        let now = Date()

        // Treat the reading as stale if no HR packets have arrived in the
        // last few seconds.  The ring streams ~1 packet/s when active, so
        // a gap > 5 s means the stream died silently (no CMD_STOP sent).
        let hrPacketAge = ringManager?.lastRealTimeHRPacketTime.map { now.timeIntervalSince($0) } ?? .infinity
        let dataFresh = hrPacketAge < 5.0

        // When sport RT (0x73) is active the firmware monopolises the PPG
        // sensor and the 0x69 HR stream goes silent.  Rather than showing
        // "warming up" we hold the last known HR value — the user IS
        // exercising (sport RT proves wrist contact) and the reading is
        // still approximately correct.
        let sportRTAge = ringManager?.lastSportRTPacketTime.map { now.timeIntervalSince($0) } ?? .infinity
        let sportRTActive = sportRTAge < 5.0

        if dataFresh, let bpm = ringManager?.realTimeHeartRateBPM, bpm > 0 {
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
            if lastSampleTime == nil || now.timeIntervalSince(lastSampleTime!) >= 0.9 {
                let sample = LiveHRSample(timestamp: now, bpm: bpm, zone: currentZone)
                samples.append(sample)
                lastSampleTime = now
            }
        } else if sportRTActive {
            // Sport RT is flowing — ring is on wrist and exercising.
            // Try to use HR derived from sport RT beat counter (byte[10]).
            if let derivedBPM = ringManager?.sportRTDerivedHR, derivedBPM > 0 {
                currentBPM = derivedBPM
                let newZone = zoneConfig.zone(for: derivedBPM)

                if newZone != previousZone && hapticsEnabled {
                    fireZoneHaptic(from: previousZone, to: newZone)
                }

                currentZone = newZone
                previousZone = newZone

                if derivedBPM > peakBPM { peakBPM = derivedBPM }

                if lastSampleTime == nil || now.timeIntervalSince(lastSampleTime!) >= 0.9 {
                    let sample = LiveHRSample(timestamp: now, bpm: derivedBPM, zone: currentZone)
                    samples.append(sample)
                    lastSampleTime = now
                }

                tLog("[GymTick] Using sport RT derived HR: \(derivedBPM) BPM")
            } else if currentBPM > 0 {
                // No derived HR yet — hold last known value.
            } else {
                currentBPM = 0
            }
        } else if currentBPM > 0 && hrPacketAge < 30.0 {
            // Stream just went silent but we had a valid reading recently.
            // Hold the last known HR for up to 30 s while the watchdog
            // restarts the stream and the sensor warms up again.  This
            // avoids flickering "warming up…" every cycle.
            // (Don't record new samples — the value is stale.)
        } else {
            // Genuinely no data for a while or never had a reading.
            // Show warmup indicator.
            currentBPM = 0
        }

        // Accumulate zone time regardless of HR availability
        if let lastTick = lastZoneTickTime {
            let delta = now.timeIntervalSince(lastTick)
            zoneTimeSeconds[currentZone.rawValue] += delta
        }
        lastZoneTickTime = now

        // ── Watchdog ───────────────────────────────────────────────
        // The ring's firmware silently stops 0x69 packets after a brief
        // measurement (~5 s of valid HR) without sending CMD_STOP.
        // We detect this silence and restart aggressively.
        //
        // Two thresholds:
        //   • streamSilenceThreshold (8 s) — used when the stream was
        //     recently active (packets were flowing).
        //   • streamColdStartThreshold (40 s) — used right after a
        //     restart, giving the PPG sensor time to warm up before we
        //     decide the stream is dead again.
        //
        // Sport RT (0x73) can displace the 0x69 stream; don't restart
        // if sport RT is still active.

        if let lastPacket = ringManager?.lastRealTimeHRPacketTime {
            let age = now.timeIntervalSince(lastPacket)

            if age < 3.0 {
                // Fresh packets arriving — reset watchdog flag
                watchdogFired = false
            } else if !sportRTActive && !watchdogFired {
                // Pick the right threshold: cold-start (just restarted)
                // or silence (was recently active).
                let inColdStart: Bool
                if let restartTime = lastWatchdogRestartTime {
                    inColdStart = now.timeIntervalSince(restartTime) < Self.streamColdStartThreshold
                } else {
                    // First cycle after workout start — treat as cold start
                    inColdStart = true
                }
                let threshold = inColdStart ? Self.streamColdStartThreshold : Self.streamSilenceThreshold

                if age >= threshold {
                    tLog("[GymWatchdog] No HR packets for \(Int(age))s (\(inColdStart ? "cold start" : "silence")) — restarting stream")
                    ringManager?.startRealTimeStreaming(type: .realtimeHeartRate)
                    ringManager?.resetHRPacketTimestamp()  // Prevent re-firing
                    watchdogFired = true
                    lastWatchdogRestartTime = now
                }
            }
        }

        // ── Command-30 continue keepalive ────────────────────────────
        // Periodically tell the ring to keep the PPG sensor alive.
        // This may be the mechanism the firmware expects to sustain
        // continuous measurement in DataType=6 mode.
        let sinceLastContinue = lastContinueKeepAliveTime.map { now.timeIntervalSince($0) } ?? .infinity
        if sinceLastContinue >= Self.continueKeepAliveInterval {
            ringManager?.sendRealtimeHRContinue()
            lastContinueKeepAliveTime = now
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
        watchdogFired = false
        lastWatchdogRestartTime = nil
        lastContinueKeepAliveTime = nil
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
