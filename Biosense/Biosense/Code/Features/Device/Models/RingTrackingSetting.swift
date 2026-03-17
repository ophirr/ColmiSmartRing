//
//  RingTrackingSetting.swift
//  Biosense
//
//  Settings-protocol tracking toggles and error types for ring communication.
//

import Foundation

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

/// Errors for async tracking-setting and HR log settings operations.
enum RingSessionTrackingError: Error {
    case notConnected
    case timeout
}
