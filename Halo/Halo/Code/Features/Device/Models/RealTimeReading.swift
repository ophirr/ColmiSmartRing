//
//  RealTimeReading.swift
//  Halo
//
//  Created by Yannis De Cleene on 26/01/2025.
//

import Foundation

enum RealTimeReading: UInt8 {
    case heartRate = 1
    case bloodPressure = 2
    case spo2 = 3
    case fatigue = 4
    case healthCheck = 5
    /// Continuous real-time HR — responses arrive on command 30 (0x1E)
    /// instead of command 105 (0x69).  May provide longer/continuous
    /// PPG measurement compared to heartRate (DataType 1).
    case realtimeHeartRate = 6
    case ecg = 7
    case pressure = 8
    case bloodSugar = 9
    case hrv = 10
    case temperature = 11
}

enum Action: UInt8 {
    case start = 1
    case pause = 2
    case `continue` = 3
    case stop = 4
}
