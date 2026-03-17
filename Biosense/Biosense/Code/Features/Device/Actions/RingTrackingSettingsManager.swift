//
//  RingTrackingSettingsManager.swift
//  Biosense
//
//  Manages async read/write of ring tracking settings (HRV, HR, SpO2, Pressure)
//  and HR log interval settings. Owns the continuation state for in-flight
//  requests. RingSessionManager delegates to this and keeps the @Observable
//  properties.
//

import Foundation
import CoreBluetooth

final class RingTrackingSettingsManager {

    private typealias CMD = RingConstants

    // MARK: - Callbacks (wired by RingSessionManager)

    /// Send a raw 16-byte packet on UART. RSM provides the implementation.
    var sendPacket: (([UInt8]) -> Void)?
    /// Send a settings-protocol packet (commandId, action, 13-byte data).
    /// RSM provides: { [weak self] cmd, action, data in ... makeSettingsPacket + writeValue }
    var sendSettingsPacket: ((UInt8, UInt8, [UInt8]) -> Void)?
    /// Append to the BLE debug log.
    var appendToDebugLog: ((RingSessionManager.DebugLogEntry.Direction, [UInt8]) -> Void)?
    /// Called when HR log settings are updated (from a read response).
    /// RSM uses this to update its @Observable properties.
    var onHRLogSettingsUpdated: ((_ enabled: Bool, _ intervalMinutes: Int) -> Void)?
    /// Check whether the ring is connected (UART characteristic + peripheral available).
    var isConnected: (() -> Bool)?

    // MARK: - Tracking Settings State

    private var pendingTrackingSetting: RingTrackingSetting?
    private var pendingTrackingSettingCallback: ((Bool) -> Void)?
    private var pendingTrackingSettingContinuation: CheckedContinuation<Bool, Error>?
    private var trackingSettingGeneration: UInt = 0

    // MARK: - HR Log Settings State

    private var pendingHRLogSettingsContinuation: CheckedContinuation<(enabled: Bool, intervalMinutes: Int), Error>?

    // MARK: - Tracking Settings Public API

    /// Request current enabled state for one tracking setting (callback-based).
    func getTrackingSetting(_ setting: RingTrackingSetting, completion: @escaping (Bool) -> Void) {
        pendingTrackingSetting = setting
        pendingTrackingSettingCallback = completion
        sendSettingRead(commandId: setting.commandId)
    }

    /// Read one tracking setting from the ring (async).
    func readTrackingSetting(_ setting: RingTrackingSetting) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            guard isConnected?() == true else {
                continuation.resume(throwing: RingSessionTrackingError.notConnected)
                return
            }
            trackingSettingGeneration &+= 1
            let gen = trackingSettingGeneration
            pendingTrackingSetting = setting
            pendingTrackingSettingContinuation = continuation
            sendSettingRead(commandId: setting.commandId)

            DispatchQueue.main.asyncAfter(deadline: .now() + CMD.trackingSettingTimeout) { [weak self] in
                guard let self, self.trackingSettingGeneration == gen, self.pendingTrackingSettingContinuation != nil else { return }
                tLog("[TrackingSetting] Timeout waiting for \(setting.displayName) read response")
                self.pendingTrackingSettingContinuation = nil
                self.pendingTrackingSetting = nil
                continuation.resume(throwing: RingSessionTrackingError.timeout)
            }
        }
    }

    /// Write one tracking setting to the ring (async).
    func writeTrackingSetting(_ setting: RingTrackingSetting, enabled: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            guard isConnected?() == true else {
                continuation.resume(throwing: RingSessionTrackingError.notConnected)
                return
            }
            trackingSettingGeneration &+= 1
            let gen = trackingSettingGeneration
            pendingTrackingSetting = setting
            pendingTrackingSettingContinuation = continuation
            sendSettingWrite(commandId: setting.commandId, isEnabled: enabled)

            DispatchQueue.main.asyncAfter(deadline: .now() + CMD.trackingSettingTimeout) { [weak self] in
                guard let self, self.trackingSettingGeneration == gen, self.pendingTrackingSettingContinuation != nil else { return }
                tLog("[TrackingSetting] Timeout waiting for \(setting.displayName) write response — assuming success")
                self.pendingTrackingSettingContinuation = nil
                self.pendingTrackingSetting = nil
                continuation.resume(returning: enabled)
            }
        }
    }

    // MARK: - HR Log Settings Public API

    /// Read the current HR log settings (enabled + interval) from the ring.
    func readHRLogSettings() async throws -> (enabled: Bool, intervalMinutes: Int) {
        try await withCheckedThrowingContinuation { continuation in
            guard isConnected?() == true else {
                continuation.resume(throwing: RingSessionTrackingError.notConnected)
                return
            }
            pendingHRLogSettingsContinuation = continuation
            do {
                let packet = try makePacket(command: CMD.cmdHRTimingMonitor)
                appendToDebugLog?(.sent, packet)
                sendPacket?(packet)
            } catch {
                pendingHRLogSettingsContinuation = nil
                continuation.resume(throwing: error)
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + CMD.trackingSettingTimeout) { [weak self] in
                guard let self, let continuation = self.pendingHRLogSettingsContinuation else { return }
                tLog("[HRLogSettings] Timeout waiting for read response")
                self.pendingHRLogSettingsContinuation = nil
                continuation.resume(throwing: RingSessionTrackingError.timeout)
            }
        }
    }

    /// Write HR log settings to the ring.
    func writeHRLogSettings(enabled: Bool, intervalMinutes: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard isConnected?() == true else {
                continuation.resume(throwing: RingSessionTrackingError.notConnected)
                return
            }
            do {
                let subData: [UInt8] = [
                    enabled ? 1 : 0,
                    UInt8(clamping: intervalMinutes)
                ]
                let packet = try makePacket(command: CMD.cmdHRTimingMonitor, subData: subData)
                appendToDebugLog?(.sent, packet)
                sendPacket?(packet)
                onHRLogSettingsUpdated?(enabled, intervalMinutes)
                tLog("[HRLogSettings] Wrote enabled=\(enabled), interval=\(intervalMinutes)min")
                continuation.resume()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Response Handlers (called by RSM's packet dispatch)

    func handleTrackingSettingResponse(packet: [UInt8]) {
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

    func handleHRTimingMonitorResponse(packet: [UInt8]) {
        guard packet.count >= 3, packet[0] == CMD.cmdHRTimingMonitor else {
            tLog("[HRLogSettings] Invalid HR timing monitor packet: \(packet)")
            return
        }

        // Command 22 is overloaded: it serves both the HR timing monitor
        // (interval read/write) and the HR tracking setting (enable/disable).
        // The settings-protocol responses use packet[1] as an action byte
        // (1=read, 2=write), while timing monitor uses it as the enabled flag.
        //
        // If there's a pending tracking-setting continuation for .heartRate,
        // this response is actually for that — resume it with the enabled state.
        if pendingTrackingSetting == .heartRate {
            let isEnabled = packet[2] != 0
            if let continuation = pendingTrackingSettingContinuation {
                pendingTrackingSettingContinuation = nil
                pendingTrackingSetting = nil
                continuation.resume(returning: isEnabled)
                return
            } else if let callback = pendingTrackingSettingCallback {
                pendingTrackingSettingCallback = nil
                pendingTrackingSetting = nil
                callback(isEnabled)
                return
            }
        }

        let enabled = packet[1] != 0
        let interval = Int(packet[2])
        onHRLogSettingsUpdated?(enabled, interval)
        tLog("[HRLogSettings] Response: enabled=\(enabled), interval=\(interval)min")

        if let continuation = pendingHRLogSettingsContinuation {
            pendingHRLogSettingsContinuation = nil
            continuation.resume(returning: (enabled: enabled, intervalMinutes: interval))
        }
    }

    // MARK: - Disconnect Cleanup

    /// Resume any pending continuations with errors so callers don't hang.
    func cancelPendingRequests() {
        if let continuation = pendingTrackingSettingContinuation {
            tLog("[Disconnect] Resuming leaked tracking-setting continuation")
            pendingTrackingSettingContinuation = nil
            pendingTrackingSetting = nil
            trackingSettingGeneration &+= 1
            continuation.resume(throwing: RingSessionTrackingError.notConnected)
        }
        pendingTrackingSettingCallback = nil

        if let continuation = pendingHRLogSettingsContinuation {
            tLog("[Disconnect] Resuming leaked HR-log-settings continuation")
            pendingHRLogSettingsContinuation = nil
            continuation.resume(throwing: RingSessionTrackingError.notConnected)
        }
    }

    // MARK: - Private Helpers

    private func sendSettingRead(commandId: UInt8) {
        let data = [UInt8](repeating: 0, count: 13)
        sendSettingsPacket?(commandId, CMD.settingsActionRead, data)
    }

    private func sendSettingWrite(commandId: UInt8, isEnabled: Bool) {
        var data = [UInt8](repeating: 0, count: 13)
        data[0] = isEnabled ? 1 : 0
        sendSettingsPacket?(commandId, CMD.settingsActionWrite, data)
    }
}
