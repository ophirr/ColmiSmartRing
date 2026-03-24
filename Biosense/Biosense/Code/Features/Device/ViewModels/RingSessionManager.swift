 //
//  RingSessionManager.swift
//  Biosense
//
//  Created by Yannis De Cleene on 27/01/2025.
//

import Foundation
import CoreBluetooth
import SwiftUI

private let savedRingIdentifierKey = AppSettings.Ring.savedIdentifier
private let savedRingDisplayNameKey = AppSettings.Ring.savedDisplayName
private let preferredDataTimeZoneIdentifierKey = AppSettings.Ring.preferredTimeZone

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
    private let sportRTWindowSeconds: TimeInterval = RingConstants.sportRTWindowSeconds

    // MARK: Phone Sport Mode (0x77 / 0x78)

    /// Whether phone sport mode is currently active on the ring.
    private(set) var phoneSportActive = false
    /// Latest step count from 0x78 sport notifications (session-scoped).
    var phoneSportSteps: Int = 0
    /// Latest distance (meters) from 0x78 sport notifications.
    var phoneSportDistanceM: Int = 0
    /// Latest HR from 0x78 sport notifications.
    var phoneSportHR: Int = 0
    /// Latest calories from 0x78 sport notifications.
    var phoneSportCalories: Int = 0
    /// Latest sport duration (seconds) from 0x78 sport notifications.
    /// Handles uint8 wrap: byte[4] wraps at 255, so this accumulates total elapsed.
    var phoneSportDurationSec: Int = 0
    /// Accumulates 256-second increments when byte[4] (uint8 elapsed) wraps.
    private var phoneSportElapsedAccumulator: Int = 0
    /// Previous raw elapsed value from 0x78, used to detect uint8 wrap.
    private var phoneSportLastRawElapsed: Int = 0
    /// Running steps from CMD 0x48 — exposed for UI display.
    var todayRunningSteps: Int = 0

    // MARK: Raw Sensor Streaming (0xA1)

    /// Whether raw sensor streaming (PPG + accel + SpO2) is currently active.
    private(set) var rawSensorStreamActive = false
    /// Latest raw PPG sample (raw waveform value).
    var rawPPGValue: Int = 0
    /// Latest raw accelerometer sample.
    var rawAccelX: Int = 0
    var rawAccelY: Int = 0
    var rawAccelZ: Int = 0
    /// Counters for raw sensor packets received (for debug display / sample rate calc).
    var rawPPGCount: Int = 0
    var rawAccelCount: Int = 0
    var rawSpO2Count: Int = 0
    /// Timestamp of the first raw packet in the current streaming session.
    private var rawStreamStartTime: Date?

    /// Latest real-time blood oxygen reading in percent.
    var realTimeBloodOxygenPercent: Int?
    /// Timer that sends continue keepalives to keep the SpO2 measurement alive.
    private var spo2ContinueTimer: Timer?
    /// Latest real-time body temperature in °C (e.g. 36.3).
    var realTimeTemperatureCelsius: Double?
    /// Latest battery info reported by the ring.
    var currentBatteryInfo: BatteryInfo?
    /// Tracks battery drain history for real-time life estimation.
    let batteryEstimator = BatteryEstimator()
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

    /// Firmware revision string read from Device Info Service (0x180A), e.g. "R02_3.00.06".
    var firmwareRevision: String?
    /// Hardware revision string read from Device Info Service.
    var hardwareRevision: String?

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

    private var scanWorkItem: DispatchWorkItem?

    private var keepaliveWorkItem: DispatchWorkItem?
    /// Timestamp of the last keepalive ping sent (or chain restart). Used to detect stalled chains.
    private var lastKeepaliveSentAt: Date = Date()

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

    /// Throttle real-time InfluxDB writes.
    private var lastInfluxHRWrite: Date = .distantPast
    private var lastInfluxSpO2Write: Date = .distantPast
    private var lastInfluxTempWrite: Date = .distantPast
    private var currentInfluxWriteInterval: TimeInterval {
        isWorkoutActive ? RingConstants.influxWriteIntervalWorkout : RingConstants.influxWriteIntervalNormal
    }

    private var uartRxCharacteristic: CBCharacteristic?
    private var uartTxCharacteristic: CBCharacteristic?
    private var colmiWriteCharacteristic: CBCharacteristic?
    private var colmiNotifyCharacteristic: CBCharacteristic?

    // BLE Service/Characteristic UUIDs — aliases for readability.
    private static let ringServiceUUID = SmartRingBLE.nordicUARTServiceUUID
    private static let colmiServiceUUID = SmartRingBLE.colmiServiceUUID
    private static let colmiWriteUUID = SmartRingBLE.colmiWriteUUID
    private static let colmiNotifyUUID = SmartRingBLE.colmiNotifyUUID
    private static let uartRxCharacteristicUUID = SmartRingBLE.nordicUARTTxUUID
    private static let uartTxCharacteristicUUID = SmartRingBLE.nordicUARTRxUUID
    private static let deviceInfoServiceUUID = SmartRingBLE.deviceInfoServiceUUID
    private static let firmwareRevisionCharUUID = SmartRingBLE.firmwareRevisionCharUUID
    private static let hardwareRevisionCharUUID = SmartRingBLE.hardwareRevisionCharUUID

    // Command IDs — see RingConstants for documentation.
    private typealias CMD = RingConstants
    

    private let hrp = HeartRateLogParser()
    private let healthHRWriter = AppleHealthHeartRateWriter()

    private var characteristicsDiscovered = false
    /// Tracks which notify characteristics have been confirmed by CoreBluetooth.
    private var confirmedNotifyCharacteristics: Set<CBUUID> = []
    /// Prevents syncOnConnect from firing more than once per connection.
    private var syncOnConnectFired = false

    var batteryStatusCallback: ((BatteryInfo) -> Void)?
    var heartRateLogCallback: ((HeartRateLog) -> Void)?
    /// Maps UTC-midnight target (sent to ring) → local day-start (for persistence/UI).
    /// Keyed lookup avoids FIFO ordering fragility when NoData responses shift the queue.
    private var heartRateLogUTCToLocalDay: [Date: Date] = [:]
    /// Delegate for persisting ring data. Set by RingDataPersistenceCoordinator.
    weak var dataDelegate: RingDataDelegate?
    /// Latest Big Data sleep result, observable by SwiftUI views.
    var lastBigDataSleep: BigDataSleepData?
    /// Latest legacy sleep data (command 68), observable by SwiftUI views.
    var lastSleepData: SleepData?
    /// Set to `true` when the ring is connected and UART characteristics are ready.
    /// Views can observe this with `.onChange(of:)` to trigger settings reads.
    var isReadyForSettingsQuery = false
    /// HR log interval reported by the ring (minutes). nil = not yet queried.
    var hrLogIntervalMinutes: Int?
    /// HR log enabled state reported by the ring. nil = not yet queried.
    var hrLogEnabled: Bool?
    /// Manages async tracking-setting and HR log setting read/write with continuations.
    private let trackingSettings = RingTrackingSettingsManager()
    /// Last requested dayOffset for sleep (0 = today); used when parsing response 68.
    private var lastSleepDayOffset: Int = 0
    /// Big Data notify buffer (variable-length responses may arrive in chunks).
    private var bigDataBuffer: [UInt8] = []

    /// Cancellable work items for the post-connect spot-check chain
    /// (SpO2 → HR → Temp).  Stored so they can be cancelled on disconnect.
    private var spotCheckChainWorkItems: [DispatchWorkItem] = []

    /// Cancellable command scheduler — replaces nested asyncAfter chains
    /// in syncOnConnect, runPeriodicSync, and handleBatteryResponse.
    private let syncScheduler = CommandScheduler()
    private let periodicSyncScheduler = CommandScheduler()
    private let fullSyncScheduler = CommandScheduler()

    // MARK: - Debug log (for Debug tab)
    struct DebugLogEntry: Identifiable {
        let id = UUID()
        let date: Date
        let direction: Direction
        let bytes: [UInt8]
        enum Direction: String { case sent = "→ Sent"; case received = "← Received" }
    }
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

        // Wire tracking settings manager callbacks
        trackingSettings.isConnected = { [weak self] in
            self?.uartRxCharacteristic != nil && self?.peripheral != nil
        }
        trackingSettings.sendPacket = { [weak self] packet in
            self?.sendPacket(packet: packet)
        }
        trackingSettings.sendSettingsPacket = { [weak self] commandId, action, data in
            guard let self, let uartRx = self.uartRxCharacteristic, let peripheral = self.peripheral else {
                tLog("Cannot send settings packet. Peripheral or characteristic not ready.")
                return
            }
            do {
                let packet = try makeSettingsPacket(commandId: commandId, action: action, data: data)
                self.appendToDebugLog(direction: .sent, bytes: packet)
                peripheral.writeValue(Data(packet), for: uartRx, type: .withResponse)
            } catch {
                tLog("Failed to create settings packet: \(error)")
            }
        }
        trackingSettings.appendToDebugLog = { [weak self] direction, bytes in
            self?.appendToDebugLog(direction: direction, bytes: bytes)
        }
        trackingSettings.onHRLogSettingsUpdated = { [weak self] enabled, interval in
            self?.hrLogEnabled = enabled
            self?.hrLogIntervalMinutes = interval
        }

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
        DispatchQueue.main.asyncAfter(deadline: .now() + RingConstants.scanTimeout, execute: item)
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
            DispatchQueue.main.asyncAfter(deadline: .now() + RingConstants.connectRetryDelay) { [weak self] in
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
        DispatchQueue.main.asyncAfter(deadline: .now() + RingConstants.scanTimeout, execute: item)
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
            DispatchQueue.main.asyncAfter(deadline: .now() + RingConstants.connectRetryDelay) { [weak self] in
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
        if debugLog.count > RingConstants.debugLogMaxEntries {
            debugLog.removeFirst(debugLog.count - RingConstants.debugLogMaxEntries)
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
                    tLog("Found previously connected peripheral (state=\(known.state.rawValue))")
                    peripheral = known
                    peripheral?.delegate = self
                    if known.state == .connected && peripheralConnected {
                        // Genuinely connected from this session — safe to reuse.
                        tLog("[Connect] Already connected — discovering services")
                        known.discoverServices(nil)
                    } else if known.state == .connected {
                        // Restored as .connected but we weren't tracking it — the
                        // BLE link is likely stale from a prior session.  Cycle the
                        // connection so the radio re-establishes fresh.
                        tLog("[Connect] Stale .connected state — cycling connection")
                        central.cancelPeripheralConnection(known)
                        DispatchQueue.main.asyncAfter(deadline: .now() + RingConstants.connectRetryDelay) { [weak self] in
                            guard let self, let p = self.peripheral, self.manager.state == .poweredOn else { return }
                            tLog("[Connect] Re-connecting after stale cancel")
                            self.manager.connect(p, options: [
                                CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
                            ])
                        }
                    } else {
                        // Cancel any stale .connecting state from a restored session
                        // (e.g. after factory reset the old bond is invalid and the
                        // pending connect will never complete).
                        if known.state == .connecting {
                            tLog("[Connect] Cancelling stale .connecting state")
                            central.cancelPeripheralConnection(known)
                        }
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
        isReadyForSettingsQuery = false
        uartRxCharacteristic = nil
        uartTxCharacteristic = nil
        colmiWriteCharacteristic = nil
        colmiNotifyCharacteristic = nil
        // Reset raw sensor streaming state (connection is gone — no stop command needed).
        rawSensorStreamActive = false
        firmwareRevision = nil
        hardwareRevision = nil
        // Reset sensor state directly (no BLE commands — connection is gone).
        sensorState = .idle
        spo2ContinueTimer?.invalidate()
        spo2ContinueTimer = nil
        spotCheckTimeoutTask?.cancel()
        spotCheckTimeoutTask = nil
        awaitingKeepaliveBatteryResponse = false
        stopKeepalive()
        stopPeriodicSync()
        syncScheduler.cancel()
        periodicSyncScheduler.cancel()
        fullSyncScheduler.cancel()
        spotCheckChainWorkItems.forEach { $0.cancel() }
        spotCheckChainWorkItems.removeAll()

        // Resume any pending tracking/HR-log-settings continuations so callers
        // don't hang forever.
        trackingSettings.cancelPendingRequests()

        // Clear stale one-shot callbacks — if the ring disconnects before
        // responding, these closures would hold references indefinitely.
        batteryStatusCallback = nil
        heartRateLogCallback = nil

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
                tLog("DEBUG: Found device info service, discovering characteristics...")
                peripheral.discoverCharacteristics([
                    CBUUID(string: Self.firmwareRevisionCharUUID),
                    CBUUID(string: Self.hardwareRevisionCharUUID)
                ], for: service)
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
            case CBUUID(string: Self.firmwareRevisionCharUUID):
                tLog("DEBUG: Found firmware revision characteristic — reading")
                peripheral.readValue(for: characteristic)
            case CBUUID(string: Self.hardwareRevisionCharUUID):
                tLog("DEBUG: Found hardware revision characteristic — reading")
                peripheral.readValue(for: characteristic)
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
                self?.isReadyForSettingsQuery = true
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else {
            tLog("Failed to read characteristic value: \(String(describing: error))")
            return
        }
        
        let packet = [UInt8](value)

        // Device Info Service reads (firmware/hardware revision) — plain UTF-8 strings.
        if characteristic.uuid == CBUUID(string: Self.firmwareRevisionCharUUID) {
            firmwareRevision = String(data: value, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
            tLog("[DeviceInfo] Firmware revision: \(firmwareRevision ?? "nil")")
            return
        }
        if characteristic.uuid == CBUUID(string: Self.hardwareRevisionCharUUID) {
            hardwareRevision = String(data: value, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
            tLog("[DeviceInfo] Hardware revision: \(hardwareRevision ?? "nil")")
            return
        }

        if characteristic.uuid == CBUUID(string: Self.colmiNotifyUUID) {
            appendToDebugLog(direction: .received, bytes: packet)
            if gymWorkoutInProgress {
                let hex = packet.map { String(format: "%02x", $0) }.joined(separator: " ")
                tLog("[WorkoutRX-BigData] len=\(packet.count) hex=\(hex)")
            }
            // Raw sensor (0xA1) packets arrive on this service but are NOT Big Data protocol.
            // Intercept them before processBigDataChunk, which expects magic byte 0xBC.
            if packet.first == CMD.cmdRawSensor {
                let result = RingPacketDispatcher.dispatch(packet)
                switch result {
                case .rawPPG(let raw, _, _, _, let ts):
                    rawPPGValue = raw; rawPPGCount += 1
                    if rawStreamStartTime == nil { rawStreamStartTime = ts }
                case .rawAccelerometer(let x, let y, let z, let ts):
                    rawAccelX = x; rawAccelY = y; rawAccelZ = z; rawAccelCount += 1
                    if rawStreamStartTime == nil { rawStreamStartTime = ts }
                case .rawSpO2(let value, _, _, _, let ts):
                    rawSpO2Count += 1
                    if rawStreamStartTime == nil { rawStreamStartTime = ts }
                    _ = value
                case .rawSensorAck:
                    tLog("[RawSensor] Ack on BigData service")
                default:
                    break
                }
                return
            }
            processBigDataChunk(packet)
            tLog(packet)
            return
        }

        if characteristic.uuid == CBUUID(string: Self.uartTxCharacteristicUUID) {
            appendToDebugLog(direction: .received, bytes: packet)
            // During workouts, dump every raw packet for protocol analysis
            if gymWorkoutInProgress {
                let hex = packet.map { String(format: "%02x", $0) }.joined(separator: " ")
                tLog("[WorkoutRX] opcode=0x\(String(format: "%02x", packet[0])) len=\(packet.count) hex=\(hex)")
            }
        }

        switch RingPacketDispatcher.dispatch(packet) {

        // MARK: Real-time HR (0x69)
        case .heartRateReading(let bpm, let timestamp):
            lastRealTimeHRPacketTime = timestamp
            if spotCheckActive && spotCheckType == .realtimeHeartRate {
                spotCheckHRReadings.append(bpm)
                tLog("[SpotCheck] HR sample \(spotCheckHRReadings.count): \(bpm) bpm")
            } else {
                realTimeHeartRateBPM = bpm
                throttledInfluxHRWrite(bpm: bpm, at: timestamp)
            }

        case .heartRateZero(let timestamp):
            lastRealTimeHRPacketTime = timestamp
            if isWorkoutActive { realTimeHeartRateBPM = nil }

        case .heartRateOutOfRange(let value, let timestamp):
            lastRealTimeHRPacketTime = timestamp
            tLog("[RealTime] Ignoring out-of-range HR: \(value)")

        // MARK: Real-time SpO2 (0x69)
        case .spo2Reading(let percent, let timestamp):
            realTimeBloodOxygenPercent = percent
            if spotCheckActive && spotCheckType == .spo2 {
                tLog("[SpotCheck] Got SpO2 \(percent)% — writing to InfluxDB/HealthKit/SwiftData and stopping stream")
                lastInfluxSpO2Write = timestamp
                Task { @MainActor in
                    InfluxDBWriter.shared.writeSpO2(value: Double(percent), time: timestamp)
                    await self.healthHRWriter.writeSpO2(percent: percent, time: timestamp)
                }
                dataDelegate?.ringDidReceiveSpotCheckSpO2(percent: percent, time: timestamp)
                finishSpotCheck()
            } else {
                throttledInfluxSpO2Write(percent: percent, at: timestamp)
            }

        case .spo2OutOfRange(let value):
            tLog("[SpO2] Discarding out-of-range value: \(value)%")

        // MARK: Real-time temperature (0x69)
        case .temperatureReading(let celsius, let timestamp):
            tLog("[RealTime] Temp → \(String(format: "%.1f", celsius))°C")
            spotCheckTempReadings.append(celsius)
            guard celsius >= RingConstants.bodyTempRangeMin && celsius <= RingConstants.bodyTempRangeMax else { break }
            realTimeTemperatureCelsius = celsius
            guard !spotCheckActive else { break }
            throttledInfluxTempWrite(celsius: celsius, at: timestamp)

        case .readingError(let type, let errorCode):
            tLog("Error in reading - Type: \(type), Error Code: \(errorCode)")

        // MARK: RT HR via command 30 (0x1E)
        case .rtHR(let bpm, let timestamp):
            lastRealTimeHRPacketTime = timestamp
            if spotCheckActive && spotCheckType == .realtimeHeartRate {
                // During HR spot-check, collect for median — don't write warmup noise to InfluxDB.
                spotCheckHRReadings.append(bpm)
                tLog("[RT-HR30] heartRate=\(bpm) (spot-check sample \(spotCheckHRReadings.count))")
            } else {
                realTimeHeartRateBPM = bpm
                tLog("[RT-HR30] heartRate=\(bpm)")
                throttledInfluxHRWrite(bpm: bpm, at: timestamp)
            }

        case .rtHRZero(let timestamp):
            lastRealTimeHRPacketTime = timestamp
            if isWorkoutActive { realTimeHeartRateBPM = nil }
            tLog("[RT-HR30] heartRate=0 (warmup)")

        case .rtHROutOfRange(let value):
            tLog("[RT-HR30] Ignoring out-of-range HR: \(value)")

        // MARK: Stop / pathway notifications
        case .hrAutoStop:
            if isWorkoutActive || isContinuousHRStreamActive {
                tLog("[RealTime] Ring auto-stopped stream — restarting (\(isWorkoutActive ? "workout" : "continuous"))")
                startRealTimeStreaming(type: .realtimeHeartRate)
            } else {
                tLog("[RealTime] Stream stopped (0x6A)")
                realTimeHeartRateBPM = nil
            }

        case .spo2StopPathwayData(let percent):
            tLog("[SpO2] Response on 0x6A — value=\(percent)")
            realTimeBloodOxygenPercent = percent

        case .spo2StopNotification(let pkt):
            tLog("[SpO2] Stop notification (0x6B) — pkt=\(pkt.prefix(4).map { String(format: "%02x", $0) }.joined(separator: " "))")

        // MARK: Data responses (delegate to existing handlers)
        case .batteryResponse(let pkt):         handleBatteryResponse(packet: pkt)
        case .heartRateLogResponse(let pkt):    handleHeartRateLogResponse(packet: pkt)
        case .hrTimingMonitorResponse(let pkt):  trackingSettings.handleHRTimingMonitorResponse(packet: pkt)
        case .sleepDataResponse(let pkt):       handleSleepDataResponse(packet: pkt)
        case .sleepLegacyResponse(let pkt):     handleSleepResponse(packet: pkt)
        case .hrvDataResponse(let pkt):         handleHRVDataResponse(packet: pkt)
        case .pressureDataResponse(let pkt):    handlePressureDataResponse(packet: pkt)
        case .activityDataResponse(let pkt):    handleActivityDataResponse(packet: pkt)
        case .todaySportsResponse(let pkt):     handleTodaySportsResponse(packet: pkt)
        case .trackingSettingResponse(let pkt): trackingSettings.handleTrackingSettingResponse(packet: pkt)
        case .sportRealTimeResponse(let pkt):   handleSportRealTimeResponse(packet: pkt)
        case .phoneSportResponse(let pkt):      handlePhoneSportResponse(packet: pkt)
        case .phoneSportNotify(let pkt):        handlePhoneSportNotify(packet: pkt)

        // MARK: Raw sensor streaming (0xA1)
        case .rawPPG(let raw, _, _, _, let ts):
            rawPPGValue = raw
            rawPPGCount += 1
            if rawStreamStartTime == nil { rawStreamStartTime = ts }
        case .rawAccelerometer(let x, let y, let z, let ts):
            rawAccelX = x; rawAccelY = y; rawAccelZ = z
            rawAccelCount += 1
            if rawStreamStartTime == nil { rawStreamStartTime = ts }
        case .rawSpO2(let value, _, _, _, let ts):
            rawSpO2Count += 1
            if rawStreamStartTime == nil { rawStreamStartTime = ts }
            _ = value  // available for future use
        case .rawSensorAck:
            tLog("[RawSensor] Ack received")

        // MARK: Misc
        case .timeSyncAck(let success):
            tLog(success ? "[SyncTime] Ring acknowledged time sync OK" : "[SyncTime] Ring time sync response: \(packet.prefix(4).map { String(format: "%02x", $0) }.joined(separator: " "))")
        case .counterX:
            tLog("🔥")
        case .ack, .packetTooShort:
            break
        case .unhandled(let opcode, let pkt):
            tLog("Unhandled response opcode: \(opcode) (0x\(String(format: "%02x", opcode))) – full packet: \(pkt)")
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
            let blinkTwicePacket = try makePacket(command: CMD.cmdBlinkTwice, subData: nil)
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
            CMD.bigDataMagic,
            dataId,
            0, 0,       // dataLen = 0 (LE)
            0xFF, 0xFF  // crc16 = 0xFFFF (LE)
        ]
    }

    static func parseBigDataResponsePacket(_ packet: [UInt8]) -> (dataId: UInt8, dataLen: Int, crc16: UInt16, payload: [UInt8])? {
        let headerLen = CMD.bigDataHeaderLength
        guard packet.count >= headerLen, packet[0] == CMD.bigDataMagic else { return nil }
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

        // Safety cap: discard the buffer if it grows beyond the expected
        // maximum.  This prevents unbounded memory growth from corrupt
        // BLE data that never forms a valid packet header.
        if bigDataBuffer.count > CMD.bigDataBufferMaxBytes {
            tLog("[BigData] Buffer exceeded \(CMD.bigDataBufferMaxBytes) bytes — discarding \(bigDataBuffer.count) bytes")
            bigDataBuffer.removeAll()
            return
        }

        let headerLen = CMD.bigDataHeaderLength
        while bigDataBuffer.count >= headerLen {
            guard bigDataBuffer[0] == CMD.bigDataMagic else {
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
        case CMD.bigDataSleepId:
            if let sleepData = BigDataSleepParser.parseSleepPayload(payload) {
                tLog("Big Data sleep received – \(sleepData.sleepDays) day(s)")
                lastBigDataSleep = sleepData
                dataDelegate?.ringDidReceiveSleepData(sleepData)
            } else {
                tLog("Big Data sleep parse failed – payload length: \(payload.count)")
            }
        case CMD.bigDataBloodOxygenId:
            tLog("Big Data blood oxygen received – payload length: \(payload.count)")
            dataDelegate?.ringDidReceiveBloodOxygenPayload(payload)
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
        let delay = delay ?? RingConstants.keepaliveInterval
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
            let packet = try makePacket(command: CMD.cmdBattery)
            appendToDebugLog(direction: .sent, bytes: packet)
            sendPacket(packet: packet)
        } catch {
            tLog("[Keepalive] Packet failed: \(error)")
            awaitingKeepaliveBatteryResponse = false
        }
        // Don't schedule next here — handleBatteryResponse will do it when
        // the ring responds, keeping the chain BLE-event-driven.
        // Safety net: if the ring doesn't respond within the fallback timeout, retry.
        let fallback = DispatchWorkItem { [weak self] in
            guard let self, self.keepaliveWorkItem == nil else { return }
            tLog("[Keepalive] No battery response in \(Int(RingConstants.keepaliveFallbackTimeout))s — retrying")
            self.sendKeepalive()
        }
        keepaliveWorkItem = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + RingConstants.keepaliveFallbackTimeout, execute: fallback)
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
            transitionSensor(to: .workout)
            getBatteryStatus { _ in }
            DispatchQueue.main.asyncAfter(deadline: .now() + RingConstants.connectRetryDelay) { [weak self] in
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

        // Build the sync sequence with staggered delays.
        // The ring serialises BLE responses, so commands must be spaced by bleCommandSpacing.
        let spacing = RingConstants.bleCommandSpacing
        var steps: [CommandScheduler.Step] = []

        // Battery retry safety net (in case response was lost in post-restore flood).
        steps.append(.init(delay: RingConstants.batteryRetryDelay) { [weak self] in
            guard let self, self.currentBatteryInfo == nil else { return }
            tLog("[SyncOnConnect] Battery still nil after \(Int(RingConstants.batteryRetryDelay))s — retrying")
            self.getBatteryStatus { _ in }
        })
        // Sleep (Big Data).
        steps.append(.init(delay: spacing) { [weak self] in self?.syncSleep(dayOffset: 0) })
        // HR logs for a full week (days 0–6), spaced by bleCommandSpacing.
        for day in 0...6 {
            steps.append(.init(delay: spacing * 2 + Double(day) * spacing) { [weak self] in
                self?.getHeartRateLog(dayOffset: day) { _ in }
            })
        }
        // Other metrics start after HR logs (7 × spacing offset from 2×spacing base).
        let metricsBase = spacing * 2 + 7 * spacing  // = 9 × spacing = 5.4s
        steps.append(.init(delay: metricsBase) { [weak self] in self?.syncHRVData(dayOffset: 0) })
        steps.append(.init(delay: metricsBase + spacing) { [weak self] in self?.syncBloodOxygen(dayOffset: 0) })
        steps.append(.init(delay: metricsBase + spacing * 2) { [weak self] in self?.syncPressureData(dayOffset: 0) })
        steps.append(.init(delay: metricsBase + spacing * 3) { [weak self] in self?.syncActivityData(dayOffset: 0) })
        steps.append(.init(delay: metricsBase + spacing * 3.5) { [weak self] in self?.requestTodaySports() })
        steps.append(.init(delay: metricsBase + spacing * 4) { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.ensureHRLogSettings() }
        })

        syncScheduler.run(steps, cancelIf: { [weak self] in self?.isWorkoutActive ?? false })
    }

    /// Read HR log settings from ring; if disabled or interval doesn't match the user's saved
    /// preference, write the preferred settings. This ensures HR logging survives ring reboots.
    /// After configuring, starts a periodic sync timer at the same interval.
    private func ensureHRLogSettings() async {
        let savedInterval = UserDefaults.standard.object(forKey: AppSettings.Ring.hrLogInterval) as? Int ?? 1
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
        // Store as cancellable work items so disconnect can cancel them.
        spotCheckChainWorkItems.forEach { $0.cancel() }
        spotCheckChainWorkItems.removeAll()

        let hrItem = DispatchWorkItem { [weak self] in
            guard let self, self.peripheralConnected, self.sensorState == .idle else { return }
            tLog("[SyncOnConnect] Running HR spot-check")
            self.startSpotCheck(type: .realtimeHeartRate)
        }
        spotCheckChainWorkItems.append(hrItem)
        DispatchQueue.main.asyncAfter(deadline: .now() + RingConstants.spotCheckChainHRDelay, execute: hrItem)

        // Then temperature spot-check after HR.
        let tempItem = DispatchWorkItem { [weak self] in
            guard let self, self.peripheralConnected, self.sensorState == .idle,
                  self.realTimeTemperatureCelsius == nil else { return }
            tLog("[SyncOnConnect] Running temperature spot-check")
            self.startSpotCheck(type: .temperature)
        }
        spotCheckChainWorkItems.append(tempItem)
        DispatchQueue.main.asyncAfter(deadline: .now() + RingConstants.spotCheckChainTempDelay, execute: tempItem)

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

        periodicSyncScheduler.run([
            .init(delay: 0.0) { [weak self] in self?.getHeartRateLog(dayOffset: 0) { _ in } },
            .init(delay: 0.6) { [weak self] in self?.getHeartRateLog(dayOffset: 1) { _ in } },
            .init(delay: 1.2) { [weak self] in self?.syncHRVData(dayOffset: 0) },
            .init(delay: 1.8) { [weak self] in self?.syncBloodOxygen(dayOffset: 0) },
            .init(delay: 2.4) { [weak self] in self?.syncPressureData(dayOffset: 0) },
            .init(delay: 3.0) { [weak self] in self?.syncActivityData(dayOffset: 0) },
            .init(delay: 3.3) { [weak self] in self?.requestTodaySports() },
            // Re-check HR log settings — the ring firmware resets them on its own
            // midnight reboot, so we need to periodically re-apply.
            .init(delay: 3.6) { [weak self] in
                guard let self else { return }
                Task { @MainActor in await self.ensureHRLogSettings() }
            },
        ], cancelIf: { [weak self] in self?.isWorkoutActive ?? false })
    }
}

// MARK: - Sleep sync

extension RingSessionManager {
    /// Request sleep data via Colmi Big Data service (dataId 39). Preferred for rings that support it.
    func syncSleep(dayOffset: Int = 0) {
        lastSleepDayOffset = dayOffset
        sendBigDataRequest(dataId: CMD.bigDataSleepId)
    }

    /// Request sleep from Nordic UART Commands protocol (ID 68). Use if Big Data sleep is not supported.
    func syncSleepCommands(dayOffset: Int = 0) {
        do {
            let packet = try makePacket(command: CMD.cmdSleepData, subData: [
                UInt8(dayOffset & 0xFF),
                CMD.sleepQuerySlotCount,
                0,
                CMD.sleepQueryMaxEntries
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
            let packet = try makePacket(command: CMD.cmdSyncSleepLegacy, subData: [0x27])
            appendToDebugLog(direction: .sent, bytes: packet)
            sendPacket(packet: packet)
            tLog("Sleep sync (legacy 0xBC 0x27) requested")
        } catch {
            tLog("Failed to create legacy sleep packet: \(error)")
        }
    }

    private func handleSleepDataResponse(packet: [UInt8]) {
        // SleepDataResponse: commandId=68, year, month, day, time, sleepQualities, unused[3], crc
        guard packet.count >= 6, packet[0] == CMD.cmdSleepData else { return }
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
        lastSleepData = data
    }

    private func handleSleepResponse(packet: [UInt8]) {
        guard packet.count >= 2 else { return }
        let subType = packet[1]
        tLog("Sleep packet (legacy 0xBC) – subType: \(subType) (0x\(String(format: "%02x", subType))), full: \(packet)")
        if subType == 255 {
            tLog("Sleep: no data (ring returned 0xFF subtype)")
        }
    }

    /// Request HRV historical data (Commands protocol, ID 57). dayOffset uses index field.
    func syncHRVData(dayOffset: Int = 0) {
        do {
            let packet = try makePacket(command: CMD.cmdReadHRVData, subData: [UInt8(dayOffset & 0xFF)])
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
            let packet = try makePacket(command: CMD.cmdReadPressureData, subData: [UInt8(dayOffset & 0xFF)])
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
            let packet = try makePacket(command: CMD.cmdSetDeviceTime, subData: [
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
            DispatchQueue.main.asyncAfter(deadline: .now() + RingConstants.bleCommandSpacing) { [weak self] in
                self?.sendActivityRequest(dayOffset: 1)
            }
        }
    }

    private func sendActivityRequest(dayOffset: Int) {
        do {
            let packet = try makePacket(command: CMD.cmdReadActivityData, subData: [
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
        sendBigDataRequest(dataId: CMD.bigDataBloodOxygenId)
    }

    private func handleHRVDataResponse(packet: [UInt8]) {
        guard packet.count >= 2 else { return }
        dataDelegate?.ringDidReceiveHRVPacket(packet)
    }

    private func handlePressureDataResponse(packet: [UInt8]) {
        guard packet.count >= 2 else { return }
        dataDelegate?.ringDidReceivePressurePacket(packet)
    }

    private func handleActivityDataResponse(packet: [UInt8]) {
        guard packet.count >= 2 else { return }
        dataDelegate?.ringDidReceiveActivityPacket(packet)
    }

    // MARK: - Today's Sports (CMD 0x48)

    /// Request today's aggregated step/calorie/distance totals from the ring.
    /// Unlike CMD 67 (15-minute slot history), this returns a single packet
    /// with cumulative totals including a separate `runningSteps` field.
    func requestTodaySports() {
        do {
            let packet = try makePacket(command: CMD.cmdGetStepToday, subData: [])
            appendToDebugLog(direction: .sent, bytes: packet)
            sendPacket(packet: packet)
            tLog("[TodaySports] Requested today's aggregated totals (CMD 0x48)")
        } catch {
            tLog("[TodaySports] Failed to create packet: \(error)")
        }
    }

    /// Parse the CMD 0x48 response.
    ///
    /// Layout matches Gadgetbridge `goalsSettings` / `liveActivity` encoding:
    /// **24-bit big-endian** for steps/running/calories, **16-bit big-endian** for distance/duration.
    ///
    ///   [0]     = 0x48 (command)
    ///   [1..3]  = totalSteps    (24-bit BE) — verified against CMD 0x43 slot sums
    ///   [4..6]  = runningSteps  (24-bit BE) — 0 when no running detected
    ///   [7..9]  = calories      (24-bit BE) — likely includes BMR; may need /10
    ///   [10..12] = walkingDistance in meters (24-bit BE) — verified against CMD 0x43
    ///   [13..14] = activityDuration in minutes (16-bit BE)
    ///   [15]    = CRC
    private func handleTodaySportsResponse(packet: [UInt8]) {
        guard packet.count >= 15 else {
            tLog("[TodaySports] Packet too short (\(packet.count)B)")
            return
        }

        /// Read 24-bit big-endian unsigned at `offset` (3 bytes).
        func readBE24(_ offset: Int) -> Int {
            (Int(packet[offset]) << 16) | (Int(packet[offset + 1]) << 8) | Int(packet[offset + 2])
        }
        /// Read 16-bit big-endian unsigned at `offset` (2 bytes).
        func readBE16(_ offset: Int) -> Int {
            (Int(packet[offset]) << 8) | Int(packet[offset + 1])
        }

        let totalSteps      = readBE24(1)
        let runningSteps    = readBE24(4)
        let calories        = readBE24(7)
        let walkingDistM    = readBE24(10)
        let activityMinutes = readBE16(13)

        let walkingDistKm   = Double(walkingDistM) / 1000.0
        let hex = packet.map { String(format: "%02x", $0) }.joined(separator: " ")

        // Expose running steps for UI
        todayRunningSteps = runningSteps

        tLog("[TodaySports] totalSteps=\(totalSteps) runningSteps=\(runningSteps) cal=\(calories) walkDist=\(walkingDistKm)km activityMin=\(activityMinutes)  raw=\(hex)")
    }

    func sendPacket(packet: [UInt8]) {
        guard let uartRxCharacteristic, let peripheral else {
            tLog("Cannot send packet. Peripheral or characteristic not ready.")
            return
        }

        let data = Data(packet)
        peripheral.writeValue(data, for: uartRxCharacteristic, type: .withResponse)
    }

    // MARK: - Throttled InfluxDB writes (called from packet dispatch)

    private func throttledInfluxHRWrite(bpm: Int, at now: Date) {
        guard now.timeIntervalSince(lastInfluxHRWrite) >= currentInfluxWriteInterval else { return }
        lastInfluxHRWrite = now
        Task { @MainActor in
            InfluxDBWriter.shared.writeHeartRates([(bpm: bpm, time: now)])
        }
    }

    private func throttledInfluxSpO2Write(percent: Int, at now: Date) {
        guard now.timeIntervalSince(lastInfluxSpO2Write) >= currentInfluxWriteInterval else { return }
        lastInfluxSpO2Write = now
        Task { @MainActor in
            InfluxDBWriter.shared.writeSpO2(value: Double(percent), time: now)
        }
    }

    private func throttledInfluxTempWrite(celsius: Double, at now: Date) {
        guard now.timeIntervalSince(lastInfluxTempWrite) >= currentInfluxWriteInterval else { return }
        lastInfluxTempWrite = now
        Task { @MainActor in
            InfluxDBWriter.shared.writeTemperature(celsius: celsius, time: now)
        }
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

        if let first = sportRTBeatSamples.first, sportRTBeatSamples.count >= RingConstants.sportRTMinSamples {
            let elapsed = now.timeIntervalSince(first.time)
            if elapsed >= RingConstants.sportRTMinElapsed {
                // Unwrap the counter (it's UInt8, wraps at 256)
                var totalBeats = 0
                for i in 1 ..< sportRTBeatSamples.count {
                    var delta = Int(sportRTBeatSamples[i].b10) - Int(sportRTBeatSamples[i - 1].b10)
                    if delta < 0 { delta += 256 }  // handle wrap
                    totalBeats += delta
                }
                let derivedBPM = Int(round(Double(totalBeats) * 60.0 / elapsed))
                // Sanity: only accept 30-220 BPM
                if derivedBPM >= Int(RingConstants.validBPMMin) && derivedBPM <= Int(RingConstants.validBPMMax) {
                    sportRTDerivedHR = derivedBPM
                } else {
                    sportRTDerivedHR = nil
                }
            }
        }

        tLog("[SportRT] b4=\(b4) b10=\(b10) derivedHR=\(sportRTDerivedHR.map(String.init) ?? "nil") samples=\(sportRTBeatSamples.count) pkt=\(packet.prefix(11).map { String($0) }.joined(separator: ","))")
    }
}

// MARK: - Raw Sensor Streaming (CMD 0xA1)

extension RingSessionManager {

    /// Start raw sensor streaming (PPG + accelerometer + SpO2).
    /// Sends 0xA1 0x04 on the UART service. Responses arrive on both services.
    func startRawSensorStream() {
        guard peripheralConnected, characteristicsDiscovered else {
            tLog("[RawSensor] Cannot start — not connected")
            return
        }
        do {
            let packet = try makePacket(command: CMD.cmdRawSensor, subData: [CMD.rawSensorEnable])
            sendPacket(packet: packet)
            appendToDebugLog(direction: .sent, bytes: packet)
            rawSensorStreamActive = true
            rawPPGCount = 0; rawAccelCount = 0; rawSpO2Count = 0
            rawStreamStartTime = nil
            tLog("[RawSensor] Streaming ENABLED — sent 0xA1 0x04")
        } catch {
            tLog("[RawSensor] Failed to build enable packet: \(error)")
        }
    }

    /// Stop raw sensor streaming.
    func stopRawSensorStream() {
        guard peripheralConnected else { return }
        do {
            let packet = try makePacket(command: CMD.cmdRawSensor, subData: [CMD.rawSensorDisable])
            sendPacket(packet: packet)
            appendToDebugLog(direction: .sent, bytes: packet)
            rawSensorStreamActive = false
            let elapsed = rawStreamStartTime.map { Date().timeIntervalSince($0) } ?? 0
            tLog("[RawSensor] Streaming DISABLED — PPG:\(rawPPGCount) Accel:\(rawAccelCount) SpO2:\(rawSpO2Count) in \(String(format: "%.1f", elapsed))s")
        } catch {
            tLog("[RawSensor] Failed to build disable packet: \(error)")
        }
    }

    /// Effective sample rate for raw PPG packets (Hz).
    var rawPPGSampleRate: Double {
        guard let start = rawStreamStartTime, rawPPGCount > 1 else { return 0 }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0 else { return 0 }
        return Double(rawPPGCount) / elapsed
    }

    /// Effective sample rate for raw accelerometer packets (Hz).
    var rawAccelSampleRate: Double {
        guard let start = rawStreamStartTime, rawAccelCount > 1 else { return 0 }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0 else { return 0 }
        return Double(rawAccelCount) / elapsed
    }
}

// MARK: - Phone Sport Mode (CMD 0x77 / 0x78)

extension RingSessionManager {

    /// Send a phone sport command: start, pause, resume, or end.
    func sendPhoneSport(action: RingConstants.PhoneSportAction,
                        type: RingConstants.PhoneSportType = .running) {
        do {
            let packet = try makePacket(command: CMD.cmdPhoneSport,
                                        subData: [action.rawValue, type.rawValue])
            appendToDebugLog(direction: .sent, bytes: packet)
            sendPacket(packet: packet)
            tLog("[PhoneSport] Sent action=\(action.rawValue) sportType=\(type.rawValue)")

            if action == .start {
                phoneSportActive = true
                phoneSportSteps = 0
                phoneSportDistanceM = 0
                phoneSportHR = 0
                phoneSportCalories = 0
                phoneSportDurationSec = 0
                phoneSportElapsedAccumulator = 0
                phoneSportLastRawElapsed = 0
            } else if action == .end {
                phoneSportActive = false
            }
        } catch {
            tLog("[PhoneSport] Failed to create packet: \(error)")
        }
    }

    /// Handle 0x77 response — ring echoes back the action code.
    func handlePhoneSportResponse(packet: [UInt8]) {
        guard packet.count >= 2 else { return }
        let status = packet[1]
        tLog("[PhoneSport] Response status=\(status) raw=\(packet.prefix(6).map { String(format: "%02x", $0) }.joined(separator: " "))")
    }

    /// Handle 0x78 notification — real-time sport telemetry from the ring.
    ///
    /// Layout (empirically verified from live packet captures, 2026-03-19):
    ///   [0]      = 0x78 (command)
    ///   [1]      = sportType echoed (e.g. 7=running) — NOT status
    ///   [2]      = status flag (1=active, 3=ring-ended)
    ///   [3]      = unknown (always 0)
    ///   [4]      = elapsed seconds (uint8, 0-255; wraps for long sessions)
    ///   [5]      = heart rate (BPM, uint8)
    ///   [6..8]   = distance in meters (24-bit BE)
    ///   [9..11]  = steps (24-bit BE)
    ///   [12..14] = calories (24-bit BE, milli-kcal ÷1000 = kcal)
    ///   [15]     = CRC
    func handlePhoneSportNotify(packet: [UInt8]) {
        guard packet.count >= 15 else {
            tLog("[PhoneSportNotify] Packet too short (\(packet.count)B)")
            return
        }

        func readBE24(_ offset: Int) -> Int {
            (Int(packet[offset]) << 16) | (Int(packet[offset + 1]) << 8) | Int(packet[offset + 2])
        }

        let sportType = packet[1]
        let status    = packet[2]
        let elapsed   = Int(packet[4])
        let hr        = Int(packet[5])
        let distance  = readBE24(6)
        let steps     = readBE24(9)
        let calories  = readBE24(12)

        // Detect uint8 wrap: byte[4] is a uint8 (0-255) that wraps for workouts >4:15.
        // Packets arrive ~1/s, so a large backward jump means a wrap occurred.
        if phoneSportLastRawElapsed > elapsed && (phoneSportLastRawElapsed - elapsed) > 200 {
            phoneSportElapsedAccumulator += 256
            tLog("[PhoneSportNotify] Elapsed uint8 wrap detected: \(phoneSportLastRawElapsed) -> \(elapsed), accumulator now \(phoneSportElapsedAccumulator)")
        }
        phoneSportLastRawElapsed = elapsed
        phoneSportDurationSec = phoneSportElapsedAccumulator + elapsed

        phoneSportHR = hr
        phoneSportSteps = steps
        phoneSportDistanceM = distance
        phoneSportCalories = calories / 1000  // milli-kcal → kcal

        tLog("[PhoneSportNotify] type=\(sportType) status=\(status) elapsed=\(phoneSportDurationSec)s(raw:\(elapsed)) hr=\(hr) steps=\(steps) dist=\(distance)m cal=\(calories)mCal raw=\(packet.prefix(15).map { String(format: "%02x", $0) }.joined(separator: " "))")

        // If status 3 — ring autonomously ended the session
        if status == 3 {
            tLog("[PhoneSportNotify] Ring ended sport session autonomously")
            phoneSportActive = false
        }
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
            let packet = try makePacket(command: CMD.cmdRealTimeHeartRate, subData: [3])
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

    /// Mark the HR stream as "just restarted" so the gym watchdog doesn't
    /// immediately re-fire.  Avoids GymSessionManager mutating our property directly.
    func resetHRPacketTimestamp() {
        lastRealTimeHRPacketTime = Date()
    }

    func continueRealTimeStreaming(type: RealTimeReading) {
        tLog("[RealTime] CONTINUE \(type)")
        sendRealTimeCommand(command: CMD.cmdStartRealTime, type: type, action: .continue)
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
        // Use the centralized transition so teardown (timer cancellation,
        // BLE stop commands, reading array cleanup) is handled uniformly.
        transitionSensor(to: .idle)
        scheduleNextKeepalive()
    }

    // MARK: Raw BLE command helpers

    /// Send a 0x69 start command (does NOT update sensorState).
    private func sendRealTimeStart(type: RealTimeReading) {
        sendRealTimeCommand(command: CMD.cmdStartRealTime, type: type, action: .start)
    }

    /// Send a 0x6A stop command (does NOT update sensorState).
    private func sendRealTimeStop(type: RealTimeReading) {
        sendRealTimeCommand(command: CMD.cmdStopRealTime, type: type, action: nil)
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
            let packet = try makePacket(command: CMD.cmdStopRealTime, subData: [RealTimeReading.spo2.rawValue])
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
        case .spo2:                        timeoutSeconds = RingConstants.spotCheckTimeoutSpO2
        case .temperature:                 timeoutSeconds = RingConstants.spotCheckTimeoutTemp
        case .realtimeHeartRate, .heartRate: timeoutSeconds = RingConstants.spotCheckTimeoutHR
        default:                           timeoutSeconds = RingConstants.spotCheckTimeoutDefault
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
                let tail = Array(allReadings.suffix(RingConstants.spotCheckMedianWindowSize))
                let inRange = tail.filter { $0 >= RingConstants.bodyTempRangeMin && $0 <= RingConstants.bodyTempRangeMax }

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
                    let tail = Array(allReadings.suffix(RingConstants.spotCheckMedianWindowSize))
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
            let packet = try makePacket(command: CMD.cmdStartRealTime, subData: payload)
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
            let packet = try makePacket(command: CMD.cmdBattery)
            let data = Data(packet)
            peripheral.writeValue(data, for: uartRxCharacteristic, type: .withResponse)
            
            // Store completion handler to call when data is received
            self.batteryStatusCallback = completion
        } catch {
            tLog("Failed to create battery packet: \(error)")
        }
    }
    
    private func handleBatteryResponse(packet: [UInt8]) {
        guard packet[0] == CMD.cmdBattery else {
            tLog("Invalid battery packet received.")
            return
        }

        let batteryLevel = Int(packet[1])
        let charging = packet[2] != 0
        let batteryInfo = BatteryInfo(batteryLevel: batteryLevel, charging: charging)
        currentBatteryInfo = batteryInfo

        // Stream battery level to InfluxDB and record for drain-rate estimation.
        let now = Date()
        Task { @MainActor in
            InfluxDBWriter.shared.writeBattery(level: batteryLevel, charging: charging, time: now)
        }
        batteryEstimator.record(level: batteryLevel, charging: charging)

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
            if stalledSeconds > RingConstants.keepaliveInterval * RingConstants.keepaliveStallMultiplier && !spotCheckActive {
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
            if keepalivePingCount % RingConstants.spotCheckSpO2EveryNPings == 0 && keepalivePingCount > 0 {
                type = .spo2
            } else if keepalivePingCount % RingConstants.spotCheckTempEveryNPings == 0 && keepalivePingCount > 0 {
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
        if keepalivePingCount >= RingConstants.fullSyncEveryNPings {
            keepalivePingCount = 0
            fullSyncCycleCount += 1
            if sensorState == .idle || spotCheckActive {
                tLog("[Keepalive] Full sync triggered (every \(RingConstants.fullSyncEveryNPings) pings)")
                // Stagger syncs so commands don't pile up on the ring.
                // Start after 20 s — gives the spot-check time to finish first.
                fullSyncScheduler.run([
                    .init(delay: 20) { [weak self] in self?.getHeartRateLog(dayOffset: 0) { _ in } },
                    .init(delay: 22) { [weak self] in self?.getHeartRateLog(dayOffset: 1) { _ in } },
                    .init(delay: 24) { [weak self] in self?.syncHRVData(dayOffset: 0) },
                    .init(delay: 26) { [weak self] in self?.syncBloodOxygen(dayOffset: 0) },
                    .init(delay: 28) { [weak self] in self?.syncPressureData(dayOffset: 0) },
                    .init(delay: 30) { [weak self] in self?.syncActivityData(dayOffset: 0) },
                    .init(delay: 31) { [weak self] in self?.requestTodaySports() },
                    // Re-check HR log settings — the ring firmware resets them
                    // on its own midnight reboot cycle.
                    .init(delay: 32) { [weak self] in
                        guard let self else { return }
                        Task { @MainActor in await self.ensureHRLogSettings() }
                    },
                ], cancelIf: { [weak self] in self?.isWorkoutActive ?? false })
            }
        }
    }
}

// MARK: - Tracking Settings & HR Log Settings (delegated to RingTrackingSettingsManager)

extension RingSessionManager {
    func getTrackingSetting(_ setting: RingTrackingSetting, completion: @escaping (Bool) -> Void) {
        trackingSettings.getTrackingSetting(setting, completion: completion)
    }

    func readTrackingSetting(_ setting: RingTrackingSetting) async throws -> Bool {
        try await trackingSettings.readTrackingSetting(setting)
    }

    func writeTrackingSetting(_ setting: RingTrackingSetting, enabled: Bool) async throws {
        try await trackingSettings.writeTrackingSetting(setting, enabled: enabled)
    }

    func readHRLogSettings() async throws -> (enabled: Bool, intervalMinutes: Int) {
        try await trackingSettings.readHRLogSettings()
    }

    func writeHRLogSettings(enabled: Bool, intervalMinutes: Int) async throws {
        try await trackingSettings.writeHRLogSettings(enabled: enabled, intervalMinutes: intervalMinutes)
    }
}

// MARK: - Heart Rate Log

extension RingSessionManager {
    /// The ring clock is set to UTC, so its internal "day" runs midnight-to-midnight UTC.
    /// We must request HR logs using UTC day boundaries so the ring returns the correct data.
    private func dayStartInUTC(for base: Date = Date(), dayOffset: Int = 0) -> Date? {
        let start = RingSlotTimestamp.utcStartOfDay(for: base)
        guard dayOffset != 0 else { return start }
        return Calendar(identifier: .gregorian).date(byAdding: .day, value: -dayOffset, to: start)
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

            // Map the UTC target to the correct LOCAL day for persistence/UI.
            // dayOffset=0 → today local, dayOffset=1 → yesterday local, etc.
            let localDayStart = Calendar.current.startOfDay(
                for: Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date.now) ?? Date.now
            )
            self.heartRateLogUTCToLocalDay[target] = localDayStart
            tLog("HRL Command Sent (dayOffset: \(dayOffset), utcTarget: \(target), localDay: \(localDayStart), map=\(heartRateLogUTCToLocalDay.count))")

            // Store completion handler to call when data is received
            self.heartRateLogCallback = completion
        } catch {
            tLog("Failed to create hrl packet: \(error)")
        }
    }

    private func handleHeartRateLogResponse(packet: [UInt8]) {
        guard packet[0] == CMD.cmdReadHeartRate else {
            tLog("Invalid heart rate log packet received.")
            return
        }

        let result = hrp.parse(packet: packet)

        switch result {
        case .assembling:
            return
        case .noData:
            tLog("[HRL] No data from ring (subType=0xFF), map=\(heartRateLogUTCToLocalDay.count)")
            return
        case .complete:
            break
        }

        guard case .complete(let log) = result else { return }

        // Look up the local day from our UTC→local map using the ring's timestamp.
        // The ring echoes back the UTC midnight we requested, so this is a direct key match.
        // This avoids FIFO ordering issues — the map is keyed, not sequential.
        let ringUTCDay = RingSlotTimestamp.utcStartOfDay(for: log.timestamp)

        let requestedDay: Date
        if let mapped = heartRateLogUTCToLocalDay.removeValue(forKey: ringUTCDay) {
            requestedDay = mapped
            tLog("[HRL] Mapped UTC \(ringUTCDay) → local \(mapped)")
        } else {
            // Fallback: compute local day from dayOffset=0 assumption
            requestedDay = Calendar.current.startOfDay(for: Date.now)
            tLog("[HRL] WARNING: No map entry for UTC \(ringUTCDay) — falling back to today local \(requestedDay)")
        }
        tLog("[HRL] Parsed log: ringTimestamp=\(log.timestamp) localDay=\(requestedDay) range=\(log.range)min nonZero=\(log.heartRates.filter { $0 > 0 }.count) mapRemaining=\(heartRateLogUTCToLocalDay.count)")
        dataDelegate?.ringDidReceiveHeartRateLog(log, requestedDay: requestedDay)
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
