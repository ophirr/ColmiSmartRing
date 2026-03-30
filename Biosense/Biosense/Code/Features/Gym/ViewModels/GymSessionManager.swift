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
    /// True if this reading was corrected by the cadence rejection filter.
    let cadenceFiltered: Bool
    /// Confidence in this HR value (1.0 = clean, <0.5 = uncertain/corrected).
    let confidence: Double

    init(timestamp: Date, bpm: Int, zone: HRZone, cadenceFiltered: Bool = false, confidence: Double = 1.0) {
        self.timestamp = timestamp
        self.bpm = bpm
        self.zone = zone
        self.cadenceFiltered = cadenceFiltered
        self.confidence = confidence
    }
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

    /// Live steps from phone sport 0x78 notifications.
    var sportSteps: Int = 0
    /// Live distance (meters) from phone sport 0x78 notifications.
    var sportDistanceM: Int = 0

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

    /// Calibration factor applied to the ring's raw distance reading.
    /// Default 1.0 (no correction). Values <1.0 reduce reported distance
    /// (e.g. 0.88 corrects a ~12% overestimate from the ring's generic stride model).
    var distanceCalibrationFactor: Double {
        didSet {
            UserDefaults.standard.set(distanceCalibrationFactor, forKey: Self.distanceCalibrationKey)
        }
    }

    /// True when the ring is connected and streaming HR data.
    var isReceivingData: Bool { currentBPM > 0 }

    // MARK: - HR Filter

    /// Current filter confidence (1.0 = clean reading, <0.5 = corrected/uncertain).
    var hrConfidence: Double = 1.0
    /// Whether the filter is currently correcting a reading.
    var isCadenceFiltered: Bool = false
    /// Current running cadence in SPM (from 0x78 step deltas).
    var currentCadenceSPM: Int = 0

    /// When true, use the Kalman filter instead of the heuristic filter.
    /// Toggle in Settings or via UserDefaults key "gym_use_kalman_filter".
    var useKalmanFilter: Bool {
        didSet {
            UserDefaults.standard.set(useKalmanFilter, forKey: Self.kalmanFilterKey)
        }
    }

    private var hrFilter = WorkoutHRFilter()
    private var kalmanFilter = KalmanHRFilter()

    // MARK: - Private

    private static let zoneConfigKey = AppSettings.Gym.zoneConfig
    private static let ringFingerKey = AppSettings.Gym.ringFinger
    private static let hapticsKey = AppSettings.Gym.hapticsEnabled
    private static let distanceCalibrationKey = AppSettings.Gym.distanceCalibrationFactor
    private static let kalmanFilterKey = "gym_use_kalman_filter"
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
    /// Stable session ID for InfluxDB tagging (set once at workout start).
    private var workoutSessionID: String = ""
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

        // Load distance calibration factor (0.0 = never set → default 1.0)
        let savedCal = UserDefaults.standard.double(forKey: Self.distanceCalibrationKey)
        self.distanceCalibrationFactor = savedCal > 0 ? savedCal : 1.0

        // Load Kalman filter preference (default: enabled)
        if UserDefaults.standard.object(forKey: Self.kalmanFilterKey) != nil {
            self.useKalmanFilter = UserDefaults.standard.bool(forKey: Self.kalmanFilterKey)
        } else {
            self.useKalmanFilter = true
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
        let start = Date()
        workoutStartTime = start
        workoutSessionID = ISO8601DateFormatter().string(from: start)
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

        // Start phone sport mode (0x77) — tells the ring to enter enhanced
        // tracking, which may improve step counting accuracy and sends 0x78
        // notifications with real-time steps, distance, HR, and calories.
        ringManager?.sendPhoneSport(action: .start, type: .running)

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
        ringManager?.sendPhoneSport(action: .pause, type: .running)

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
        ringManager?.sendPhoneSport(action: .resume, type: .running)

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

        // Log HR filter stats
        if useKalmanFilter {
            let total = kalmanFilter.totalReadings
            let corrected = kalmanFilter.correctedReadings
            let pct = total > 0 ? String(format: "%.1f%%", Double(corrected) / Double(total) * 100) : "0%"
            tLog("[Gym] Kalman HR filter — total=\(total) corrected=\(corrected) (\(pct)) "
                 + "high_noise=\(kalmanFilter.highNoiseReadings)")
        } else {
            let total = hrFilter.totalReadings
            let corrected = hrFilter.correctedReadings
            let pct = total > 0 ? String(format: "%.1f%%", Double(corrected) / Double(total) * 100) : "0%"
            tLog("[Gym] HR filter — total=\(total) corrected=\(corrected) (\(pct)) "
                 + "slew=\(hrFilter.slewLimitedCount) harmonic=\(hrFilter.harmonicCorrectedCount) "
                 + "crash_guard=\(hrFilter.crashGuardedCount)")
        }

        // End phone sport mode (0x77) — must be sent before exitWorkoutMode
        // so the ring finalizes sport data while still connected.
        ringManager?.sendPhoneSport(action: .end, type: .running)

        // Exit workout mode — stops the real-time HR stream and returns
        // the sensor to idle so periodic spot-checks resume.
        ringManager?.exitWorkoutMode()

        // Clear activity tag so periodic sync resumes normally
        InfluxDBWriter.shared.activeTag = .none

        // Re-sync today's activity data so the Home card reflects workout steps.
        // Three-pass strategy:
        //   1) 2 s after stop — picks up any already-finalized 15-min slots
        //      + CMD 0x48 today's totals (includes running steps not in 15-min slots)
        //   2) 5 min after stop — the ring's current 15-min slot should now be
        //      finalized, so we get the full workout step count instead of a
        //      partial read from a still-open slot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            tLog("[Gym] Post-workout activity re-sync (immediate)")
            self?.ringManager?.syncActivityData(dayOffset: 0)
            // Also request today's aggregated totals — includes running steps
            // that the 15-min slot history may not count.
            self?.ringManager?.requestTodaySports()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 300.0) { [weak self] in
            tLog("[Gym] Post-workout activity re-sync (delayed 5 min)")
            self?.ringManager?.syncActivityData(dayOffset: 0)
            self?.ringManager?.requestTodaySports()
        }

        if hapticsEnabled {
            hapticNotification.notificationOccurred(.warning)
        }

        guard let start = workoutStartTime else { return nil }
        let end = Date()

        // Capture final sport steps from 0x78 before clearing
        let finalSportSteps = sportSteps
        let finalSportDistanceM = sportDistanceM

        let validSamples = samples.filter { $0.bpm > 0 }
        let avgBPM = validSamples.isEmpty ? 0 : validSamples.reduce(0) { $0 + $1.bpm } / validSamples.count

        tLog("[Gym] Workout finished — sportSteps=\(finalSportSteps) sportDistanceM=\(finalSportDistanceM)")

        return CompletedWorkout(
            startTime: start,
            endTime: end,
            durationSeconds: elapsedSeconds,
            maxHR: zoneConfig.maxHR,
            avgBPM: avgBPM,
            peakBPM: peakBPM,
            zoneTimeSeconds: zoneTimeSeconds,
            samples: samples,
            sportSteps: finalSportSteps,
            sportDistanceM: finalSportDistanceM
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

        let now = Date()

        // ── Update phone sport data FIRST ────────────────────────────
        // Read 0x78 cumulative values before any writes so the current
        // tick records fresh distance/steps, not the previous tick's.
        if let rm = ringManager, rm.phoneSportActive {
            sportSteps = rm.phoneSportSteps
            sportDistanceM = Int(Double(rm.phoneSportDistanceM) * distanceCalibrationFactor)
        }

        // ── Determine best HR source ─────────────────────────────────
        let hrPacketAge = ringManager?.lastRealTimeHRPacketTime.map { now.timeIntervalSince($0) } ?? .infinity
        let dataFresh = hrPacketAge < 5.0

        let sportRTAge = ringManager?.lastSportRTPacketTime.map { now.timeIntervalSince($0) } ?? .infinity
        let sportRTActive = sportRTAge < 5.0

        // Prefer phoneSportHR (0x78) when available — it's the ring's own
        // PPG-processed value (matches ring display).  During treadmill
        // workouts, 0x69 often reads resting HR due to arm swing artefacts
        // while 0x78 reads actual exercise HR.
        let sportHR = ringManager?.phoneSportHR ?? 0
        let rawHR69 = ringManager?.realTimeHeartRateBPM ?? 0
        let usePhoneSportHR = sportHR > 0 && (ringManager?.phoneSportActive == true)

        // Pick the HR source: 0x78 if active, else 0x69 if fresh.
        let bestRawBPM: Int
        let hrSourceLabel: String
        if usePhoneSportHR {
            bestRawBPM = sportHR
            hrSourceLabel = "0x78"
        } else if dataFresh && rawHR69 > 0 {
            bestRawBPM = rawHR69
            hrSourceLabel = "0x69"
        } else if sportRTActive && sportHR > 0 {
            // Sport RT (0x73) displaced 0x69 but phoneSportActive may be
            // false if ring auto-ended sport.  Still use 0x78 HR if nonzero.
            bestRawBPM = sportHR
            hrSourceLabel = "0x78-rt"
        } else {
            bestRawBPM = 0
            hrSourceLabel = "none"
        }

        if bestRawBPM > 0 {
            let bpm: Int
            let confidence: Double
            let wasCorrected: Bool
            let cadenceSPM: Int

            if useKalmanFilter {
                // --- Kalman filter path ---
                let source: KalmanHRFilter.HRSource = {
                    switch hrSourceLabel {
                    case "0x78":    return .phoneSport0x78
                    case "0x69":    return .realtime0x69
                    case "0x78-rt": return .sportRT0x73
                    default:        return .none
                    }
                }()

                if let kr = kalmanFilter.process(
                    rawBPM: bestRawBPM,
                    cumulativeSteps: ringManager?.phoneSportSteps ?? 0,
                    source: source,
                    packetAge: hrPacketAge,
                    timestamp: now
                ) {
                    bpm = kr.bpm
                    confidence = kr.confidence
                    wasCorrected = kr.wasCorrected
                    cadenceSPM = kr.cadenceSPM

                    hrConfidence = confidence
                    isCadenceFiltered = wasCorrected
                    currentCadenceSPM = cadenceSPM

                    // Record sample (~1 per second)
                    if lastSampleTime == nil || now.timeIntervalSince(lastSampleTime!) >= 0.9 {
                        let sample = LiveHRSample(
                            timestamp: now, bpm: bpm, zone: zoneConfig.zone(for: bpm),
                            cadenceFiltered: wasCorrected,
                            confidence: confidence
                        )
                        samples.append(sample)
                        lastSampleTime = now

                        InfluxDBWriter.shared.writeKalmanWorkoutTick(
                            bpm: bpm,
                            rawBPM: bestRawBPM,
                            cadenceSPM: cadenceSPM,
                            distanceM: sportDistanceM,
                            steps: sportSteps,
                            confidence: confidence,
                            zone: zoneConfig.zone(for: bpm).label,
                            sessionID: workoutSessionID,
                            time: now,
                            filterReason: kr.filterReason,
                            hrSource: hrSourceLabel,
                            hrPacketAge: hrPacketAge,
                            kalmanGain: kr.kalmanGain,
                            innovationBPM: kr.innovationBPM,
                            measurementNoise: kr.measurementNoise,
                            hrRate: kr.hrRate,
                            stateUncertainty: kr.stateUncertainty,
                            predictedBPM: kr.predictedBPM
                        )
                    }

                    if hrSourceLabel != "0x69" {
                        tLog("[GymTick-K] src=\(hrSourceLabel) raw=\(bestRawBPM) kalman=\(bpm) "
                             + "gain=\(String(format: "%.2f", kr.kalmanGain)) "
                             + "innov=\(String(format: "%.0f", kr.innovationBPM)) "
                             + "R=\(String(format: "%.0f", kr.measurementNoise)) "
                             + "reason=\(kr.filterReason)")
                    }
                } else {
                    bpm = 0
                    confidence = 0
                    wasCorrected = false
                    cadenceSPM = 0
                }
            } else {
                // --- Heuristic filter path (original) ---
                let filterResult = hrFilter.process(
                    rawBPM: bestRawBPM,
                    cumulativeSteps: ringManager?.phoneSportSteps ?? 0,
                    timestamp: now
                )
                bpm = filterResult.bpm
                confidence = filterResult.confidence
                wasCorrected = filterResult.wasCorrected
                cadenceSPM = filterResult.cadenceSPM

                hrConfidence = confidence
                isCadenceFiltered = wasCorrected
                currentCadenceSPM = cadenceSPM

                // Record sample (~1 per second)
                if lastSampleTime == nil || now.timeIntervalSince(lastSampleTime!) >= 0.9 {
                    let sample = LiveHRSample(
                        timestamp: now, bpm: bpm, zone: zoneConfig.zone(for: bpm),
                        cadenceFiltered: wasCorrected,
                        confidence: confidence
                    )
                    samples.append(sample)
                    lastSampleTime = now

                    InfluxDBWriter.shared.writeWorkoutTick(
                        bpm: bpm,
                        rawBPM: bestRawBPM,
                        cadenceSPM: cadenceSPM,
                        distanceM: sportDistanceM,
                        steps: sportSteps,
                        confidence: confidence,
                        cadenceFiltered: wasCorrected,
                        zone: zoneConfig.zone(for: bpm).label,
                        sessionID: workoutSessionID,
                        time: now,
                        slewDelta: filterResult.slewDelta,
                        trendBPM: filterResult.trendBPM,
                        filterReason: filterResult.filterReason,
                        hrSource: hrSourceLabel,
                        hrPacketAge: hrPacketAge,
                        crashGuardCount: filterResult.crashGuardCount
                    )
                }

                if hrSourceLabel != "0x69" {
                    tLog("[GymTick] src=\(hrSourceLabel) hr=\(bestRawBPM) filtered=\(bpm) "
                         + "cadence=\(cadenceSPM)SPM corrected=\(wasCorrected) "
                         + "conf=\(String(format: "%.2f", confidence))")
                }
            }

            currentBPM = bpm
            let newZone = zoneConfig.zone(for: bpm)

            // Zone transition haptic
            if newZone != previousZone && hapticsEnabled {
                fireZoneHaptic(from: previousZone, to: newZone)
            }

            currentZone = newZone
            previousZone = newZone

            if bpm > peakBPM { peakBPM = bpm }
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
        sportSteps = 0
        sportDistanceM = 0
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
        hrFilter.reset()
        kalmanFilter.reset()
        hrConfidence = 1.0
        isCadenceFiltered = false
        currentCadenceSPM = 0
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
    /// Steps reported by phone sport mode (0x78 notifications).
    let sportSteps: Int
    /// Distance in meters from phone sport mode.
    let sportDistanceM: Int

    func toStoredSession() -> StoredGymSession {
        let storedSamples = samples.map { GymHRSample(timestamp: $0.timestamp, bpm: $0.bpm, cadenceFiltered: $0.cadenceFiltered) }
        return StoredGymSession(
            startTime: startTime,
            endTime: endTime,
            durationSeconds: durationSeconds,
            maxHR: maxHR,
            avgBPM: avgBPM,
            peakBPM: peakBPM,
            sportRTSteps: sportSteps,
            sportDistanceM: sportDistanceM,
            zoneTimeSeconds: zoneTimeSeconds,
            samples: storedSamples
        )
    }
}
