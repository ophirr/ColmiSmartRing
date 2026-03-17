 //
//  RingSessionManager.swift
//  Biosense
//
//  Created by Yannis De Cleene on 27/01/2025.
//

import Foundation
import CoreBluetooth
import SwiftUI

/// Settings-protocol tracking toggles (READ/WRITE isEnabled) shared by HRV, Heart Rate, Blood Oxygen, Pressure.
enum RingTrackingSetting: CaseIterable {
    case hrv           // command 56
    case heartRate     // command 22
    case bloodOxygen   // command 44
    case pressure      // command 54 (Stress)

    var commandId: UInt8 {
        switch self {
        case .hrv: return 56
        case .heartRate: return 22
        case .bloodOxygen: return 44
        case .pressure: return 54
        }
    }

    /// Maps response commandId back to setting; nil if not a tracking-setting command.
    init?(commandId: UInt8) {
        switch commandId {
        case 56: self = .hrv
        case 22: self = .heartRate
        case 44: self = .bloodOxygen
        case 54: self = .pressure
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .hrv: return "HRV"
        case .heartRate: return "Heart Rate"
        case .bloodOxygen: return "Blood Oxygen"
        case .pressure: return "Pressure (Stress)"
        }
    }
}

/// Unified PPG sensor state.  The ring has a single VC30F sensor shared by
/// HR, SpO2, and temperature — only one measurement can run at a time.
/// This enum replaces the scattered boolean flags that previously tracked
/// which mode the sensor was in.
enum SensorState: Equatable, CustomStringConvertible {
    case idle
    case spotCheck(RealTimeReading)   // brief measurement, auto-stops
    case continuousHR                  // user-toggled from home screen
    case spo2Stream                    // SpO2 with 2s continue keepalives
    case workout                       // gym session owns the sensor

    var description: String {
        switch self {
        case .idle: return "idle"
        case .spotCheck(let type): return "spotCheck(\(type))"
        case .continuousHR: return "continuousHR"
        case .spo2Stream: return "spo2Stream"
        case .workout: return "workout"
        }
    }
}

private let savedRingIdentifierKey = "savedRingIdentifier"
private let savedRingDisplayNameKey = "savedRingDisplayName"
private let preferredDataTimeZoneIdentifierKey = "preferredDataTimeZoneIdentifier"

@Observable
class RingSessionManager: NSObject {
    var peripheralConnected = false
    /// When true, the app behaves as if a ring is connected (for demo/testing).
    var demoModeActive = false
    /// True when either a real ring is connected or demo mode is active.
    var isEffectivelyConnected: Bool { peripheralConnected || demoModeActive }
    // MARK: - PPG Sensor State Machine

    /// Unified PPG sensor state.  Only one measurement can run at a time.
    private(set) var sensorState: SensorState = .idle
    /// Survives BLE disconnect — set by enterWorkoutMode, cleared by exitWorkoutMode.
    /// Lets syncOnConnect know a gym session is in progress even though sensorState
    /// was reset to .idle on disconnect.
    private(set) var gymWorkoutInProgress = false

    /// Backward-compatible computed properties — external consumers
    /// (GymSessionManager, HomeScreenView, etc.) read these as before.
    var isWorkoutActive: Bool { sensorState == .workout }
    var isContinuousHRStreamActive: Bool { sensorState == .continuousHR }
    var isSpO2StreamActive: Bool {
        switch sensorState {
        case .spo2Stream: return true
        case .spotCheck(.spo2): return true
        default: return false
        }
    }

    /// Latest real-time heart rate reading in bpm.
    var realTimeHeartRateBPM: Int?
    /// When the last command 105 heartRate packet arrived (including zeros).
    /// Used by GymSessionManager to detect when the stream has gone silent.
    var lastRealTimeHRPacketTime: Date?
    /// When the last sport real-time (0x73) packet arrived.
    /// Used by GymSessionManager to distinguish "stream dead" from
    /// "HR stream displaced by sport telemetry" (ring still on wrist, exercising).
    var lastSportRTPacketTime: Date?

    // MARK: Sport RT heartbeat counter (hypothesis: byte[10] = cumulative beat count)

    /// Estimated HR derived from the sport RT beat counter (byte[10]).
    /// Updated each 0x73 packet via a sliding window over the last ~10 seconds.
    /// nil until enough data has accumulated for a reliable estimate.
    var sportRTDerivedHR: Int?

    /// Ring buffer of (timestamp, byte10) samples used to compute sportRTDerivedHR.
    private var sportRTBeatSamples: [(time: Date, b10: UInt8)] = []

    /// How many seconds of history to use for the sliding-window HR estimate.
    private let sportRTWindowSeconds: TimeInterval = 10.0
    /// Latest real-time blood oxygen reading in percent.
    var realTimeBloodOxygenPercent: Int?
    /// Timer that sends continue keepalives to keep the SpO2 measurement alive.
    private var spo2ContinueTimer: Timer?
    /// Latest real-time body temperature in °C (e.g. 36.3).
    var realTimeTemperatureCelsius: Double?
    /// Latest battery info reported by the ring.
    var currentBatteryInfo: BatteryInfo?
    /// True when we have a saved ring but no peripheral and are scanning for it.
    var isScanningForRing = false
    /// Peripherals found during "Add ring" scan (name starts with R02_).
    var discoveredPeripherals: [CBPeripheral] = []
    /// True when scanning for ring to add (discovery list).
    var isDiscovering = false

    /// Persisted ring identifier for reconnection; nil if no ring has been added. Stored so @Observable updates the UI when set in didConnect.
    var savedRingIdentifier: UUID? {
        didSet {
            if let id = savedRingIdentifier {
                UserDefaults.standard.set(id.uuidString, forKey: savedRingIdentifierKey)
            } else {
                UserDefaults.standard.removeObject(forKey: savedRingIdentifierKey)
                UserDefaults.standard.removeObject(forKey: savedRingDisplayNameKey)
            }
        }
    }
    /// Display name for the ring (from BLE peripheral name).
    var ringDisplayName: String? {
        didSet {
            if let n = ringDisplayName {
                UserDefaults.standard.set(n, forKey: savedRingDisplayNameKey)
            } else {
                UserDefaults.standard.removeObject(forKey: savedRingDisplayNameKey)
            }
        }
    }

    /// Time zone used when building day-based request timestamps (e.g. heart-rate history).
    var preferredDataTimeZoneIdentifier: String {
        didSet {
            UserDefaults.standard.set(preferredDataTimeZoneIdentifier, forKey: preferredDataTimeZoneIdentifierKey)
        }
    }

    var preferredDataTimeZone: TimeZone {
        TimeZone(identifier: preferredDataTimeZoneIdentifier) ?? .current
    }

    private var manager: CBCentralManager!
    private var peripheral: CBPeripheral?

    private static let scanTimeout: TimeInterval = 15
    private var scanWorkItem: DispatchWorkItem?

    /// Interval between keepalive battery pings.  Each ping wakes the app from
    /// background via the BLE response callback, forming a self-sustaining chain.
    /// 60 s gives us ~1/min InfluxDB spot-checks even when the phone is locked.
    private static let keepaliveInterval: TimeInterval = 60
    private var keepaliveWorkItem: DispatchWorkItem?
    /// Timestamp of the last keepalive ping sent (or chain restart). Used to detect stalled chains.
    private var lastKeepaliveSentAt: Date = Date()

    /// How many keepalive pings between full data syncs (HR log, HRV, SpO2, etc.).
    /// With a 60 s keepalive, 5 = full sync every ~5 minutes.
    private static let fullSyncEveryNPings: Int = 5
    /// Counter incremented on each keepalive; triggers full sync when it hits fullSyncEveryNPings.
    /// Spot-check rotation: SpO2 every 10th ping (~10 min, 60s window), temperature every 3rd, rest HR.
    private var keepalivePingCount: Int = 0
    /// Counts how many full-sync cycles have occurred.
    private var fullSyncCycleCount: Int = 0

    /// Periodic timer that re-syncs HR log (and other data) at the user's configured HR interval.
    /// Used as a foreground fallback; the BLE keepalive chain is the primary background driver.
    private var periodicSyncTimer: Timer?

    /// True when a spot-check is in progress (derived from sensorState).
    private var spotCheckActive: Bool {
        if case .spotCheck = sensorState { return true }
        return false
    }
    /// Which reading type the current spot-check is measuring (derived from sensorState).
    private var spotCheckType: RealTimeReading {
        if case .spotCheck(let type) = sensorState { return type }
        return .realtimeHeartRate
    }
    /// Auto-stop the spot-check after this timeout even if no valid reading arrives.
    private var spotCheckTimeoutTask: Task<Void, Never>?
    /// All temperature readings received during the current spot-check.
    /// The timeout handler picks the median of body-range values (35-42°C)
    /// rather than trusting a single noisy sample.
    private var spotCheckTempReadings: [Double] = []
    /// All HR readings received during the current HR spot-check.
    /// The VC30F PPG sensor's first readings after a cold start are often
    /// elevated (warmup artefact).  We collect for the full timeout period
    /// and write the median to InfluxDB instead of trusting the first value.
    private var spotCheckHRReadings: [Int] = []

    /// True while we're waiting for a battery response that was sent by the
    /// keepalive chain.  Prevents `handleBatteryResponse` from driving the
    /// chain when the battery read was triggered by `syncOnConnect` or
    /// `getBatteryStatus` — which caused duplicate responses to pile up.
    private var awaitingKeepaliveBatteryResponse = false

    /// Auto-reconnect task after unexpected disconnection.
    private var reconnectTask: Task<Void, Never>?

    /// Throttle real-time InfluxDB writes — 15s during workouts, 60s otherwise.
    private var lastInfluxHRWrite: Date = .distantPast
    private var lastInfluxSpO2Write: Date = .distantPast
    private var lastInfluxTempWrite: Date = .distantPast
    private var currentInfluxWriteInterval: TimeInterval {
        isWorkoutActive ? 15 : 60
    }

    private var uartRxCharacteristic: CBCharacteristic?
    private var uartTxCharacteristic: CBCharacteristic?
    private var colmiWriteCharacteristic: CBCharacteristic?
    private var colmiNotifyCharacteristic: CBCharacteristic?

    private static let ringServiceUUID = SmartRingBLE.nordicUARTServiceUUID
    private static let colmiServiceUUID = SmartRingBLE.colmiServiceUUID
    private static let colmiWriteUUID = SmartRingBLE.colmiWriteUUID
    private static let colmiNotifyUUID = SmartRingBLE.colmiNotifyUUID
    private static let uartRxCharacteristicUUID = SmartRingBLE.nordicUARTTxUUID
    private static let uartTxCharacteristicUUID = SmartRingBLE.nordicUARTRxUUID

    private static let deviceInfoServiceUUID = SmartRingBLE.deviceInfoServiceUUID
    private static let deviceHardwareUUID = SmartRingBLE.hardwareRevisionCharUUID
    private static let deviceFirmwareUUID = SmartRingBLE.firmwareRevisionCharUUID

    private static let CMD_SET_DEVICE_TIME: UInt8 = 0x01
    private static let CMD_BLINK_TWICE: UInt8 = 16 // 0x10
    private static let CMD_BATTERY: UInt8 = 3
    private static let CMD_READ_HEART_RATE: UInt8 = 21  // 0x15
    /// HR timing monitor switch: READ/WRITE enabled + interval in minutes. ID: 0x16.
    private static let CMD_HR_TIMING_MONITOR: UInt8 = 0x16
    /// Heart Rate setting (Settings protocol): READ/WRITE isEnabled. ID: 22.
    private static let CMD_HEART_RATE_SETTING: UInt8 = 22
    /// Pressure/Stress setting (Settings protocol): READ/WRITE isEnabled. ID: 54.
    private static let CMD_PRESSURE: UInt8 = 54
    /// Pressure/Stress historical data request (Commands protocol, split array).
    private static let CMD_READ_PRESSURE_DATA: UInt8 = 55
    /// HRV setting (Settings protocol): READ/WRITE isEnabled. ID: 56.
    private static let CMD_HRV: UInt8 = 56
    /// HRV historical data request (Commands protocol, split array).
    private static let CMD_READ_HRV_DATA: UInt8 = 57
    /// Sports/activity historical data request (steps, calories, distance).
    private static let CMD_READ_ACTIVITY_DATA: UInt8 = 67
    /// Sleep Data (Colmi BLE API: https://colmi.puxtril.com/commands/#sleep-data) – request/response use ID 68
    private static let CMD_SLEEP_DATA: UInt8 = 68
    /// Legacy Big Data syncHistoricalSleep; some firmware may use 0xBC 0x27
    private static let CMD_SYNC_SLEEP_LEGACY: UInt8 = 188 // 0xBC

    private static let CMD_START_REAL_TIME: UInt8 = 105
    private static let CMD_STOP_REAL_TIME: UInt8 = 106
    /// Sport real-time telemetry — ring sends these automatically during exercise.
    private static let CMD_SPORT_REAL_TIME: UInt8 = 115  // 0x73
    /// Realtime heart rate response (0x1E).  Sent by the ring when
    /// DataType=6 (realtimeHeartRate) is requested via CMD_START_REAL_TIME.
    /// Packet: [30, heartRate, 0, ..., checksum]
    private static let CMD_REAL_TIME_HEART_RATE: UInt8 = 30
    
    
    /// Pathway A: general-purpose real-time start/response (0x6A).
    /// Used for SpO2 (DataType=3) and other non-HR measurements.
    /// NOT the same as CMD_STOP_REAL_TIME (which is 0x6A but used for HR auto-stop).
    private static let CMD_PATHWAY_A: UInt8 = 0x6A       // 106
    /// Pathway A: stop command (0x6B).
    private static let CMD_PATHWAY_A_STOP: UInt8 = 0x6B  // 107

    private static let CMD_BLOOD_OXYGEN: UInt8 = 44
    

    private let hrp = HeartRateLogParser()
    private let healthHRWriter = AppleHealthHeartRateWriter()

    private var characteristicsDiscovered = false
    /// Tracks which notify characteristics have been confirmed by CoreBluetooth.
    private var confirmedNotifyCharacteristics: Set<CBUUID> = []
    /// Prevents syncOnConnect from firing more than once per connection.
    private var syncOnConnectFired = false

    var batteryStatusCallback: ((BatteryInfo) -> Void)?
    var heartRateLogCallback: ((HeartRateLog) -> Void)?
    /// FIFO queue of requested day-starts — one per in-flight HR log request.
    /// Responses arrive in the same order as requests, so we dequeue from the front.
    private var heartRateLogRequestedDays: [Date] = []
    /// Called with each raw sleep response packet (16 bytes) for debugging / future parsing
    var sleepPacketCallback: (([UInt8]) -> Void)?
    /// Called when sleep data (command 68) is received; dayOffset is the requested day (0 = today).
    var sleepDataCallback: ((SleepData) -> Void)?
    /// Called when Big Data sleep (dataId 39) is received from Colmi service.
    var bigDataSleepCallback: ((BigDataSleepData) -> Void)?
    /// Always-on callback intended for persistence layer when Big Data sleep is received.
    var bigDataSleepPersistenceCallback: ((BigDataSleepData) -> Void)?
    /// Called when Big Data blood oxygen payload (dataId 42) is received.
    var bigDataBloodOxygenPayloadCallback: (([UInt8]) -> Void)?
    /// Always-on callback intended for persistence layer when Big Data blood oxygen payload is received.
    var bigDataBloodOxygenPayloadPersistenceCallback: (([UInt8]) -> Void)?
    /// Called with each raw HRV data packet (command 57).
    var hrvDataPacketCallback: (([UInt8]) -> Void)?
    /// Always-on callback intended for persistence layer for HRV packets.
    var hrvDataPacketPersistenceCallback: (([UInt8]) -> Void)?
    /// Called with each raw pressure/stress data packet (command 55).
    var pressureDataPacketCallback: (([UInt8]) -> Void)?
    /// Always-on callback intended for persistence layer for pressure packets.
    var pressureDataPacketPersistenceCallback: (([UInt8]) -> Void)?
    /// Called with each raw activity data packet (command 67).
    var activityDataPacketCallback: (([UInt8]) -> Void)?
    /// Always-on callback intended for persistence layer for activity packets.
    var activityDataPacketPersistenceCallback: (([UInt8]) -> Void)?
    /// Always-on callback intended for persistence layer when a heart-rate log is parsed.
    /// Second parameter is the requested day-start (canonical date for storage/dedup).
    var heartRateLogPersistenceCallback: ((HeartRateLog, Date) -> Void)?
    /// Called when the ring is connected and UART characteristics are ready; use this to trigger tracking-settings reads.
    var onReadyForSettingsQuery: (() -> Void)?
    /// HR log interval reported by the ring (minutes). nil = not yet queried.
    var hrLogIntervalMinutes: Int?
    /// HR log enabled state reported by the ring. nil = not yet queried.
    var hrLogEnabled: Bool?
    /// Pending continuation for HR log settings read.
    private var pendingHRLogSettingsContinuation: CheckedContinuation<(enabled: Bool, intervalMinutes: Int), Error>?
    /// Single callback or continuation for any in-flight tracking setting READ; cleared after use.
    private var pendingTrackingSetting: RingTrackingSetting?
    private var pendingTrackingSettingCallback: ((Bool) -> Void)?
    private var pendingTrackingSettingContinuation: CheckedContinuation<Bool, Error>?
    private var trackingSettingGeneration: UInt = 0
    /// Last requested dayOffset for sleep (0 = today); used when parsing response 68.
    private var lastSleepDayOffset: Int = 0
    /// Big Data notify buffer (variable-length responses may arrive in chunks).
    private var bigDataBuffer: [UInt8] = []
    private static let bigDataMagic: UInt8 = 188
    private static let bigDataSleepId: UInt8 = 39
    private static let bigDataBloodOxygenId: UInt8 = 42

    // MARK: - Debug log (for Debug tab)
    struct DebugLogEntry: Identifiable {
        let id = UUID()
        let date: Date
        let direction: Direction
        let bytes: [UInt8]
        enum Direction: String { case sent = "→ Sent"; case received = "← Received" }
    }
    private static let debugLogMaxEntries = 300
    var debugLog: [DebugLogEntry] = []

    override init() {
        if let s = UserDefaults.standard.string(forKey: savedRingIdentifierKey), let id = UUID(uuidString: s) {
            self.savedRingIdentifier = id
            self.ringDisplayName = UserDefaults.standard.string(forKey: savedRingDisplayNameKey)
        } else {
            self.savedRingIdentifier = nil
            self.ringDisplayName = nil
        }
        if let tz = UserDefaults.standard.string(forKey: preferredDataTimeZoneIdentifierKey),
           TimeZone(identifier: tz) != nil {
            self.preferredDataTimeZoneIdentifier = tz
        } else {
            self.preferredDataTimeZoneIdentifier = TimeZone.current.identifier
        }
        super.init()
        manager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.halo.ring-central"]
        )

        // When the app returns to foreground (phone unlocked), trigger a reconnect
        // if needed and run a sync + spot-check for a fresh InfluxDB reading.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            tLog("[Foreground] App entering foreground")
            if self.peripheralConnected, self.characteristicsDiscovered {
                tLog("[Foreground] Connected — running sync + spot-check")
                self.runPeriodicSync()
            } else if self.savedRingIdentifier != nil, !self.peripheralConnected {
                tLog("[Foreground] Disconnected — attempting reconnect")
                self.findRingAgain()
            }
        }
    }

    // MARK: - RingSessionManager actions

    /// Start BLE discovery for Colmi ring (by name prefix R02_). Results go to discoveredPeripherals.
    func startDiscovery() {
        stopDiscovery()
        discoveredPeripherals = []
        isDiscovering = true
        if manager.state == .poweredOn {
            actuallyStartScan()
        } else {
            tLog("[Discovery] Waiting for BLE (state=\(manager.state.rawValue))")
        }
    }

    func stopDiscovery() {
        guard isDiscovering else { return }
        scanWorkItem?.cancel()
        scanWorkItem = nil
        if manager.state == .poweredOn {
            manager.stopScan()
        }
        isDiscovering = false
    }

    private func actuallyStartScan() {
        guard manager.state == .poweredOn else { return }
        // Rings already connected at the iOS level won't appear in a scan,
        // so retrieve them by known service UUIDs first.
        let alreadyConnected = manager.retrieveConnectedPeripherals(withServices: [
            CBUUID(string: Self.ringServiceUUID),
            CBUUID(string: Self.colmiServiceUUID)
        ])
        for p in alreadyConnected where isColmiRingName(p.name ?? "") {
            if !discoveredPeripherals.contains(where: { $0.identifier == p.identifier }) {
                discoveredPeripherals.append(p)
            }
        }
        manager.scanForPeripherals(withServices: nil, options: nil)
        scanWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.stopDiscovery()
        }
        scanWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scanTimeout, execute: item)
    }

    /// Connect to a discovered peripheral and save it as the ring (persist identifier).
    func connectAndSaveRing(peripheral p: CBPeripheral) {
        tLog("[Connect] connectAndSaveRing called – manager.state=\(manager.state.rawValue), peripheral.state=\(p.state.rawValue)")
        guard manager.state == .poweredOn else {
            tLog("[Connect] ⚠️ Manager not powered on, aborting")
            return
        }
        if p.state == .connected {
            tLog("[Connect] Already connected — setting up")
            stopDiscovery()
            p.delegate = self
            peripheral = p
            p.discoverServices(nil)
            return
        }
        if p.state == .connecting {
            tLog("[Connect] Stuck in .connecting — cancelling and retrying")
            manager.cancelPeripheralConnection(p)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.connectAndSaveRing(peripheral: p)
            }
            return
        }
        stopDiscovery()
        p.delegate = self
        peripheral = p
        manager.connect(p, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
        ])
        tLog("[Connect] Connection request sent")
    }

    func removeRing() {
        stopDiscovery()
        stopScanningForRing()
        if peripheralConnected {
            disconnect()
        }
        peripheral = nil
        savedRingIdentifier = nil
        ringDisplayName = nil
    }

    /// Reconnect: connect if we have a peripheral reference, otherwise try retrieve then scan by name.
    func findRingAgain() {
        guard savedRingIdentifier != nil else { return }
        if peripheralConnected { return }
        if let peripheral {
            connect()
        } else if manager.state == .poweredOn {
            if let id = savedRingIdentifier,
               let known = manager.retrievePeripherals(withIdentifiers: [id]).first {
                peripheral = known
                known.delegate = self
                connect()
            } else {
                // Also check for peripherals already connected at the system level.
                let connected = manager.retrieveConnectedPeripherals(withServices: [
                    CBUUID(string: Self.ringServiceUUID),
                    CBUUID(string: Self.colmiServiceUUID)
                ])
                if let match = connected.first(where: { $0.identifier == savedRingIdentifier }) {
                    peripheral = match
                    match.delegate = self
                    connect()
                } else {
                    startScanningForRing()
                }
            }
        }
    }

    private func startScanningForRing() {
        guard manager.state == .poweredOn, peripheral == nil, savedRingIdentifier != nil else { return }
        scanWorkItem?.cancel()
        isScanningForRing = true
        manager.scanForPeripherals(withServices: nil, options: nil)
        let item = DispatchWorkItem { [weak self] in
            self?.stopScanningForRing()
        }
        scanWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scanTimeout, execute: item)
    }

    private func stopScanningForRing() {
        guard isScanningForRing else { return }
        scanWorkItem?.cancel()
        scanWorkItem = nil
        if manager.state == .poweredOn {
            manager.stopScan()
        }
        isScanningForRing = false
    }

    func connect() {
        guard manager.state == .poweredOn, let peripheral else { return }
        // If the peripheral is stuck in .connecting (e.g. restored from a killed session),
        // cancel it first so CoreBluetooth starts fresh.
        if peripheral.state == .connecting {
            tLog("[Connect] Peripheral stuck in .connecting — cancelling first")
            manager.cancelPeripheralConnection(peripheral)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, let p = self.peripheral, self.manager.state == .poweredOn else { return }
                tLog("[Connect] Re-connecting after cancel")
                self.manager.connect(p, options: [
                    CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                    CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
                ])
            }
            return
        }
        if peripheral.state == .connected {
            tLog("[Connect] Already connected — discovering services")
            peripheralConnected = true
            peripheral.discoverServices(nil)
            return
        }
        // CoreBluetooth persists this connect request even when the app is
        // suspended.  When the peripheral reappears, iOS wakes the app and
        // delivers didConnect — no manual retry loop needed.
        manager.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])
    }

    func disconnect() {
        guard let peripheral, manager.state == .poweredOn else { return }
        reconnectTask?.cancel()  // User-initiated — don't auto-reconnect
        reconnectTask = nil
        // cancelPeripheralConnection also cancels any pending persistent
        // connect request, so the ring won't auto-reconnect.
        manager.cancelPeripheralConnection(peripheral)
    }

    /// Append a line to the debug log (used by Debug tab). Keeps last N entries.
    func appendToDebugLog(direction: DebugLogEntry.Direction, bytes: [UInt8]) {
        let entry = DebugLogEntry(date: Date(), direction: direction, bytes: bytes)
        debugLog.append(entry)
        if debugLog.count > Self.debugLogMaxEntries {
            debugLog.removeFirst(debugLog.count - Self.debugLogMaxEntries)
        }
    }

    /// Send a raw command packet and log it. Payload is optional (up to 14 bytes). Packet is 16 bytes with checksum.
    func sendDebugCommand(command: UInt8, subData: [UInt8]? = nil) {
        do {
            let packet = try makePacket(command: command, subData: subData)
            appendToDebugLog(direction: .sent, bytes: packet)
            sendPacket(packet: packet)
        } catch {
            appendToDebugLog(direction: .sent, bytes: [command])
        }
    }

    func clearDebugLog() {
        debugLog = []
        debugLogEntryTags = [:]
    }

    /// Tags for log entries (entry id → set of tag strings). Multiple tags per entry.
    var debugLogEntryTags: [UUID: Set<String>] = [:]

    func addTag(forEntryId id: UUID, tag: String) {
        let t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        debugLogEntryTags[id, default: []].insert(t)
    }

    func removeTag(forEntryId id: UUID, tag: String) {
        debugLogEntryTags[id]?.remove(tag)
        if debugLogEntryTags[id]?.isEmpty == true {
            debugLogEntryTags.removeValue(forKey: id)
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension RingSessionManager: CBCentralManagerDelegate {

    /// Called when the app is relaunched by iOS after being terminated.
    /// CoreBluetooth restores the peripheral references that were active.
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        tLog("[Restore] CoreBluetooth restoring state")
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let restored = peripherals.first {
            tLog("[Restore] Restored peripheral: \(restored.identifier), state=\(restored.state.rawValue)")
            self.peripheral = restored
            restored.delegate = self
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        tLog("Central manager state: \(central.state)")
        switch central.state {
        case .poweredOn:
            if isDiscovering {
                actuallyStartScan()
            } else if let id = savedRingIdentifier {
                if let known = central.retrievePeripherals(withIdentifiers: [id]).first {
                    tLog("Found previously connected peripheral")
                    peripheral = known
                    peripheral?.delegate = self
                    // Skip if a connect is already in-flight (e.g. foreground handler
                    // called findRingAgain() before this delegate fired).
                    if known.state == .connecting {
                        tLog("[Connect] Already connecting — skipping duplicate connect")
                    } else {
                        connect()
                    }
                } else {
                    tLog("Known peripheral not found, starting scan")
                    startScanningForRing()
                }
            }
        default:
            peripheral = nil
            stopScanningForRing()
            stopDiscovery()
        }
    }

    private func isColmiRingName(_ name: String) -> Bool {
        let upper = name.uppercased()
        return upper.hasPrefix(SmartRingBLE.deviceNamePrefix.uppercased())
            || upper.hasPrefix(SmartRingBLE.deviceNamePrefixAlt.uppercased())
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // peripheral.name can be nil on first discovery; prefer the advertisement local name.
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? ""
        if isDiscovering {
            guard isColmiRingName(name) else { return }
            if !discoveredPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
                discoveredPeripherals.append(peripheral)
            }
            return
        }
        if isScanningForRing, peripheral.identifier == savedRingIdentifier {
            stopScanningForRing()
            self.peripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: [
                CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
                CBConnectPeripheralOptionStartDelayKey: 1
            ])
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        stopScanningForRing()
        reconnectTask?.cancel()
        reconnectTask = nil
        if peripheralConnected {
            return
        }
        if savedRingIdentifier == nil {
            savedRingIdentifier = peripheral.identifier
            ringDisplayName = peripheral.name ?? "COLMI R02 Ring"
        }
        tLog("DEBUG: Connected to peripheral: \(peripheral)")
        peripheral.delegate = self
        tLog("DEBUG: Discovering services...")
        peripheral.discoverServices([
            CBUUID(string: Self.ringServiceUUID),
            CBUUID(string: Self.deviceInfoServiceUUID),
            CBUUID(string: Self.colmiServiceUUID)
        ])
        peripheralConnected = true
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        tLog("Disconnected from peripheral: \(peripheral), error: \(error.debugDescription)")
        peripheralConnected = false
        realTimeHeartRateBPM = nil
        lastRealTimeHRPacketTime = nil
        lastSportRTPacketTime = nil
        sportRTDerivedHR = nil
        sportRTBeatSamples.removeAll()
        realTimeBloodOxygenPercent = nil
        realTimeTemperatureCelsius = nil
        characteristicsDiscovered = false
        confirmedNotifyCharacteristics.removeAll()
        syncOnConnectFired = false
        uartRxCharacteristic = nil
        uartTxCharacteristic = nil
        colmiWriteCharacteristic = nil
        colmiNotifyCharacteristic = nil
        // Reset sensor state directly (no BLE commands — connection is gone).
        sensorState = .idle
        spo2ContinueTimer?.invalidate()
        spo2ContinueTimer = nil
        spotCheckTimeoutTask?.cancel()
        spotCheckTimeoutTask = nil
        awaitingKeepaliveBatteryResponse = false
        stopKeepalive()
        stopPeriodicSync()

        // Auto-reconnect: immediately issue a persistent connect request.
        // CoreBluetooth queues this and will complete it automatically when
        // the peripheral reappears — even from the suspended/background state.
        // This is the iOS-idiomatic pattern for bluetooth-central background mode.
        if savedRingIdentifier != nil {
            tLog("[Reconnect] Unexpected disconnect — issuing persistent reconnect")
            manager.connect(peripheral, options: [
                CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
            ])
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        tLog("[Reconnect] Failed to connect: \(error.debugDescription)")
        // Re-issue a persistent connect — CoreBluetooth will keep trying
        // in the background until the peripheral reappears.
        if savedRingIdentifier != nil {
            tLog("[Reconnect] Re-issuing persistent connect")
            manager.connect(peripheral, options: [
                CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
            ])
        }
    }
}

// MARK: - CBPeripheralDelegate
extension RingSessionManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        tLog("DEBUG: Services discovery callback, error: \(String(describing: error))")
        guard error == nil, let services = peripheral.services else {
            tLog("DEBUG: No services found or error occurred")
            return
        }
        
        tLog("DEBUG: Found \(services.count) services")
        for service in services {
            switch service.uuid {
            case CBUUID(string: Self.ringServiceUUID):
                tLog("DEBUG: Found ring service, discovering characteristics...")
                peripheral.discoverCharacteristics([
                    CBUUID(string: Self.uartRxCharacteristicUUID),
                    CBUUID(string: Self.uartTxCharacteristicUUID)
                ], for: service)
            case CBUUID(string: Self.deviceInfoServiceUUID):
                tLog("DEBUG: Found device info service")
            case CBUUID(string: Self.colmiServiceUUID):
                tLog("DEBUG: Found Colmi Big Data service, discovering characteristics...")
                peripheral.discoverCharacteristics([
                    CBUUID(string: Self.colmiWriteUUID),
                    CBUUID(string: Self.colmiNotifyUUID)
                ], for: service)
            default:
                break
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        tLog("DEBUG: Characteristics discovery callback, error: \(String(describing: error))")
        guard error == nil, let characteristics = service.characteristics else {
            tLog("DEBUG: No characteristics found or error occurred")
            return
        }
        
        tLog("DEBUG: Found \(characteristics.count) characteristics")
        for characteristic in characteristics {
            switch characteristic.uuid {
            case CBUUID(string: Self.uartRxCharacteristicUUID):
                tLog("DEBUG: Found UART RX characteristic")
                self.uartRxCharacteristic = characteristic
            case CBUUID(string: Self.uartTxCharacteristicUUID):
                tLog("DEBUG: Found UART TX characteristic")
                self.uartTxCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            case CBUUID(string: Self.colmiWriteUUID):
                tLog("DEBUG: Found Colmi Big Data write characteristic")
                self.colmiWriteCharacteristic = characteristic
            case CBUUID(string: Self.colmiNotifyUUID):
                tLog("DEBUG: Found Colmi Big Data notify characteristic")
                self.colmiNotifyCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            default:
                tLog("DEBUG: Found other characteristic: \(characteristic.uuid)")
            }
        }
        characteristicsDiscovered = (uartRxCharacteristic != nil && uartTxCharacteristic != nil)
        // syncOnConnect is deferred until notify subscriptions are confirmed
        // in didUpdateNotificationStateFor — otherwise the ring receives
        // commands but has nowhere to deliver responses.
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            tLog("[Notify] Failed to subscribe to \(characteristic.uuid): \(error)")
            return
        }
        tLog("[Notify] Subscribed to \(characteristic.uuid)")
        confirmedNotifyCharacteristics.insert(characteristic.uuid)

        let uartTXConfirmed = confirmedNotifyCharacteristics.contains(CBUUID(string: Self.uartTxCharacteristicUUID))
        if characteristicsDiscovered && uartTXConfirmed && !syncOnConnectFired {
            syncOnConnectFired = true
            syncOnConnect()
            DispatchQueue.main.async { [weak self] in
                self?.onReadyForSettingsQuery?()
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else {
            tLog("Failed to read characteristic value: \(String(describing: error))")
            return
        }
        
        let packet = [UInt8](value)

        if characteristic.uuid == CBUUID(string: Self.colmiNotifyUUID) {
            appendToDebugLog(direction: .received, bytes: packet)
            processBigDataChunk(packet)
            tLog(packet)
            return
        }

        if characteristic.uuid == CBUUID(string: Self.uartTxCharacteristicUUID) {
            appendToDebugLog(direction: .received, bytes: packet)
        }
        
        switch packet[0] {
        case RingSessionManager.CMD_SET_DEVICE_TIME:
            // Response to time sync — byte[1]: 0=success, else error
            if packet.count >= 2 && packet[1] == 0 {
                tLog("[SyncTime] Ring acknowledged time sync OK")
            } else {
                tLog("[SyncTime] Ring time sync response: \(packet.prefix(4).map { String(format: "%02x", $0) }.joined(separator: " "))")
            }
        case RingSessionManager.CMD_BATTERY:
            handleBatteryResponse(packet: packet)
        case RingSessionManager.CMD_READ_HEART_RATE:
            handleHeartRateLogResponse(packet: packet)
        case RingSessionManager.CMD_HR_TIMING_MONITOR:
            handleHRTimingMonitorResponse(packet: packet)
        case Counter.shared.CMD_X:
            tLog("🔥")
        case RingSessionManager.CMD_START_REAL_TIME:
            guard packet.count >= 4 else {
                tLog("Real-time response packet too short: \(packet)")
                break
            }
            guard let readingType = RealTimeReading(rawValue: packet[1]) else {
                tLog("Real-Time Reading - Unknown sub-type: \(packet[1]) – full packet: \(packet)")
                break
            }
            let errorCode = packet[2]

            if errorCode == 0 {
                let readingValue = packet[3]
                let now = Date()

                switch readingType {
                case .heartRate, .realtimeHeartRate:
                    // Stamp every HR packet (including zeros) so the gym
                    // watchdog can distinguish "stream alive but warming up"
                    // from "stream has gone silent".
                    lastRealTimeHRPacketTime = now

                    if readingValue == 0 {
                        // Zero = sensor warmup / no skin contact.
                        // During a workout, nil-out so the gym UI shows the
                        // warmup indicator instead of a frozen stale value.
                        if isWorkoutActive { realTimeHeartRateBPM = nil }
                        break
                    }
                    // Sanity-check: discard physiologically impossible values.
                    // 0xFF (255) is a known firmware artefact; valid resting-to-max
                    // range is roughly 30-220 BPM.  Values like 1-2 bpm are sensor
                    // noise during warmup — not real heart rates.
                    guard readingValue >= 30 && readingValue <= 220 else {
                        tLog("[RealTime] Ignoring out-of-range HR: \(readingValue)")
                        break
                    }

                    // Spot-check: collect readings — don't stop early.
                    // The VC30F PPG sensor's first readings after a cold start
                    // are often elevated (warmup artefact).  We let the full
                    // timeout run and take the median at the end.
                    if spotCheckActive && spotCheckType == .realtimeHeartRate {
                        spotCheckHRReadings.append(Int(readingValue))
                        tLog("[SpotCheck] HR sample \(spotCheckHRReadings.count): \(readingValue) bpm")
                        break
                    }

                    realTimeHeartRateBPM = Int(readingValue)

                    if now.timeIntervalSince(lastInfluxHRWrite) >= currentInfluxWriteInterval {
                        lastInfluxHRWrite = now
                        Task { @MainActor in
                            InfluxDBWriter.shared.writeHeartRates([(bpm: Int(readingValue), time: now)])
                        }
                    }
                case .spo2:
                    tLog("[SpO2] Response on 0x69 — value=\(readingValue) error=\(errorCode) pkt=\(packet.prefix(6).map { String(format: "%02x", $0) }.joined(separator: " "))")
                    guard readingValue >= 70, readingValue <= 100 else {
                        tLog("[SpO2] Discarding out-of-range value: \(readingValue)%")
                        break
                    }
                    realTimeBloodOxygenPercent = Int(readingValue)

                    // Spot-check: got a valid SpO2 reading — write to InfluxDB/HealthKit and stop.
                    if spotCheckActive && spotCheckType == .spo2 {
                        tLog("[SpotCheck] Got SpO2 \(readingValue)% — writing to InfluxDB/HealthKit and stopping stream")
                        lastInfluxSpO2Write = now
                        let percent = Int(readingValue)
                        Task { @MainActor in
                            InfluxDBWriter.shared.writeSpO2(value: Double(percent), time: now)
                            await self.healthHRWriter.writeSpO2(percent: percent, time: now)
                        }
                        finishSpotCheck()
                        break
                    }

                    if now.timeIntervalSince(lastInfluxSpO2Write) >= currentInfluxWriteInterval {
                        lastInfluxSpO2Write = now
                        Task { @MainActor in
                            InfluxDBWriter.shared.writeSpO2(value: Double(readingValue), time: now)
                        }
                    }
                case .temperature:
                    // Temperature uses a 16-bit LE value at bytes[6-7], not byte[3].
                    // byte[3] is always 0 for temperature packets.
                    // Raw 16-bit value / 20.0 = degrees Celsius.
                    // e.g. raw 730 → 730 / 20.0 = 36.5 °C
                    //
                    // The ring sends uncalibrated sensor readings mid-stream
                    // (often 50-57°C) that ramp toward the real value. Only
                    // the final packet — typically sent right after the stop
                    // command — contains the calibrated body temperature.
                    // During a spot-check we therefore let the full timeout
                    // run, then write the last reading if it is in range.
                    guard packet.count >= 8 else { break }
                    let rawTemp = Int(packet[6]) | (Int(packet[7]) << 8)
                    guard rawTemp > 0 else { break }
                    let celsius = Double(rawTemp) / 20.0
                    tLog("[RealTime] Temp raw=\(rawTemp) → \(String(format: "%.1f", celsius))°C")

                    // Stash every reading so the timeout handler can pick
                    // the median of body-range values.
                    spotCheckTempReadings.append(celsius)

                    // For non-spot-check continuous streaming, only surface
                    // calibrated values (35-38°C) to the UI / InfluxDB.
                    guard celsius >= 35.0 && celsius <= 38.0 else { break }
                    realTimeTemperatureCelsius = celsius

                    // During a spot-check, do NOT stop early — let the full
                    // timeout run so the ring can finish calibrating.
                    guard !spotCheckActive else { break }

                    if now.timeIntervalSince(lastInfluxTempWrite) >= currentInfluxWriteInterval {
                        lastInfluxTempWrite = now
                        Task { @MainActor in
                            InfluxDBWriter.shared.writeTemperature(celsius: celsius, time: now)
                        }
                    }
                default:
                    break
                }
                tLog("Real-Time Reading - Type: \(readingType), Value: \(readingValue)")
            } else {
                tLog("Error in reading - Type: \(readingType), Error Code: \(errorCode)")
            }
        case RingSessionManager.CMD_REAL_TIME_HEART_RATE:
            // Response to DataType=6 (realtimeHeartRate) streaming.
            // Packet format: [30, heartRate, 0, ..., checksum]
            let hrValue = packet[1]
            let now = Date()
            lastRealTimeHRPacketTime = now

            if hrValue == 0 {
                if isWorkoutActive { realTimeHeartRateBPM = nil }
                tLog("[RT-HR30] heartRate=0 (warmup)")
            } else if hrValue >= 30 && hrValue <= 220 {
                realTimeHeartRateBPM = Int(hrValue)
                tLog("[RT-HR30] heartRate=\(hrValue)")
                if now.timeIntervalSince(lastInfluxHRWrite) >= currentInfluxWriteInterval {
                    lastInfluxHRWrite = now
                    Task { @MainActor in
                        InfluxDBWriter.shared.writeHeartRates([(bpm: Int(hrValue), time: now)])
                    }
                }
            } else {
                tLog("[RT-HR30] Ignoring out-of-range HR: \(hrValue)")
            }
        case RingSessionManager.CMD_STOP_REAL_TIME:
            // 0x6A serves double duty:
            //   (a) HR auto-stop notification (Pathway B)
            //   (b) Pathway A data response (SpO2 etc.) — packet[1]=DataType, packet[2]=error, packet[3]=value
            if packet.count >= 4, let dataType = RealTimeReading(rawValue: packet[1]), dataType == .spo2 {
                // Pathway A SpO2 data response
                let errorCode = packet[2]
                let value = packet[3]
                tLog("[SpO2] Response on 0x6A — DataType=\(dataType) error=\(errorCode) value=\(value) pkt=\(packet.prefix(6).map { String(format: "%02x", $0) }.joined(separator: " "))")
                if errorCode == 0 && value > 0 && value <= 100 {
                    realTimeBloodOxygenPercent = Int(value)
                }
            } else {
                // HR auto-stop notification
                if isWorkoutActive || isContinuousHRStreamActive {
                    tLog("[RealTime] Ring auto-stopped stream — restarting (\(isWorkoutActive ? "workout" : "continuous"))")
                    startRealTimeStreaming(type: .realtimeHeartRate)
                } else {
                    tLog("[RealTime] Stream stopped (0x6A) — pkt=\(packet.prefix(4).map { String(format: "%02x", $0) }.joined(separator: " "))")
                    realTimeHeartRateBPM = nil
                }
            }
        case RingSessionManager.CMD_PATHWAY_A_STOP:  // 0x6B
            tLog("[SpO2] Stop notification (0x6B) — pkt=\(packet.prefix(4).map { String(format: "%02x", $0) }.joined(separator: " "))")
        case RingSessionManager.CMD_SLEEP_DATA:
            handleSleepDataResponse(packet: packet)
        case RingSessionManager.CMD_SYNC_SLEEP_LEGACY:
            handleSleepResponse(packet: packet)
        case RingSessionManager.CMD_READ_HRV_DATA:
            handleHRVDataResponse(packet: packet)
        case RingSessionManager.CMD_READ_PRESSURE_DATA:
            handlePressureDataResponse(packet: packet)
        case RingSessionManager.CMD_READ_ACTIVITY_DATA:
            handleActivityDataResponse(packet: packet)
        case RingSessionManager.CMD_HRV,
             RingSessionManager.CMD_HEART_RATE_SETTING,
             RingSessionManager.CMD_BLOOD_OXYGEN,
             RingSessionManager.CMD_PRESSURE:
            handleTrackingSettingResponse(packet: packet)
        case RingSessionManager.CMD_SPORT_REAL_TIME:
            handleSportRealTimeResponse(packet: packet)
        case 158: // 0x9E — ack from CMD_REAL_TIME_HEART_RATE (30) continue keepalive (30+128)
            break
        default:
            // Log unhandled opcodes so we can identify sleep/other response formats
            tLog("Unhandled response opcode: \(packet[0]) (0x\(String(format: "%02x", packet[0]))) – full packet: \(packet)")
            break
        }
        
        if characteristic.uuid == CBUUID(string: Self.uartTxCharacteristicUUID) {
            if let value = characteristic.value {
                tLog("Received value: \(value) : \([UInt8](value))")
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            tLog("Write to characteristic failed: \(error.localizedDescription)")
        } else {
            tLog("Write to characteristic successful")
        }
    }
}

// MARK: - BlinkTwice

extension RingSessionManager {
    func sendBlinkTwiceCommand() {
        do {
            let blinkTwicePacket = try makePacket(command: RingSessionManager.CMD_BLINK_TWICE, subData: nil)
            appendToDebugLog(direction: .sent, bytes: blinkTwicePacket)
            sendPacket(packet: blinkTwicePacket)
        } catch {
            tLog("Failed to create blink twice packet: \(error)")
        }
    }
}


// MARK: - Big Data (Colmi service)

extension RingSessionManager {
    static func makeBigDataRequestPacket(dataId: UInt8) -> [UInt8] {
        [
            Self.bigDataMagic,
            dataId,
            0, 0,       // dataLen = 0 (LE)
            0xFF, 0xFF  // crc16 = 0xFFFF (LE)
        ]
    }

    static func parseBigDataResponsePacket(_ packet: [UInt8]) -> (dataId: UInt8, dataLen: Int, crc16: UInt16, payload: [UInt8])? {
        let headerLen = 6
        guard packet.count >= headerLen, packet[0] == Self.bigDataMagic else { return nil }
        let dataId = packet[1]
        let dataLen = Int(packet[2]) | (Int(packet[3]) << 8)
        let crc16 = UInt16(packet[4]) | (UInt16(packet[5]) << 8)
        guard dataLen >= 0, packet.count == headerLen + dataLen else { return nil }
        let payload = Array(packet.dropFirst(headerLen))
        return (dataId: dataId, dataLen: dataLen, crc16: crc16, payload: payload)
    }

    /// Send a Big Data request on the Colmi service. Request: magic 188, dataId, dataLen=0, crc16=0xFFFF.
    func sendBigDataRequest(dataId: UInt8) {
        guard let colmiWriteCharacteristic, let peripheral else {
            tLog("Cannot send Big Data request. Colmi write characteristic or peripheral not ready.")
            return
        }
        let request = Self.makeBigDataRequestPacket(dataId: dataId)
        let data = Data(request)
        peripheral.writeValue(data, for: colmiWriteCharacteristic, type: .withResponse)
        appendToDebugLog(direction: .sent, bytes: request)
        tLog("Big Data request sent – dataId: \(dataId), command: \(request)")
    }

    private func processBigDataChunk(_ chunk: [UInt8]) {
        bigDataBuffer.append(contentsOf: chunk)
        let headerLen = 6
        while bigDataBuffer.count >= 6 {
            guard bigDataBuffer[0] == Self.bigDataMagic else {
                bigDataBuffer.removeFirst()
                continue
            }
            let dataId = bigDataBuffer[1]
            let dataLen = Int(bigDataBuffer[2]) | (Int(bigDataBuffer[3]) << 8)
            let packetLen = headerLen + dataLen
            guard dataLen >= 0, bigDataBuffer.count >= packetLen else { break }

            // CRC16 is little-endian in the Big Data header (currently informational).
            let _ = UInt16(bigDataBuffer[4]) | (UInt16(bigDataBuffer[5]) << 8)
            let payload = Array(bigDataBuffer.dropFirst(headerLen).prefix(dataLen))
            bigDataBuffer.removeFirst(packetLen)
            handleBigDataResponse(dataId: dataId, payload: payload)
        }
    }

    private func handleBigDataResponse(dataId: UInt8, payload: [UInt8]) {
        switch dataId {
        case Self.bigDataSleepId:
            if let sleepData = BigDataSleepParser.parseSleepPayload(payload) {
                tLog("Big Data sleep received – \(sleepData.sleepDays) day(s)")
                bigDataSleepCallback?(sleepData)
                bigDataSleepPersistenceCallback?(sleepData)
            } else {
                tLog("Big Data sleep parse failed – payload length: \(payload.count)")
            }
        case Self.bigDataBloodOxygenId:
            tLog("Big Data blood oxygen received – payload length: \(payload.count)")
            bigDataBloodOxygenPayloadCallback?(payload)
            bigDataBloodOxygenPayloadPersistenceCallback?(payload)
        default:
            tLog("Big Data response – dataId: \(dataId), payload length: \(payload.count)")
        }
    }
}

// MARK: - Keepalive

extension RingSessionManager {
    // MARK: - BLE-event-driven keepalive chain
    //
    // The app sends CMD_BATTERY → ring responds → didUpdateValueFor wakes the
    // app (even from background) → handleBatteryResponse fires a spot-check
    // and schedules the next ping.  This forms a self-sustaining chain that
    // keeps InfluxDB fed ~1/min even when the phone is locked.

    func startKeepalive() {
        stopKeepalive()
        keepalivePingCount = 0
        // First ping after the full keepalive interval.  syncOnConnect has
        // already fired a spot-check, so there's no rush.
        scheduleNextKeepalive()
    }

    func stopKeepalive() {
        keepaliveWorkItem?.cancel()
        keepaliveWorkItem = nil
    }

    private func scheduleNextKeepalive(delay: TimeInterval? = nil) {
        let delay = delay ?? Self.keepaliveInterval
        keepaliveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.sendKeepalive()
        }
        keepaliveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func sendKeepalive() {
        keepaliveWorkItem = nil
        guard peripheralConnected, characteristicsDiscovered else { return }

        // During a workout or continuous stream the real-time HR stream is
        // running.  Sending CMD_BATTERY mid-stream appears to disrupt the
        // PPG sensor pipeline on the R02 firmware, causing the stream to
        // die silently.  Skip the battery read and reschedule.
        if sensorState == .workout || sensorState == .continuousHR {
            tLog("[Keepalive] Active stream — skipping battery read, rescheduling")
            scheduleNextKeepalive()
            return
        }

        tLog("[Keepalive] Sending battery ping #\(keepalivePingCount + 1)")
        lastKeepaliveSentAt = Date()
        awaitingKeepaliveBatteryResponse = true
        do {
            let packet = try makePacket(command: Self.CMD_BATTERY)
            appendToDebugLog(direction: .sent, bytes: packet)
            sendPacket(packet: packet)
        } catch {
            tLog("[Keepalive] Packet failed: \(error)")
            awaitingKeepaliveBatteryResponse = false
        }
        // Don't schedule next here — handleBatteryResponse will do it when
        // the ring responds, keeping the chain BLE-event-driven.
        // Safety net: if the ring doesn't respond within 30 s, retry.
        let fallback = DispatchWorkItem { [weak self] in
            guard let self, self.keepaliveWorkItem == nil else { return }
            tLog("[Keepalive] No battery response in 30s — retrying")
            self.sendKeepalive()
        }
        keepaliveWorkItem = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: fallback)
    }
}

// MARK: - Sync on connect

extension RingSessionManager {
    /// Runs when the app has connected to the ring and discovered characteristics. Requests battery, sleep (Big Data), and heart rate log with staggered delays.
    func syncOnConnect() {
        tLog("Sync on connect: starting…")

        // If a gym workout is in progress, the disconnect killed the HR stream
        // but GymSessionManager still considers itself .active.  Restore the
        // sensor state to .workout and restart the real-time HR stream after
        // a brief BLE settle delay instead of running the normal stop-all /
        // spot-check flow.
        if gymWorkoutInProgress {
            tLog("[SyncOnConnect] Workout active on reconnect — restoring workout mode")
            sensorState = .workout
            getBatteryStatus { _ in }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.gymWorkoutInProgress else { return }
                self.sendRealTimeStart(type: .realtimeHeartRate)
                tLog("[SyncOnConnect] Workout HR stream restarted")
            }
            return
        }

        // Set the ring's clock FIRST — without a valid time the ring can't
        // bucket activity, HR log, sleep, or HRV data into correct day slots.
        // The firmware resets on its midnight reboot, so we re-sync every connect.
        syncDeviceTime()

        // Kill any leftover real-time streams from a previous session.
        // The ring may still be streaming SpO2/HR/temp if the app was
        // backgrounded or disconnected without sending a stop command.
        // Use raw BLE commands — the app state is already .idle from disconnect.
        tLog("[SyncOnConnect] Sending stop commands to clear stale streams")
        sendSpO2Stop()
        sendRealTimeStop(type: .realtimeHeartRate)
        sendRealTimeStop(type: .temperature)

        getBatteryStatus { _ in }
        // Safety net: if battery response is lost in the post-restore data flood,
        // retry once after 5s so the UI doesn't stay stuck on "--% Connect ring".
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self, self.currentBatteryInfo == nil else { return }
            tLog("[SyncOnConnect] Battery still nil after 5s — retrying")
            self.getBatteryStatus { _ in }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            // Skip if a workout started while we were waiting — BLE sync
            // commands flood the channel and disrupt the real-time HR stream.
            guard !self.isWorkoutActive else {
                tLog("[SyncOnConnect] Workout active — skipping sleep sync")
                return
            }
            self.syncSleep(dayOffset: 0)
        }
        // Fetch a full week of HR logs (days 0–6) so the week view is populated.
        // Each request is enqueued; BLE responses are serialised by the ring.
        for day in 0...6 {
            let delay = 1.2 + Double(day) * 0.6
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.isWorkoutActive else {
                    if day == 0 { tLog("[SyncOnConnect] Workout active — skipping HR log sync") }
                    return
                }
                self.getHeartRateLog(dayOffset: day) { _ in }
            }
        }
        // Other metrics start after HR logs (7 × 0.6 = 4.2s offset from 1.2 base = 5.4s)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.4) { [weak self] in
            guard let self, !self.isWorkoutActive else { return }
            self.syncHRVData(dayOffset: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            guard let self, !self.isWorkoutActive else { return }
            self.syncBloodOxygen(dayOffset: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.6) { [weak self] in
            guard let self, !self.isWorkoutActive else { return }
            self.syncPressureData(dayOffset: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.2) { [weak self] in
            guard let self, !self.isWorkoutActive else { return }
            self.syncActivityData(dayOffset: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.8) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.ensureHRLogSettings()
            }
        }
    }

    /// Read HR log settings from ring; if disabled or interval doesn't match the user's saved
    /// preference, write the preferred settings. This ensures HR logging survives ring reboots.
    /// After configuring, starts a periodic sync timer at the same interval.
    private func ensureHRLogSettings() async {
        let savedInterval = UserDefaults.standard.object(forKey: "hrLogInterval") as? Int ?? 1
        let ringSettings = try? await readHRLogSettings()
        tLog("[SyncOnConnect] HR log settings: enabled=\(ringSettings?.enabled ?? false), interval=\(ringSettings?.intervalMinutes ?? 0)min")

        let needsWrite = ringSettings == nil
            || !ringSettings!.enabled
            || ringSettings!.intervalMinutes != savedInterval

        if needsWrite {
            tLog("[SyncOnConnect] Writing HR log settings: enabled=true, interval=\(savedInterval)min")
            do {
                try await writeTrackingSetting(.heartRate, enabled: true)
                try await writeHRLogSettings(enabled: true, intervalMinutes: savedInterval)
                tLog("[SyncOnConnect] HR log settings written successfully")
            } catch {
                tLog("[SyncOnConnect] Failed to write HR log settings: \(error)")
            }
        }

        // Ensure autonomous blood oxygen monitoring is enabled on the ring.
        do {
            let spo2Enabled = try await readTrackingSetting(.bloodOxygen)
            if !spo2Enabled {
                tLog("[SyncOnConnect] Blood oxygen tracking disabled — enabling")
                try await writeTrackingSetting(.bloodOxygen, enabled: true)
                tLog("[SyncOnConnect] Blood oxygen tracking enabled")
            } else {
                tLog("[SyncOnConnect] Blood oxygen tracking already enabled")
            }
        } catch {
            tLog("[SyncOnConnect] Blood oxygen tracking check failed: \(error)")
        }

        startPeriodicSync(intervalMinutes: savedInterval)

        // After connect, start with SpO2 spot-check first (60s window),
        // then HR, then temperature — so we can verify real-time SpO2 works.
        if sensorState == .idle {
            tLog("[SyncOnConnect] Running SpO2 spot-check (60s window)")
            startSpotCheck(type: .spo2)
        } else {
            tLog("[SyncOnConnect] Sensor already in \(sensorState) — skipping spot-check")
        }

        // After SpO2 finishes (up to 60s), run HR spot-check for fresh reading.
        DispatchQueue.main.asyncAfter(deadline: .now() + 65) { [weak self] in
            guard let self, self.peripheralConnected, self.sensorState == .idle else { return }
            tLog("[SyncOnConnect] Running HR spot-check")
            self.startSpotCheck(type: .realtimeHeartRate)
        }

        // Then temperature spot-check after HR.
        DispatchQueue.main.asyncAfter(deadline: .now() + 100) { [weak self] in
            guard let self, self.peripheralConnected, self.sensorState == .idle,
                  self.realTimeTemperatureCelsius == nil else { return }
            tLog("[SyncOnConnect] Running temperature spot-check")
            self.startSpotCheck(type: .temperature)
        }

        // Start the keepalive chain now that the initial sync is done.
        // The first ping fires after the full keepalive interval (60 s),
        // giving the spot-check above time to finish without overlap.
        startKeepalive()
    }

    /// Start a repeating timer that re-fetches HR log (and other metrics) from the ring.
    private func startPeriodicSync(intervalMinutes: Int) {
        stopPeriodicSync()
        let interval = TimeInterval(max(intervalMinutes, 1) * 60)
        tLog("[PeriodicSync] Starting periodic sync every \(intervalMinutes) min")
        periodicSyncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runPeriodicSync()
            }
        }
    }

    private func stopPeriodicSync() {
        periodicSyncTimer?.invalidate()
        periodicSyncTimer = nil
    }

    /// Foreground-only fallback sync.  The BLE keepalive chain handles background
    /// spot-checks; this Timer-based sync covers the case where the chain stalls
    /// while the app is in the foreground (e.g. during long idle periods).
    private func runPeriodicSync() {
        guard peripheralConnected, characteristicsDiscovered else { return }

        if sensorState == .workout || sensorState == .continuousHR {
            tLog("[PeriodicSync] Active stream — skipping entirely")
            return
        }

        tLog("[PeriodicSync] Foreground fallback sync")

        if sensorState == .idle {
            startSpotCheck()
        }

        getHeartRateLog(dayOffset: 0) { _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.getHeartRateLog(dayOffset: 1) { _ in }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.syncHRVData(dayOffset: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            self?.syncBloodOxygen(dayOffset: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            self?.syncPressureData(dayOffset: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.syncActivityData(dayOffset: 0)
        }

        // Re-check HR log settings — the ring firmware resets them on its own
        // midnight reboot, so we need to periodically re-apply.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.ensureHRLogSettings()
            }
        }
    }
}

// MARK: - Sleep sync

extension RingSessionManager {
    /// Request sleep data via Colmi Big Data service (dataId 39). Preferred for rings that support it.
    func syncSleep(dayOffset: Int = 0) {
        lastSleepDayOffset = dayOffset
        sendBigDataRequest(dataId: Self.bigDataSleepId)
    }

    /// Request sleep from Nordic UART Commands protocol (ID 68). Use if Big Data sleep is not supported.
    func syncSleepCommands(dayOffset: Int = 0) {
        do {
            let packet = try makePacket(command: Self.CMD_SLEEP_DATA, subData: [
                UInt8(dayOffset & 0xFF),
                15,
                0,
                95
            ])
            lastSleepDayOffset = dayOffset
            appendToDebugLog(direction: .sent, bytes: packet)
            sendPacket(packet: packet)
            tLog("Sleep data requested (Commands 68, dayOffset: \(dayOffset))")
        } catch {
            tLog("Failed to create sleep packet: \(error)")
        }
    }

    /// Legacy: request sleep via Big Data style 0xBC 0x27 on Nordic UART (use for firmware that doesn’t support command 68).
    func syncSleepLegacy() {
        do {
            let packet = try makePacket(command: Self.CMD_SYNC_SLEEP_LEGACY, subData: [0x27])
            appendToDebugLog(direction: .sent, bytes: packet)
            sendPacket(packet: packet)
            tLog("Sleep sync (legacy 0xBC 0x27) requested")
        } catch {
            tLog("Failed to create legacy sleep packet: \(error)")
        }
    }

    private func handleSleepDataResponse(packet: [UInt8]) {
        // SleepDataResponse: commandId=68, year, month, day, time, sleepQualities, unused[3], crc
        guard packet.count >= 6, packet[0] == Self.CMD_SLEEP_DATA else { return }
        let year = Int(packet[1])
        let month = Int(packet[2])
        let day = Int(packet[3])
        let time = packet[4]
        let sleepQualities = packet[5]
        let data = SleepData(
            year: year,
            month: month,
            day: day,
            time: time,
            sleepQualities: sleepQualities,
            dayOffset: lastSleepDayOffset
        )
        tLog("Sleep data received – date: \(year + 2000)-\(month)-\(day), time: \(time), qualities: \(sleepQualities)")
        sleepDataCallback?(data)
    }

    private func handleSleepResponse(packet: [UInt8]) {
        guard packet.count >= 2 else { return }
        let subType = packet[1]
        tLog("Sleep packet (legacy 0xBC) – subType: \(subType) (0x\(String(format: "%02x", subType))), full: \(packet)")
        sleepPacketCallback?(packet)
        if subType == 255 {
            tLog("Sleep: no data (ring returned 0xFF subtype)")
        }
    }

    /// Request HRV historical data (Commands protocol, ID 57). dayOffset uses index field.
    func syncHRVData(dayOffset: Int = 0) {
        do {
            let packet = try makePacket(command: Self.CMD_READ_HRV_DATA, subData: [UInt8(dayOffset & 0xFF)])
            appendToDebugLog(direction: .sent, bytes: packet)
            sendPacket(packet: packet)
            tLog("HRV data requested (Commands 57, dayOffset/index: \(dayOffset))")
        } catch {
            tLog("Failed to create HRV packet: \(error)")
        }
    }

    /// Request pressure/stress historical data (Commands protocol, ID 55). dayOffset uses index field.
    func syncPressureData(dayOffset: Int = 0) {
        do {
            let packet = try makePacket(command: Self.CMD_READ_PRESSURE_DATA, subData: [UInt8(dayOffset & 0xFF)])
            appendToDebugLog(direction: .sent, bytes: packet)
            sendPacket(packet: packet)
            tLog("Pressure data requested (Commands 55, dayOffset/index: \(dayOffset))")
        } catch {
            tLog("Failed to create pressure packet: \(error)")
        }
    }

    // MARK: - Device Time Sync

    /// Convert a decimal value to BCD (Binary-Coded Decimal).
    /// e.g. 26 → 0x26 (0010_0110), 3 → 0x03, 59 → 0x59.
    private static func toBCD(_ value: Int) -> UInt8 {
        let tens = (value / 10) & 0x0F
        let ones = (value % 10) & 0x0F
        return UInt8((tens << 4) | ones)
    }

    /// Sync the ring's clock to the phone's current UTC time.
    /// The ring uses this clock to timestamp HR logs, activity/step data, and sleep.
    /// Without a valid clock, the ring returns 0xFF (no data) for historical queries.
    ///
    /// Packet format (CMD 0x01): [year-2000, month, day, hour, minute, second, language]
    /// All time fields are BCD-encoded. Language: 1 = English, 0 = Chinese.
    func syncDeviceTime() {
        let now = Date()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)

        let year = (comps.year ?? 2026) - 2000
        let month = comps.month ?? 1
        let day = comps.day ?? 1
        let hour = comps.hour ?? 0
        let minute = comps.minute ?? 0
        let second = comps.second ?? 0

        do {
            let packet = try makePacket(command: Self.CMD_SET_DEVICE_TIME, subData: [
                Self.toBCD(year),
                Self.toBCD(month),
                Self.toBCD(day),
                Self.toBCD(hour),
                Self.toBCD(minute),
                Self.toBCD(second),
                0x01  // language: English
            ])
            sendPacket(packet: packet)
            tLog("[SyncTime] Sent device time: \(String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", year + 2000, month, day, hour, minute, second))")
        } catch {
            tLog("[SyncTime] Failed to create time packet: \(error)")
        }
    }

    /// Request activity data (steps/calories/distance) via CMD_GET_STEP_SOMEDAY (0x43 / 67).
    /// Sub-data: [dayOffset, 0x0F, 0x00, 0x5F, 0x01]  (matches Python colmi_r02_client).
    ///
    /// The ring stores activity in UTC days.  When the local timezone is behind
    /// UTC, "today local" spans two UTC days.  For dayOffset 0 we automatically
    /// also fetch dayOffset 1 (yesterday UTC) so the full local day is covered.
    func syncActivityData(dayOffset: Int = 0) {
        sendActivityRequest(dayOffset: dayOffset)
        // When fetching "today" (offset 0), also fetch "yesterday UTC" so that
        // the earlier part of "today local" is included.
        if dayOffset == 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.sendActivityRequest(dayOffset: 1)
            }
        }
    }

    private func sendActivityRequest(dayOffset: Int) {
        do {
            let packet = try makePacket(command: Self.CMD_READ_ACTIVITY_DATA, subData: [
                UInt8(dayOffset & 0xFF),
                0x0F,
                0x00,
                0x5F,
                0x01
            ])
            appendToDebugLog(direction: .sent, bytes: packet)
            sendPacket(packet: packet)
            tLog("Activity data requested (CMD 0x43, dayOffset: \(dayOffset))")
        } catch {
            tLog("Failed to create activity packet: \(error)")
        }
    }

    /// Request blood oxygen historical data via Big Data (dataId 42).
    func syncBloodOxygen(dayOffset: Int = 0) {
        _ = dayOffset // dataId 42 request itself does not include dayOffset in request header.
        sendBigDataRequest(dataId: Self.bigDataBloodOxygenId)
    }

    private func handleHRVDataResponse(packet: [UInt8]) {
        guard packet.count >= 2 else { return }
        hrvDataPacketCallback?(packet)
        hrvDataPacketPersistenceCallback?(packet)
    }

    private func handlePressureDataResponse(packet: [UInt8]) {
        guard packet.count >= 2 else { return }
        pressureDataPacketCallback?(packet)
        pressureDataPacketPersistenceCallback?(packet)
    }

    private func handleActivityDataResponse(packet: [UInt8]) {
        guard packet.count >= 2 else { return }
        activityDataPacketCallback?(packet)
        activityDataPacketPersistenceCallback?(packet)
    }
    
    func sendPacket(packet: [UInt8]) {
        guard let uartRxCharacteristic, let peripheral else {
            tLog("Cannot send packet. Peripheral or characteristic not ready.")
            return
        }
        
        let data = Data(packet)
        peripheral.writeValue(data, for: uartRxCharacteristic, type: .withResponse)
    }
}

// MARK: - Sport Real-Time Telemetry (0x73)

extension RingSessionManager {
    /// Handle sport real-time packets (command 115 / 0x73).
    /// These arrive autonomously when the ring's firmware detects exercise.
    /// Packet layout (observed):
    ///   [0]    = 115 (command)
    ///   [1]    = 18  (sub-type / flags — constant so far)
    ///   [2]    = 0
    ///   [3]    = 0
    ///   [4]    = cumulative counter (wraps at 256, ~steps or activity ticks)
    ///   [5]    = 0
    ///   [6]    = slow counter (increments ~1 per 3 packets)
    ///   [7]    = fast counter (increments ~58 per packet, wraps at 256)
    ///   [8]    = 0
    ///   [9]    = 0 (was 4 in earlier captures — possibly sport type)
    ///   [10]   = possible cumulative heartbeat counter (HYPOTHESIS — under test)
    ///   [11..14] = 0
    ///   [15]   = checksum
    ///
    /// HYPOTHESIS: byte[10] is a cumulative heartbeat counter.  In a captured
    /// 18-second session it incremented at ~60/min, which is a plausible resting
    /// HR.  We derive an estimated HR via a sliding window over the last 10 s
    /// and expose it as `sportRTDerivedHR` so GymSessionManager can use it when
    /// the 0x69 HR stream is displaced.
    func handleSportRealTimeResponse(packet: [UInt8]) {
        guard packet.count >= 11 else { return }
        let now = Date()
        lastSportRTPacketTime = now

        let b4  = packet[4]
        let b10 = packet[10]

        // ── Sliding-window HR from byte[10] ──────────────────────────
        sportRTBeatSamples.append((time: now, b10: b10))

        // Trim samples older than the window
        let cutoff = now.addingTimeInterval(-sportRTWindowSeconds)
        sportRTBeatSamples.removeAll { $0.time < cutoff }

        if let first = sportRTBeatSamples.first, sportRTBeatSamples.count >= 3 {
            let elapsed = now.timeIntervalSince(first.time)
            if elapsed >= 3.0 {
                // Unwrap the counter (it's UInt8, wraps at 256)
                var totalBeats = 0
                for i in 1 ..< sportRTBeatSamples.count {
                    var delta = Int(sportRTBeatSamples[i].b10) - Int(sportRTBeatSamples[i - 1].b10)
                    if delta < 0 { delta += 256 }  // handle wrap
                    totalBeats += delta
                }
                let derivedBPM = Int(round(Double(totalBeats) * 60.0 / elapsed))
                // Sanity: only accept 30-220 BPM
                if derivedBPM >= 30 && derivedBPM <= 220 {
                    sportRTDerivedHR = derivedBPM
                } else {
                    sportRTDerivedHR = nil
                }
            }
        }

        tLog("[SportRT] b4=\(b4) b10=\(b10) derivedHR=\(sportRTDerivedHR.map(String.init) ?? "nil") samples=\(sportRTBeatSamples.count) pkt=\(packet.prefix(11).map { String($0) }.joined(separator: ","))")
    }
}

// MARK: - PPG Sensor State Machine

extension RingSessionManager {

    // MARK: Transition

    /// Centralized state transition.  Tears down the current sensor mode,
    /// then sets up the new one.  All mutual-exclusion logic lives here.
    private func transitionSensor(to newState: SensorState) {
        let old = sensorState
        guard old != newState else { return }

        // --- Teardown current state ---
        switch old {
        case .idle:
            break
        case .spotCheck(let type):
            spotCheckTimeoutTask?.cancel()
            spotCheckTimeoutTask = nil
            spotCheckTempReadings.removeAll()
            spotCheckHRReadings.removeAll()
            if type == .spo2 {
                sendSpO2Stop()
            } else {
                sendRealTimeStop(type: type)
            }
        case .continuousHR:
            sendRealTimeStop(type: .realtimeHeartRate)
        case .spo2Stream:
            spo2ContinueTimer?.invalidate()
            spo2ContinueTimer = nil
            sendSpO2Stop()
        case .workout:
            sendRealTimeStop(type: .realtimeHeartRate)
        }

        sensorState = newState

        // --- Setup new state ---
        switch newState {
        case .idle:
            break
        case .spotCheck(let type):
            spotCheckTempReadings.removeAll()
            spotCheckHRReadings.removeAll()
            if type == .spo2 {
                sendSpO2Start()
                startSpO2ContinueTimer()
            } else {
                sendRealTimeStart(type: type)
            }
            startSpotCheckTimeout(type: type)
        case .continuousHR:
            sendRealTimeStart(type: .realtimeHeartRate)
        case .spo2Stream:
            sendSpO2Start()
            startSpO2ContinueTimer()
        case .workout:
            sendRealTimeStart(type: .realtimeHeartRate)
        }

        tLog("[Sensor] \(old) → \(newState)")
    }

    // MARK: Public API

    /// Send a command-30 "continue" keepalive to tell the ring to keep
    /// the PPG sensor running.  The Colmi protocol docs say the request
    /// type field is "only set to 3 in app".
    func sendRealtimeHRContinue() {
        guard peripheralConnected, characteristicsDiscovered else { return }
        do {
            let packet = try makePacket(command: Self.CMD_REAL_TIME_HEART_RATE, subData: [3])
            appendToDebugLog(direction: .sent, bytes: packet)
            sendPacket(packet: packet)
            tLog("[RT-HR30] Sent continue keepalive")
        } catch {
            tLog("[RT-HR30] Continue packet failed: \(error)")
        }
    }

    /// Toggle continuous real-time HR streaming from the home screen.
    func toggleContinuousHRStream() {
        guard !isWorkoutActive else {
            tLog("[ContinuousHR] Ignored — workout is active")
            return
        }
        if isContinuousHRStreamActive {
            transitionSensor(to: .idle)
        } else {
            transitionSensor(to: .continuousHR)
        }
    }

    /// Start continuous SpO2 streaming (with 2s continue keepalives).
    func startSpO2Streaming() {
        transitionSensor(to: .spo2Stream)
    }

    /// Stop SpO2 streaming.
    func stopSpO2Streaming() {
        if isSpO2StreamActive {
            transitionSensor(to: .idle)
        }
    }

    /// Start a real-time stream (used by GymSessionManager watchdog restart).
    func startRealTimeStreaming(type: RealTimeReading) {
        tLog("[RealTime] START \(type)")
        sendRealTimeStart(type: type)
    }

    func continueRealTimeStreaming(type: RealTimeReading) {
        tLog("[RealTime] CONTINUE \(type)")
        sendRealTimeCommand(command: RingSessionManager.CMD_START_REAL_TIME, type: type, action: .continue)
    }

    /// Stop a real-time stream.  Called by GymSessionManager on workout end
    /// and by the spot-check completion path.
    func stopRealTimeStreaming(type: RealTimeReading) {
        tLog("[RealTime] STOP \(type)")
        realTimeHeartRateBPM = nil
        sendRealTimeStop(type: type)
    }

    /// Enter workout mode.  Called by GymSessionManager.startWorkout().
    func enterWorkoutMode() {
        gymWorkoutInProgress = true
        transitionSensor(to: .workout)
    }

    /// Exit workout mode.  Called by GymSessionManager.stopWorkout().
    func exitWorkoutMode() {
        gymWorkoutInProgress = false
        if isWorkoutActive {
            transitionSensor(to: .idle)
        }
    }

    /// Start a brief spot-check measurement.  The stream auto-stops when
    /// the first valid reading arrives, or after a safety timeout.
    func startSpotCheck(type: RealTimeReading = .realtimeHeartRate) {
        guard sensorState == .idle else {
            tLog("[SpotCheck] Skipping \(type) — sensor busy (\(sensorState))")
            scheduleNextKeepalive()
            return
        }
        transitionSensor(to: .spotCheck(type))
    }

    /// Called by the spot-check packet handler when a valid reading arrives.
    /// Transitions back to idle and resumes the keepalive chain.
    func finishSpotCheck() {
        guard spotCheckActive else { return }
        spotCheckTimeoutTask?.cancel()
        spotCheckTimeoutTask = nil
        let wasType = spotCheckType
        // Teardown via transition, but avoid sending a redundant stop for
        // the stream we already got a final reading from.  The transition
        // teardown will handle the BLE stop command.
        sensorState = .idle
        if wasType == .spo2 {
            spo2ContinueTimer?.invalidate()
            spo2ContinueTimer = nil
            sendSpO2Stop()
        } else {
            sendRealTimeStop(type: wasType)
        }
        tLog("[Sensor] spotCheck(\(wasType)) → idle (spot-check finished)")
        scheduleNextKeepalive()
    }

    // MARK: Raw BLE command helpers

    /// Send a 0x69 start command (does NOT update sensorState).
    private func sendRealTimeStart(type: RealTimeReading) {
        sendRealTimeCommand(command: RingSessionManager.CMD_START_REAL_TIME, type: type, action: .start)
    }

    /// Send a 0x6A stop command (does NOT update sensorState).
    private func sendRealTimeStop(type: RealTimeReading) {
        sendRealTimeCommand(command: RingSessionManager.CMD_STOP_REAL_TIME, type: type, action: nil)
    }

    /// Send an SpO2 start via 0x69 (does NOT update sensorState).
    private func sendSpO2Start() {
        tLog("[SpO2] START — sending 0x69 DataType=3 Action=Start")
        sendSpO2Packet(payload: [RealTimeReading.spo2.rawValue, Action.start.rawValue])
    }

    /// Send an SpO2 stop via 0x6A (does NOT update sensorState).
    private func sendSpO2Stop() {
        tLog("[SpO2] STOP")
        guard let uartRxCharacteristic, let peripheral else { return }
        do {
            let packet = try makePacket(command: Self.CMD_STOP_REAL_TIME, subData: [RealTimeReading.spo2.rawValue])
            let hex = packet.map { String(format: "%02x", $0) }.joined(separator: " ")
            tLog("[SpO2] Stop packet (0x6A): \(hex)")
            peripheral.writeValue(Data(packet), for: uartRxCharacteristic, type: .withResponse)
        } catch {
            tLog("[SpO2] Stop packet failed: \(error)")
        }
    }

    /// Start the SpO2 2-second continue keepalive timer.
    private func startSpO2ContinueTimer() {
        spo2ContinueTimer?.invalidate()
        spo2ContinueTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, self.isSpO2StreamActive else { return }
            self.sendSpO2Continue()
        }
    }

    /// Start the spot-check safety timeout.
    private func startSpotCheckTimeout(type: RealTimeReading) {
        let timeoutSeconds: UInt64
        switch type {
        case .spo2:         timeoutSeconds = 60
        case .temperature:  timeoutSeconds = 20
        case .realtimeHeartRate, .heartRate:
            // The VC30F PPG needs 45-60s to settle from warmup.
            // With median-based collection, longer = more accurate.
            timeoutSeconds = 60
        default:            timeoutSeconds = 30
        }
        spotCheckTimeoutTask?.cancel()
        spotCheckTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
            guard let self, !Task.isCancelled, self.spotCheckActive else { return }

            // VC30F PPG ground truth: the sensor needs warmup time
            // after every cold start.  Early readings are artefacts.
            // Take the last 5 readings — the sensor converges toward
            // the true value over time, so the final samples are the
            // most accurate.  Median of 5 gives noise protection.
            //
            // Temperature additionally filters to body range (35-38°C)
            // because the raw sensor swings wildly (27-57°C).
            if type == .temperature {
                let allReadings = self.spotCheckTempReadings
                self.spotCheckTempReadings.removeAll()
                let tail = Array(allReadings.suffix(5))
                let inRange = tail.filter { $0 >= 35.0 && $0 <= 38.0 }

                if inRange.isEmpty {
                    let lastStr = allReadings.last.map { String(format: "%.1f", $0) } ?? "none"
                    tLog("[SpotCheck] Temp timeout — 0 in-range from last \(tail.count)/\(allReadings.count) readings (last: \(lastStr)°C), discarding")
                } else {
                    let sorted = inRange.sorted()
                    let median = sorted[sorted.count / 2]
                    tLog("[SpotCheck] Temp timeout — median \(String(format: "%.1f", median))°C from \(inRange.count) in-range of last \(tail.count)/\(allReadings.count) readings")
                    let now = Date()
                    self.lastInfluxTempWrite = now
                    self.realTimeTemperatureCelsius = median
                    Task { @MainActor in
                        InfluxDBWriter.shared.writeTemperature(celsius: median, time: now)
                        await self.healthHRWriter.writeTemperature(celsius: median, time: now)
                    }
                }
            } else if type == .realtimeHeartRate || type == .heartRate {
                // HR spot-check: take the median of the LAST 5 readings.
                // The VC30F PPG sensor needs ~45-60s to settle from warmup;
                // the final readings are the most converged toward the true
                // resting value.  Median of 5 gives noise protection without
                // pulling in the warmup plateau.
                let allReadings = self.spotCheckHRReadings
                self.spotCheckHRReadings.removeAll()

                if allReadings.isEmpty {
                    tLog("[SpotCheck] HR timeout — no valid readings in \(timeoutSeconds)s")
                } else {
                    let tail = Array(allReadings.suffix(5))
                    let sorted = tail.sorted()
                    let median = sorted[sorted.count / 2]
                    tLog("[SpotCheck] HR timeout — median \(median) bpm from last \(tail.count)/\(allReadings.count) readings (tail range \(sorted.first!)–\(sorted.last!)), all samples: \(allReadings)")
                    let now = Date()
                    self.lastInfluxHRWrite = now
                    self.realTimeHeartRateBPM = median
                    Task { @MainActor in
                        InfluxDBWriter.shared.writeHeartRates([(bpm: median, time: now)])
                        await self.healthHRWriter.writeHeartRate(bpm: median, time: now)
                    }
                }
            } else if type == .spo2 {
                tLog("[SpotCheck] SpO2 timeout — no valid reading received in \(timeoutSeconds)s")
            } else {
                tLog("[SpotCheck] Timeout — stopping \(type) stream without a valid reading")
            }

            self.transitionSensor(to: .idle)
            self.scheduleNextKeepalive()
        }
    }

    private func sendRealTimeCommand(command: UInt8, type: RealTimeReading, action: Action?) {
        guard let uartRxCharacteristic, let peripheral else {
            tLog("Cannot send real-time command. Peripheral or characteristic not ready.")
            return
        }

        var packetData: [UInt8] = [type.rawValue]
        if let action = action {
            packetData.append(action.rawValue)
        } else {
            packetData.append(contentsOf: [0, 0])
        }

        do {
            let packet = try makePacket(command: command, subData: packetData)
            let data = Data(packet)
            peripheral.writeValue(data, for: uartRxCharacteristic, type: .withResponse)
        } catch {
            tLog("Failed to create packet: \(error)")
        }
    }

    private func sendSpO2Continue() {
        sendSpO2Packet(payload: [RealTimeReading.spo2.rawValue, Action.continue.rawValue])
    }

    private func sendSpO2Packet(payload: [UInt8]) {
        guard let uartRxCharacteristic, let peripheral else {
            tLog("[SpO2] Not connected")
            return
        }
        do {
            let packet = try makePacket(command: Self.CMD_START_REAL_TIME, subData: payload)
            let hex = packet.map { String(format: "%02x", $0) }.joined(separator: " ")
            tLog("[SpO2] Sending: \(hex)")
            peripheral.writeValue(Data(packet), for: uartRxCharacteristic, type: .withResponse)
        } catch {
            tLog("[SpO2] Packet failed: \(error)")
        }
    }
}

// MARK: - Battery Status

extension RingSessionManager {
    func getBatteryStatus(completion: @escaping (BatteryInfo) -> Void) {
        guard let uartRxCharacteristic, let peripheral else {
            tLog("Cannot send battery request. Peripheral or characteristic not ready.")
            return
        }
        
        do {
            let packet = try makePacket(command: RingSessionManager.CMD_BATTERY)
            let data = Data(packet)
            peripheral.writeValue(data, for: uartRxCharacteristic, type: .withResponse)
            
            // Store completion handler to call when data is received
            self.batteryStatusCallback = completion
        } catch {
            tLog("Failed to create battery packet: \(error)")
        }
    }
    
    private func handleBatteryResponse(packet: [UInt8]) {
        guard packet[0] == RingSessionManager.CMD_BATTERY else {
            tLog("Invalid battery packet received.")
            return
        }

        let batteryLevel = Int(packet[1])
        let charging = packet[2] != 0
        let batteryInfo = BatteryInfo(batteryLevel: batteryLevel, charging: charging)
        currentBatteryInfo = batteryInfo

        // Trigger stored callback with battery info
        batteryStatusCallback?(batteryInfo)
        batteryStatusCallback = nil

        // --- BLE-event-driven chain ---
        // Only drive the keepalive chain if this response is from a keepalive
        // battery ping.  Battery reads from syncOnConnect / getBatteryStatus
        // must NOT trigger spot-checks or reschedule the chain — that caused
        // duplicate responses to pile up (every ~10 s instead of 60 s).
        //
        // However, if the chain appears stalled (no keepalive sent in 2× the
        // expected interval), any battery response restarts it. This handles
        // iOS suspending the app and killing the DispatchQueue timer.
        if !awaitingKeepaliveBatteryResponse {
            let stalledSeconds = Date().timeIntervalSince(lastKeepaliveSentAt)
            if stalledSeconds > Self.keepaliveInterval * 2 && !spotCheckActive {
                tLog("[Keepalive] Chain stalled for \(Int(stalledSeconds))s — restarting from unsolicited battery response")
                lastKeepaliveSentAt = Date() // prevent re-trigger on next battery packet
                // Fall through to drive the chain as if this were a keepalive response.
            } else {
                return
            }
        }
        awaitingKeepaliveBatteryResponse = false

        keepalivePingCount += 1

        // Spot-check rotation: only start when sensor is idle.
        // SpO2 every 10th ping (~10 min) with a 60s window; temperature every
        // 3rd non-SpO2 ping; everything else is HR.
        if sensorState == .idle {
            let type: RealTimeReading
            if keepalivePingCount % 10 == 0 && keepalivePingCount > 0 {
                type = .spo2
            } else if keepalivePingCount % 3 == 0 && keepalivePingCount > 0 {
                type = .temperature
            } else {
                type = .realtimeHeartRate
            }
            startSpotCheck(type: type)
            // Don't schedule next keepalive now — it will be scheduled when
            // the spot-check finishes (or times out).
        } else {
            scheduleNextKeepalive()
        }

        // Full data sync (HR log, HRV, SpO2, etc.) every N pings.
        if keepalivePingCount >= Self.fullSyncEveryNPings {
            keepalivePingCount = 0
            fullSyncCycleCount += 1
            if sensorState == .idle || spotCheckActive {
                tLog("[Keepalive] Full sync triggered (every \(Self.fullSyncEveryNPings) pings)")
                // Stagger syncs so commands don't pile up on the ring.
                // Start after 20 s — gives the spot-check time to finish first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                    self?.getHeartRateLog(dayOffset: 0) { _ in }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 22) { [weak self] in
                    self?.getHeartRateLog(dayOffset: 1) { _ in }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 24) { [weak self] in
                    self?.syncHRVData(dayOffset: 0)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 26) { [weak self] in
                    self?.syncBloodOxygen(dayOffset: 0)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 28) { [weak self] in
                    self?.syncPressureData(dayOffset: 0)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                    self?.syncActivityData(dayOffset: 0)
                }
                // Re-check HR log settings — the ring firmware resets them
                // on its own midnight reboot cycle.
                DispatchQueue.main.asyncAfter(deadline: .now() + 32) { [weak self] in
                    guard let self else { return }
                    Task { @MainActor in
                        await self.ensureHRLogSettings()
                    }
                }
            }
        }
    }
}

// MARK: - Tracking settings (Settings protocol: HRV, Heart Rate, Blood Oxygen, Pressure)

private let settingsActionRead: UInt8 = 1
private let settingsActionWrite: UInt8 = 2

enum RingSessionTrackingError: Error {
    case notConnected
    case timeout
}

extension RingSessionManager {
    /// Request current enabled state for one tracking setting (Settings protocol READ).
    func getTrackingSetting(_ setting: RingTrackingSetting, completion: @escaping (Bool) -> Void) {
        pendingTrackingSetting = setting
        pendingTrackingSettingCallback = completion
        sendSettingRead(commandId: setting.commandId)
    }

    /// Read one tracking setting from the ring (async); throws if not connected or times out after 5 s.
    func readTrackingSetting(_ setting: RingTrackingSetting) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            guard uartRxCharacteristic != nil, peripheral != nil else {
                continuation.resume(throwing: RingSessionTrackingError.notConnected)
                return
            }
            trackingSettingGeneration &+= 1
            let gen = trackingSettingGeneration
            pendingTrackingSetting = setting
            pendingTrackingSettingContinuation = continuation
            sendSettingRead(commandId: setting.commandId)

            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.trackingSettingGeneration == gen, self.pendingTrackingSettingContinuation != nil else { return }
                tLog("[TrackingSetting] Timeout waiting for \(setting.displayName) read response")
                self.pendingTrackingSettingContinuation = nil
                self.pendingTrackingSetting = nil
                continuation.resume(throwing: RingSessionTrackingError.timeout)
            }
        }
    }

    /// Write one tracking setting to the ring (async); throws if not connected or times out after 5 s.
    func writeTrackingSetting(_ setting: RingTrackingSetting, enabled: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            guard uartRxCharacteristic != nil, peripheral != nil else {
                continuation.resume(throwing: RingSessionTrackingError.notConnected)
                return
            }
            trackingSettingGeneration &+= 1
            let gen = trackingSettingGeneration
            pendingTrackingSetting = setting
            pendingTrackingSettingContinuation = continuation
            sendSettingWrite(commandId: setting.commandId, isEnabled: enabled)

            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.trackingSettingGeneration == gen, self.pendingTrackingSettingContinuation != nil else { return }
                tLog("[TrackingSetting] Timeout waiting for \(setting.displayName) write response — assuming success")
                self.pendingTrackingSettingContinuation = nil
                self.pendingTrackingSetting = nil
                continuation.resume(returning: enabled)
            }
        }
    }

    private func handleTrackingSettingResponse(packet: [UInt8]) {
        guard packet.count >= 3 else { return }
        let setting = RingTrackingSetting(commandId: packet[0])
        guard let setting, setting == pendingTrackingSetting else { return }
        let isEnabled = packet[2] != 0
        if let continuation = pendingTrackingSettingContinuation {
            pendingTrackingSettingContinuation = nil
            pendingTrackingSetting = nil
            continuation.resume(returning: isEnabled)
        } else {
            pendingTrackingSettingCallback?(isEnabled)
            pendingTrackingSetting = nil
            pendingTrackingSettingCallback = nil
        }
    }

    private func sendSettingRead(commandId: UInt8) {
        guard let uartRxCharacteristic, let peripheral else {
            tLog("Cannot send settings request. Peripheral or characteristic not ready.")
            return
        }
        do {
            let data = [UInt8](repeating: 0, count: 13)
            let packet = try makeSettingsPacket(commandId: commandId, action: settingsActionRead, data: data)
            appendToDebugLog(direction: .sent, bytes: packet)
            peripheral.writeValue(Data(packet), for: uartRxCharacteristic, type: .withResponse)
        } catch {
            tLog("Failed to create settings packet: \(error)")
        }
    }

    private func sendSettingWrite(commandId: UInt8, isEnabled: Bool) {
        guard let uartRxCharacteristic, let peripheral else {
            tLog("Cannot send settings write. Peripheral or characteristic not ready.")
            return
        }
        do {
            var data = [UInt8](repeating: 0, count: 13)
            data[0] = isEnabled ? 1 : 0
            let packet = try makeSettingsPacket(commandId: commandId, action: settingsActionWrite, data: data)
            appendToDebugLog(direction: .sent, bytes: packet)
            peripheral.writeValue(Data(packet), for: uartRxCharacteristic, type: .withResponse)
        } catch {
            tLog("Failed to create settings write packet: \(error)")
        }
    }
}

// MARK: - HR Log Settings (Timing Monitor: interval + enabled)

extension RingSessionManager {
    /// Read the current HR log settings (enabled + interval) from the ring.
    func readHRLogSettings() async throws -> (enabled: Bool, intervalMinutes: Int) {
        try await withCheckedThrowingContinuation { continuation in
            guard uartRxCharacteristic != nil, peripheral != nil else {
                continuation.resume(throwing: RingSessionTrackingError.notConnected)
                return
            }
            pendingHRLogSettingsContinuation = continuation
            do {
                // Read: send command 0x16 with all-zero subdata
                let packet = try makePacket(command: Self.CMD_HR_TIMING_MONITOR)
                appendToDebugLog(direction: .sent, bytes: packet)
                sendPacket(packet: packet)
            } catch {
                pendingHRLogSettingsContinuation = nil
                continuation.resume(throwing: error)
            }
        }
    }

    /// Write HR log settings to the ring: enabled state + interval in minutes (1–10).
    func writeHRLogSettings(enabled: Bool, intervalMinutes: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard uartRxCharacteristic != nil, peripheral != nil else {
                continuation.resume(throwing: RingSessionTrackingError.notConnected)
                return
            }
            do {
                var subData: [UInt8] = [
                    enabled ? 1 : 0,
                    UInt8(clamping: intervalMinutes)
                ]
                // Pad to fit standard packet (14 bytes subdata max, we only need 2)
                let packet = try makePacket(command: Self.CMD_HR_TIMING_MONITOR, subData: subData)
                appendToDebugLog(direction: .sent, bytes: packet)
                sendPacket(packet: packet)
                // Update local state immediately (ring doesn't always echo back on write)
                hrLogEnabled = enabled
                hrLogIntervalMinutes = intervalMinutes
                tLog("[HRLogSettings] Wrote enabled=\(enabled), interval=\(intervalMinutes)min")
                continuation.resume()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func handleHRTimingMonitorResponse(packet: [UInt8]) {
        guard packet.count >= 3, packet[0] == Self.CMD_HR_TIMING_MONITOR else {
            tLog("[HRLogSettings] Invalid HR timing monitor packet: \(packet)")
            return
        }
        let enabled = packet[1] != 0
        let interval = Int(packet[2])
        hrLogEnabled = enabled
        hrLogIntervalMinutes = interval
        tLog("[HRLogSettings] Response: enabled=\(enabled), interval=\(interval)min")

        if let continuation = pendingHRLogSettingsContinuation {
            pendingHRLogSettingsContinuation = nil
            continuation.resume(returning: (enabled: enabled, intervalMinutes: interval))
        }
    }
}

// MARK: - Heart Rate Log

extension RingSessionManager {
    /// The ring clock is set to UTC, so its internal "day" runs midnight-to-midnight UTC.
    /// We must request HR logs using UTC day boundaries so the ring returns the correct data.
    private func dayStartInUTC(for base: Date = Date(), dayOffset: Int = 0) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = calendar.startOfDay(for: base)
        guard dayOffset != 0 else { return start }
        return calendar.date(byAdding: .day, value: -dayOffset, to: start)
    }

    func getHeartRateLog(dayOffset: Int = 0, completion: @escaping (HeartRateLog) -> Void) {
        guard let uartRxCharacteristic, let peripheral else {
            tLog("Cannot send heart rate log request. Peripheral or characteristic not ready.")
            return
        }

        do {
            // Request using UTC midnight — ring clock is UTC so its day boundaries are UTC.
            guard let target = dayStartInUTC(for: Date.now, dayOffset: dayOffset) else {
                return
            }
            let packet = try readHeartRatePacket(for: target)
            let data = Data(packet)
            peripheral.writeValue(data, for: uartRxCharacteristic, type: .withResponse)

            // Enqueue the LOCAL-timezone day-start for persistence/UI (user sees local calendar days).
            let localDayStart = Calendar.current.startOfDay(
                for: Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date.now) ?? Date.now
            )
            self.heartRateLogRequestedDays.append(localDayStart)
            tLog("HRL Command Sent (dayOffset: \(dayOffset), utcTarget: \(target), localDay: \(localDayStart), queue=\(heartRateLogRequestedDays.count))")

            // Store completion handler to call when data is received
            self.heartRateLogCallback = completion
        } catch {
            tLog("Failed to create hrl packet: \(error)")
        }
    }

    private func handleHeartRateLogResponse(packet: [UInt8]) {
        guard packet[0] == RingSessionManager.CMD_READ_HEART_RATE else {
            tLog("Invalid heart rate log packet received.")
            return
        }

        let parsed = hrp.parse(packet: packet)

        // parse() returns:
        //   nil       → intermediate packet (multi-packet log still assembling) — do NOT dequeue
        //   NoData    → ring has no data for this day (subType 0xFF) — dequeue & skip
        //   HeartRateLog → complete log assembled — dequeue & persist
        if parsed is NoData {
            if !heartRateLogRequestedDays.isEmpty {
                let skipped = heartRateLogRequestedDays.removeFirst()
                tLog("[HRL] No data from ring — dequeued \(skipped), queueRemaining=\(heartRateLogRequestedDays.count)")
            }
            return
        }

        guard let log = parsed as? HeartRateLog else {
            // Intermediate packet — still assembling, don't dequeue
            return
        }

        // Complete log — dequeue the requested day from the FIFO (matches request order).
        let requestedDay: Date
        if !heartRateLogRequestedDays.isEmpty {
            requestedDay = heartRateLogRequestedDays.removeFirst()
        } else {
            requestedDay = Calendar.current.startOfDay(for: log.timestamp)
            tLog("[HRL] WARNING: No queued requestedDay — falling back to ring timestamp")
        }
        tLog("[HRL] Parsed log: ringTimestamp=\(log.timestamp) requestedDay=\(requestedDay) range=\(log.range)min nonZero=\(log.heartRates.filter { $0 > 0 }.count) queueRemaining=\(heartRateLogRequestedDays.count)")
        heartRateLogPersistenceCallback?(log, requestedDay)
        heartRateLogCallback?(log)
        heartRateLogCallback = nil
    }
}

// MARK: - X

extension RingSessionManager {
    func sendXCommand() {
        do {
            let xPacket = try makePacket(command: Counter.shared.CMD_X, subData: nil)
            sendPacket(packet: xPacket)
        } catch {
            tLog("Failed to create blink twice packet: \(error)")
        }
    }
}
