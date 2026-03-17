//
//  SensorState.swift
//  Biosense
//
//  Unified PPG sensor state for the ring's single VC30F sensor.
//

import Foundation

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
