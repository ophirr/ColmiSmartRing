 //
//  RingSessionManager.swift
//  Halo
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
    /// Set by GymSessionManager to prevent periodic sync from interrupting the real-time stream.
    var isWorkoutActive = false
    /// User-toggled continuous HR streaming from the home screen.
    var isContinuousHRStreamActive = false
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

    /// How many keepalive pings between full data syncs (HR log, HRV, SpO2, etc.).
    /// With a 60 s keepalive, 5 = full sync every ~5 minutes.
    private static let fullSyncEveryNPings: Int = 5
    /// Counter incremented on each keepalive; triggers full sync when it hits fullSyncEveryNPings.
    private var keepalivePingCount: Int = 0

    /// Periodic timer that re-syncs HR log (and other data) at the user's configured HR interval.
    /// Used as a foreground fallback; the BLE keepalive chain is the primary background driver.
    private var periodicSyncTimer: Timer?

    /// When true, the next valid real-time reading triggers an InfluxDB write
    /// and then auto-stops the stream.  Used for periodic spot-checks outside workouts.
    private var spotCheckActive = false
    /// Which reading type the current spot-check is measuring (HR or temperature).
    private var spotCheckType: RealTimeReading = .realtimeHeartRate
    /// Auto-stop the spot-check after this timeout even if no valid reading arrives.
    private var spotCheckTimeoutTask: Task<Void, Never>?

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
    
    
    private static let CMD_BLOOD_OXYGEN: UInt8 = 44
    

    private let hrp = HeartRateLogParser()
    private let healthHRWriter = AppleHealthHeartRateWriter()

    private var characteristicsDiscovered = false

    var batteryStatusCallback: ((BatteryInfo) -> Void)?
    var heartRateLogCallback: ((HeartRateLog) -> Void)?
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
    var heartRateLogPersistenceCallback: ((HeartRateLog) -> Void)?
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
        if p.state == .connected || p.state == .connecting {
            tLog("[Connect] ⚠️ Already connected/connecting, skipping")
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
        manager.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            CBConnectPeripheralOptionStartDelayKey: 1
        ])
    }

    func disconnect() {
        guard let peripheral, manager.state == .poweredOn else { return }
        reconnectTask?.cancel()  // User-initiated — don't auto-reconnect
        reconnectTask = nil
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
            tLog("[Restore] Restored peripheral: \(restored.identifier)")
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
                    connect()
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
        uartRxCharacteristic = nil
        uartTxCharacteristic = nil
        colmiWriteCharacteristic = nil
        colmiNotifyCharacteristic = nil
        isContinuousHRStreamActive = false
        spotCheckActive = false
        spotCheckTimeoutTask?.cancel()
        spotCheckTimeoutTask = nil
        awaitingKeepaliveBatteryResponse = false
        stopKeepalive()
        stopPeriodicSync()

        // Auto-reconnect if we have a saved ring (unexpected disconnect, e.g. phone locked).
        if savedRingIdentifier != nil {
            tLog("[Reconnect] Unexpected disconnect — will attempt to reconnect in 2s")
            reconnectTask?.cancel()
            reconnectTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled, !self.peripheralConnected else { return }
                tLog("[Reconnect] Attempting reconnect…")
                self.findRingAgain()
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        tLog("[Reconnect] Failed to connect: \(error.debugDescription)")
        if savedRingIdentifier != nil {
            tLog("[Reconnect] Will retry in 5s…")
            reconnectTask?.cancel()
            reconnectTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled, !self.peripheralConnected else { return }
                self.findRingAgain()
            }
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
        let wasReady = characteristicsDiscovered
        characteristicsDiscovered = (uartRxCharacteristic != nil && uartTxCharacteristic != nil)
        if characteristicsDiscovered && !wasReady {
            syncOnConnect()
            // Keepalive chain is started at the end of ensureHRLogSettings()
            // (called by syncOnConnect) so it doesn't overlap with the
            // initial sync and spot-check.
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
                    // range is roughly 30-220 BPM.
                    guard readingValue <= 220 else {
                        tLog("[RealTime] Ignoring out-of-range HR: \(readingValue)")
                        break
                    }
                    realTimeHeartRateBPM = Int(readingValue)

                    // Spot-check: got a valid reading — write to InfluxDB + Apple Health and stop.
                    if spotCheckActive && spotCheckType == .realtimeHeartRate {
                        tLog("[SpotCheck] Got HR \(readingValue) — writing to InfluxDB/HealthKit and stopping stream")
                        spotCheckActive = false
                        spotCheckTimeoutTask?.cancel()
                        spotCheckTimeoutTask = nil
                        lastInfluxHRWrite = now
                        let bpm = Int(readingValue)
                        Task { @MainActor in
                            InfluxDBWriter.shared.writeHeartRates([(bpm: bpm, time: now)])
                            await self.healthHRWriter.writeHeartRate(bpm: bpm, time: now)
                        }
                        stopRealTimeStreaming(type: .realtimeHeartRate)
                        // Continue the keepalive chain now that the spot-check is done.
                        scheduleNextKeepalive()
                        break
                    }

                    if now.timeIntervalSince(lastInfluxHRWrite) >= currentInfluxWriteInterval {
                        lastInfluxHRWrite = now
                        Task { @MainActor in
                            InfluxDBWriter.shared.writeHeartRates([(bpm: Int(readingValue), time: now)])
                        }
                    }
                case .spo2:
                    // R02 firmware does not support real-time SpO2 streaming
                    // (always returns 0).  SpO2 data comes from historical
                    // hourly logs instead.  We still update the UI if a
                    // non-zero value somehow arrives.
                    guard readingValue > 0 else { break }
                    realTimeBloodOxygenPercent = Int(readingValue)

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
                    guard packet.count >= 8 else { break }
                    let rawTemp = Int(packet[6]) | (Int(packet[7]) << 8)
                    guard rawTemp > 0 else { break }
                    let celsius = Double(rawTemp) / 20.0
                    // Sanity-check: body temperature should be 30-42°C
                    guard celsius >= 30.0 && celsius <= 42.0 else {
                        tLog("[RealTime] Ignoring out-of-range temp: \(celsius)°C (raw=\(rawTemp))")
                        break
                    }
                    realTimeTemperatureCelsius = celsius

                    // Spot-check: got a valid temperature — write and stop.
                    if spotCheckActive && spotCheckType == .temperature {
                        tLog("[SpotCheck] Got temp \(celsius)°C — writing to InfluxDB/HealthKit and stopping stream")
                        spotCheckActive = false
                        spotCheckTimeoutTask?.cancel()
                        spotCheckTimeoutTask = nil
                        lastInfluxTempWrite = now
                        Task { @MainActor in
                            InfluxDBWriter.shared.writeTemperature(celsius: celsius, time: now)
                            await self.healthHRWriter.writeTemperature(celsius: celsius, time: now)
                        }
                        stopRealTimeStreaming(type: .temperature)
                        scheduleNextKeepalive()
                        break
                    }

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
            } else if hrValue <= 220 {
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
            // The ring auto-stops real-time streaming after ~60 s.
            // Restart if a workout or user-toggled continuous stream is active.
            if isWorkoutActive || isContinuousHRStreamActive {
                tLog("[RealTime] Ring auto-stopped stream — restarting (\(isWorkoutActive ? "workout" : "continuous"))")
                startRealTimeStreaming(type: .realtimeHeartRate)
            } else {
                tLog("[RealTime] Stream stopped — clearing live HR")
                realTimeHeartRateBPM = nil
            }
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
        if isWorkoutActive || isContinuousHRStreamActive {
            tLog("[Keepalive] Active stream — skipping battery read, rescheduling")
            scheduleNextKeepalive()
            return
        }

        tLog("[Keepalive] Sending battery ping #\(keepalivePingCount + 1)")
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
        getBatteryStatus { _ in }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, !self.isWorkoutActive else {
                tLog("[SyncOnConnect] Workout active — skipping HR log sync")
                return
            }
            self.getHeartRateLog { _ in }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self, !self.isWorkoutActive else { return }
            self.syncHRVData(dayOffset: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            guard let self, !self.isWorkoutActive else { return }
            self.syncBloodOxygen(dayOffset: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, !self.isWorkoutActive else { return }
            self.syncPressureData(dayOffset: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) { [weak self] in
            guard let self, !self.isWorkoutActive else { return }
            self.syncActivityData(dayOffset: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) { [weak self] in
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
        let savedInterval = UserDefaults.standard.object(forKey: "hrLogInterval") as? Int ?? 5
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

        startPeriodicSync(intervalMinutes: savedInterval)

        // Only start continuous real-time HR streaming if a workout is active.
        // Outside workouts the ring's built-in HR logging (1-min interval) is
        // sufficient, and the green LED flashing continuously is distracting
        // (e.g. during sleep).
        if isWorkoutActive {
            tLog("[SyncOnConnect] Workout active — starting real-time HR stream")
            startRealTimeStreaming(type: .realtimeHeartRate)
        } else if isContinuousHRStreamActive {
            tLog("[SyncOnConnect] Continuous stream was active — restarting")
            startRealTimeStreaming(type: .realtimeHeartRate)
        } else if !spotCheckActive {
            tLog("[SyncOnConnect] Running spot-check for fresh InfluxDB reading")
            startSpotCheck()
        } else {
            tLog("[SyncOnConnect] Spot-check already active — skipping")
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

        if isWorkoutActive || isContinuousHRStreamActive {
            tLog("[PeriodicSync] Active stream — skipping entirely")
            return
        }

        tLog("[PeriodicSync] Foreground fallback sync")

        if !spotCheckActive {
            startSpotCheck()
        }

        getHeartRateLog { _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.syncHRVData(dayOffset: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.syncBloodOxygen(dayOffset: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            self?.syncPressureData(dayOffset: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            self?.syncActivityData(dayOffset: 0)
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

    /// Request activity data (steps/calories/distance) via Sports Data (Commands protocol, ID 67).
    func syncActivityData(dayOffset: Int = 0) {
        do {
            let packet = try makePacket(command: Self.CMD_READ_ACTIVITY_DATA, subData: [
                UInt8(dayOffset & 0xFF),
                15,
                0,
                95
            ])
            appendToDebugLog(direction: .sent, bytes: packet)
            sendPacket(packet: packet)
            tLog("Activity data requested (Commands 67, dayOffset: \(dayOffset))")
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

// MARK: - RealTime Streaming

extension RingSessionManager {
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

    func startRealTimeStreaming(type: RealTimeReading) {
        tLog("[RealTime] START \(type)")
        sendRealTimeCommand(command: RingSessionManager.CMD_START_REAL_TIME, type: type, action: .start)
    }

    func continueRealTimeStreaming(type: RealTimeReading) {
        tLog("[RealTime] CONTINUE \(type)")
        sendRealTimeCommand(command: RingSessionManager.CMD_START_REAL_TIME, type: type, action: .continue)
    }

    func stopRealTimeStreaming(type: RealTimeReading) {
        tLog("[RealTime] STOP \(type)")
        realTimeHeartRateBPM = nil
        spotCheckActive = false
        spotCheckTimeoutTask?.cancel()
        spotCheckTimeoutTask = nil
        sendRealTimeCommand(command: RingSessionManager.CMD_STOP_REAL_TIME, type: type, action: nil)
    }

    /// Start a brief real-time HR measurement.  The stream auto-stops as soon as
    /// the first valid (non-zero, ≤220) HR packet arrives, or after 15 s timeout.
    /// Toggle continuous real-time HR streaming from the home screen.
    func toggleContinuousHRStream() {
        guard !isWorkoutActive else {
            tLog("[ContinuousHR] Ignored — workout is active")
            return
        }
        if isContinuousHRStreamActive {
            tLog("[ContinuousHR] Stopping continuous stream")
            isContinuousHRStreamActive = false
            stopRealTimeStreaming(type: .realtimeHeartRate)
        } else {
            tLog("[ContinuousHR] Starting continuous stream")
            isContinuousHRStreamActive = true
            startRealTimeStreaming(type: .realtimeHeartRate)
        }
    }

    private func startSpotCheck(type: RealTimeReading = .realtimeHeartRate) {
        guard !isWorkoutActive, !isContinuousHRStreamActive else { return }
        tLog("[SpotCheck] Starting brief \(type) spot-check")
        spotCheckActive = true
        spotCheckType = type
        startRealTimeStreaming(type: type)

        // Safety timeout — temperature needs ~16s to measure, HR is faster.
        let timeoutSeconds: UInt64 = (type == .temperature) ? 20 : 15
        spotCheckTimeoutTask?.cancel()
        spotCheckTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
            guard let self, !Task.isCancelled, self.spotCheckActive else { return }
            tLog("[SpotCheck] Timeout — stopping \(type) stream without a valid reading")
            self.spotCheckActive = false
            self.stopRealTimeStreaming(type: type)
            // Continue the keepalive chain even though this check failed.
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
        guard awaitingKeepaliveBatteryResponse else { return }
        awaitingKeepaliveBatteryResponse = false

        keepalivePingCount += 1

        // Alternate spot-checks: odd pings → HR, even pings → temperature.
        // (R02 firmware does not support real-time SpO2, so we skip that.)
        if !isWorkoutActive && !isContinuousHRStreamActive && !spotCheckActive {
            let type: RealTimeReading = (keepalivePingCount % 2 == 1) ? .realtimeHeartRate : .temperature
            startSpotCheck(type: type)
            // Don't schedule next keepalive now — it will be scheduled when
            // the spot-check finishes (or times out).  This prevents piling
            // up battery pings while the PPG sensor is still measuring.
        } else {
            // Stream active or another spot-check in progress — just reschedule.
            scheduleNextKeepalive()
        }

        // Full data sync (HR log, HRV, SpO2, etc.) every N pings.
        if keepalivePingCount >= Self.fullSyncEveryNPings {
            keepalivePingCount = 0
            if !isWorkoutActive && !isContinuousHRStreamActive {
                tLog("[Keepalive] Full sync triggered (every \(Self.fullSyncEveryNPings) pings)")
                // Stagger syncs so commands don't pile up on the ring.
                // Start after 20 s — gives the spot-check time to finish first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                    self?.getHeartRateLog { _ in }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 22) { [weak self] in
                    self?.syncHRVData(dayOffset: 0)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 24) { [weak self] in
                    self?.syncBloodOxygen(dayOffset: 0)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 26) { [weak self] in
                    self?.syncPressureData(dayOffset: 0)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 28) { [weak self] in
                    self?.syncActivityData(dayOffset: 0)
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
    private func dayStartInPreferredTimeZone(for base: Date = Date(), dayOffset: Int = 0) -> Date? {
        var calendar = Calendar.current
        calendar.timeZone = preferredDataTimeZone
        let start = calendar.startOfDay(for: base)
        guard dayOffset != 0 else { return start }
        return calendar.date(byAdding: .day, value: -dayOffset, to: start)
    }

    func getHeartRateLog(completion: @escaping (HeartRateLog) -> Void) {
        guard let uartRxCharacteristic, let peripheral else {
            tLog("Cannot send heart rate log request. Peripheral or characteristic not ready.")
            return
        }
        
        do {
            guard let target = dayStartInPreferredTimeZone(for: Date.now, dayOffset: 0) else {
                return
            }
            let packet = try readHeartRatePacket(for: target)
            let data = Data(packet)
            peripheral.writeValue(data, for: uartRxCharacteristic, type: .withResponse)
            
            tLog("HRL Commmand Sent")
            
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
        
        guard let log = hrp.parse(packet: packet) as? HeartRateLog else {
            return
        }
        heartRateLogPersistenceCallback?(log)
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
