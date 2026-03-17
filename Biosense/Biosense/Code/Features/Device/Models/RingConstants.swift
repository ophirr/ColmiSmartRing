//
//  RingConstants.swift
//  Biosense
//
//  Ring firmware constants, BLE protocol timeouts, and named values
//  extracted from RingSessionManager to improve readability.
//

import Foundation

/// Central repository of ring protocol constants and firmware-imposed timing values.
/// All values are documented with the *why* — not just the *what*.
enum RingConstants {

    // MARK: - BLE Command IDs (Nordic UART protocol)

    static let cmdSetDeviceTime: UInt8       = 0x01
    static let cmdBattery: UInt8             = 0x03
    static let cmdBlinkTwice: UInt8          = 0x10  // 16
    static let cmdReadHeartRate: UInt8       = 0x15  // 21
    static let cmdHRTimingMonitor: UInt8     = 0x16  // 22 — HR log interval + enable
    static let cmdHeartRateSetting: UInt8    = 22    // Settings protocol: HR toggle
    static let cmdRealTimeHeartRate: UInt8   = 0x1E  // 30
    static let cmdBloodOxygen: UInt8         = 44    // Settings protocol: SpO2 toggle
    static let cmdPressureSetting: UInt8     = 54    // Settings protocol: Stress toggle
    static let cmdReadPressureData: UInt8    = 55    // Historical stress data
    static let cmdHRVSetting: UInt8          = 56    // Settings protocol: HRV toggle
    static let cmdReadHRVData: UInt8         = 57    // Historical HRV data
    static let cmdReadActivityData: UInt8    = 67    // Steps/calories/distance
    static let cmdSleepData: UInt8           = 68
    static let cmdSyncSleepLegacy: UInt8     = 0xBC  // 188
    static let cmdStartRealTime: UInt8       = 0x69  // 105
    static let cmdStopRealTime: UInt8        = 0x6A  // 106
    static let cmdPathwayAStop: UInt8        = 0x6B  // 107
    static let cmdSportRealTime: UInt8       = 0x73  // 115
    /// Ack byte for CMD_REAL_TIME_HEART_RATE (0x1E + 0x80 = 0x9E).
    /// The ring echoes command | 0x80 as acknowledgement.
    static let cmdRealTimeHeartRateAck: UInt8 = 0x9E  // 158

    // MARK: - Big Data Protocol

    static let bigDataMagic: UInt8        = 188   // 0xBC
    /// Big Data packet header: [magic, dataId, lenLo, lenHi, crc16Lo, crc16Hi].
    static let bigDataHeaderLength: Int   = 6
    static let bigDataSleepId: UInt8      = 39
    static let bigDataBloodOxygenId: UInt8 = 42

    // MARK: - Settings Protocol Actions

    static let settingsActionRead: UInt8  = 1
    static let settingsActionWrite: UInt8 = 2

    // MARK: - Spot-Check Timeouts
    //
    // The VC30F PPG sensor needs a warmup period after every cold start.
    // HR ramps from 70-90+ bpm down toward true resting over 30-60s.
    // Temperature swings 5-10°C before settling. SpO2 takes longest.
    // These timeouts are the minimum duration to collect reliable data.

    /// SpO2 spot-check: 60s to allow the ring's SpO2 algorithm to converge.
    static let spotCheckTimeoutSpO2: UInt64      = 60
    /// Temperature: 20s is enough because we only need a single calibrated reading
    /// from the ring (it sends the final calibrated value near the end).
    static let spotCheckTimeoutTemp: UInt64       = 20
    /// Heart rate: 60s for PPG sensor warmup convergence. We collect all readings
    /// and take the median of the last 5 (most settled values).
    static let spotCheckTimeoutHR: UInt64         = 60
    /// Fallback for unknown measurement types.
    static let spotCheckTimeoutDefault: UInt64    = 30

    /// Number of tail readings to use for median calculation.
    /// The last N readings are the most converged after PPG warmup.
    static let spotCheckMedianWindowSize          = 5
    /// Body temperature valid range (°C). Readings outside this are sensor artefacts.
    static let bodyTempRangeMin: Double           = 35.0
    static let bodyTempRangeMax: Double           = 38.0
    /// Physiologically valid BPM range.
    static let validBPMMin: UInt8                 = 30
    static let validBPMMax: UInt8                 = 220
    /// SpO2 physiologically valid range (%). Readings outside are sensor artefacts.
    static let spo2RangeMin: Int                  = 70
    static let spo2RangeMax: Int                  = 100
    /// VC30F raw temperature divisor: raw 16-bit value / 20.0 = degrees Celsius.
    /// e.g. raw 730 → 730 / 20.0 = 36.5 °C
    static let tempRawDivisor: Double             = 20.0

    // MARK: - Keepalive Chain
    //
    // The app sends CMD_BATTERY → ring responds → didUpdateValueFor wakes
    // the app (even from background) → handleBatteryResponse fires a spot-check
    // and schedules the next ping. Self-sustaining BLE-event-driven chain.

    /// Interval between keepalive battery pings. 60s gives ~1/min InfluxDB writes.
    static let keepaliveInterval: TimeInterval    = 60
    /// Safety net: if the ring doesn't respond within this time, retry the ping.
    static let keepaliveFallbackTimeout: TimeInterval = 30
    /// Full data sync (HR log, HRV, SpO2, etc.) every N keepalive pings.
    /// With 60s keepalive, 5 = full sync every ~5 minutes.
    static let fullSyncEveryNPings: Int           = 5

    // MARK: - Spot-Check Rotation (modulo rules for keepalive-driven spot-checks)

    /// SpO2 spot-check every Nth ping (~10 min with 60s keepalive).
    /// SpO2 is the most expensive (60s window), so it runs least often.
    static let spotCheckSpO2EveryNPings: Int      = 10
    /// Temperature spot-check every Nth non-SpO2 ping.
    static let spotCheckTempEveryNPings: Int      = 3

    // MARK: - BLE Scan & Connection

    /// How long to scan before giving up (discovery or reconnect).
    static let scanTimeout: TimeInterval          = 15
    /// Delay before retrying a stuck .connecting peripheral.
    static let connectRetryDelay: TimeInterval    = 0.5
    /// Minimum spacing between sequential BLE commands to avoid overwhelming
    /// the ring's single-threaded UART handler. 0.6s empirically reliable.
    static let bleCommandSpacing: TimeInterval    = 0.6

    // MARK: - Sport RT (command 0x73)

    /// Sliding window for deriving HR from byte[10] cumulative beat counter.
    /// 10s gives enough samples for a reliable estimate while staying responsive.
    static let sportRTWindowSeconds: TimeInterval = 10.0
    /// Minimum number of beat counter samples before computing a derived HR.
    static let sportRTMinSamples: Int             = 3
    /// Minimum elapsed time (s) in the sliding window before HR derivation is valid.
    /// Prevents wild spikes from very short measurement windows.
    static let sportRTMinElapsed: TimeInterval    = 3.0

    // MARK: - InfluxDB Write Throttle

    /// Minimum interval between real-time InfluxDB writes (non-workout).
    static let influxWriteIntervalNormal: TimeInterval  = 60
    /// Minimum interval during workouts (higher resolution).
    static let influxWriteIntervalWorkout: TimeInterval = 15

    // MARK: - Debug Log

    /// Maximum entries in the circular debug log buffer.
    static let debugLogMaxEntries: Int = 300

    // MARK: - Stale Keepalive Detection

    /// If no keepalive was sent in 2× the interval, the chain is considered stalled.
    static let keepaliveStallMultiplier: Double = 2.0

    // MARK: - Async Tracking Setting (read/write with timeout)

    /// Timeout for ring tracking-setting read/write responses.
    static let trackingSettingTimeout: TimeInterval = 5.0

    // MARK: - Sync-on-Connect Spot-Check Chain
    //
    // After initial sync, the app runs SpO2 → HR → Temp spot-checks
    // sequentially.  Each delay accounts for the previous check's
    // timeout plus a small BLE settle buffer.

    /// Delay before HR spot-check: SpO2 timeout (60s) + 5s buffer.
    static let spotCheckChainHRDelay: TimeInterval   = 65
    /// Delay before Temp spot-check: 60s + 20s + 20s margin.
    static let spotCheckChainTempDelay: TimeInterval  = 100
    /// Delay before retrying battery if no response after connect.
    static let batteryRetryDelay: TimeInterval        = 5.0

    // MARK: - Sleep Command Protocol (CMD 68)

    /// Sub-data byte 1: number of 15-minute slots per query page.
    static let sleepQuerySlotCount: UInt8  = 15
    /// Sub-data byte 3: max entries per response page (0x5F = 95).
    static let sleepQueryMaxEntries: UInt8 = 95
}
