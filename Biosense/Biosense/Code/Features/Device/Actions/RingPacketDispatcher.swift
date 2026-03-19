//
//  RingPacketDispatcher.swift
//  Biosense
//
//  Pure-function packet parser: converts raw BLE bytes into typed results.
//  No side effects — RingSessionManager handles state mutation.
//

import Foundation

/// Semantic result of parsing one BLE UART packet from the ring.
/// The dispatcher extracts meaning from raw bytes; RSM acts on it.
enum RingPacketResult {

    // MARK: - Real-time readings (command 0x69)

    /// Valid HR reading (30-220 BPM).
    case heartRateReading(bpm: Int, timestamp: Date)
    /// HR value is zero (sensor warmup / no skin contact).
    case heartRateZero(timestamp: Date)
    /// HR value outside valid range.
    case heartRateOutOfRange(value: UInt8, timestamp: Date)
    /// Valid SpO2 reading (70-100%).
    case spo2Reading(percent: Int, timestamp: Date)
    /// SpO2 value outside valid range.
    case spo2OutOfRange(value: UInt8)
    /// Temperature reading (may be uncalibrated — caller decides if in body range).
    case temperatureReading(celsius: Double, timestamp: Date)
    /// Real-time reading error from ring.
    case readingError(type: RealTimeReading, errorCode: UInt8)

    // MARK: - Command 0x1E (RT HR via DataType=6)

    /// Valid HR from command 30.
    case rtHR(bpm: Int, timestamp: Date)
    /// HR zero from command 30 (warmup).
    case rtHRZero(timestamp: Date)
    /// HR out of range from command 30.
    case rtHROutOfRange(value: UInt8)

    // MARK: - Stop / notification packets

    /// HR auto-stop notification (ring stopped streaming).
    case hrAutoStop
    /// SpO2 data on the stop channel (pathway A).
    case spo2StopPathwayData(percent: Int)
    /// SpO2 pathway A stop notification (0x6B).
    case spo2StopNotification(packet: [UInt8])

    // MARK: - Data responses (opaque — RSM routes to existing handlers)

    case batteryResponse(packet: [UInt8])
    case heartRateLogResponse(packet: [UInt8])
    case hrTimingMonitorResponse(packet: [UInt8])
    case sleepDataResponse(packet: [UInt8])
    case sleepLegacyResponse(packet: [UInt8])
    case hrvDataResponse(packet: [UInt8])
    case pressureDataResponse(packet: [UInt8])
    case activityDataResponse(packet: [UInt8])
    /// Today's aggregated step totals (CMD 0x48).
    case todaySportsResponse(packet: [UInt8])
    case trackingSettingResponse(packet: [UInt8])
    case sportRealTimeResponse(packet: [UInt8])
    /// Phone sport mode ack (CMD 0x77) — ring echoes back the action.
    case phoneSportResponse(packet: [UInt8])
    /// Phone sport notification (CMD 0x78) — real-time steps/HR/dist/cal during sport session.
    case phoneSportNotify(packet: [UInt8])

    // MARK: - Misc

    case timeSyncAck(success: Bool)
    case counterX
    case ack
    case packetTooShort
    case unhandled(opcode: UInt8, packet: [UInt8])
}

/// Pure-function packet dispatcher. Converts raw BLE bytes to typed results.
enum RingPacketDispatcher {

    private typealias CMD = RingConstants

    /// Parse a raw UART packet into a semantic result. No side effects.
    static func dispatch(_ packet: [UInt8]) -> RingPacketResult {
        guard !packet.isEmpty else { return .packetTooShort }

        switch packet[0] {

        // MARK: Time sync
        case CMD.cmdSetDeviceTime:
            return .timeSyncAck(success: packet.count >= 2 && packet[1] == 0)

        // MARK: Data responses (opaque delegation)
        case CMD.cmdBattery:
            return .batteryResponse(packet: packet)
        case CMD.cmdReadHeartRate:
            return .heartRateLogResponse(packet: packet)
        case CMD.cmdHRTimingMonitor:
            return .hrTimingMonitorResponse(packet: packet)
        case CMD.cmdSleepData:
            return .sleepDataResponse(packet: packet)
        case CMD.cmdSyncSleepLegacy:
            return .sleepLegacyResponse(packet: packet)
        case CMD.cmdReadHRVData:
            return .hrvDataResponse(packet: packet)
        case CMD.cmdReadPressureData:
            return .pressureDataResponse(packet: packet)
        case CMD.cmdReadActivityData:
            return .activityDataResponse(packet: packet)
        case CMD.cmdGetStepToday:
            return .todaySportsResponse(packet: packet)
        case CMD.cmdHRVSetting, CMD.cmdHeartRateSetting, CMD.cmdBloodOxygen, CMD.cmdPressureSetting:
            return .trackingSettingResponse(packet: packet)
        case CMD.cmdSportRealTime:
            return .sportRealTimeResponse(packet: packet)
        case CMD.cmdPhoneSport:
            return .phoneSportResponse(packet: packet)
        case CMD.cmdPhoneSportNotify:
            return .phoneSportNotify(packet: packet)

        // MARK: Real-time readings (0x69)
        case CMD.cmdStartRealTime:
            return parseRealTimeReading(packet)

        // MARK: RT HR via command 30 (0x1E)
        case CMD.cmdRealTimeHeartRate:
            return parseRT30(packet)

        // MARK: Stop / pathway notifications
        case CMD.cmdStopRealTime:
            return parseStopPacket(packet)
        case CMD.cmdPathwayAStop:
            return .spo2StopNotification(packet: packet)

        // MARK: Acks and special
        case Counter.shared.CMD_X:
            return .counterX
        case CMD.cmdRealTimeHeartRateAck:
            return .ack
        case CMD.cmdPacketSize:
            return .ack  // Packet size negotiation — safe to ignore

        default:
            return .unhandled(opcode: packet[0], packet: packet)
        }
    }

    // MARK: - Private parsing helpers

    private static func parseRealTimeReading(_ packet: [UInt8]) -> RingPacketResult {
        guard packet.count >= 4 else { return .packetTooShort }
        guard let readingType = RealTimeReading(rawValue: packet[1]) else {
            return .unhandled(opcode: packet[0], packet: packet)
        }
        let errorCode = packet[2]
        guard errorCode == 0 else {
            return .readingError(type: readingType, errorCode: errorCode)
        }
        let value = packet[3]
        let now = Date()

        switch readingType {
        case .heartRate, .realtimeHeartRate:
            if value == 0 { return .heartRateZero(timestamp: now) }
            guard value >= CMD.validBPMMin, value <= CMD.validBPMMax else {
                return .heartRateOutOfRange(value: value, timestamp: now)
            }
            return .heartRateReading(bpm: Int(value), timestamp: now)

        case .spo2:
            guard value >= UInt8(clamping: CMD.spo2RangeMin),
                  value <= UInt8(clamping: CMD.spo2RangeMax) else {
                return .spo2OutOfRange(value: value)
            }
            return .spo2Reading(percent: Int(value), timestamp: now)

        case .temperature:
            guard packet.count >= 8 else { return .packetTooShort }
            let rawTemp = Int(packet[6]) | (Int(packet[7]) << 8)
            guard rawTemp > 0 else { return .packetTooShort }
            let celsius = Double(rawTemp) / CMD.tempRawDivisor
            return .temperatureReading(celsius: celsius, timestamp: now)

        default:
            return .unhandled(opcode: packet[0], packet: packet)
        }
    }

    private static func parseRT30(_ packet: [UInt8]) -> RingPacketResult {
        let hrValue = packet[1]
        let now = Date()
        if hrValue == 0 {
            return .rtHRZero(timestamp: now)
        } else if hrValue >= CMD.validBPMMin, hrValue <= CMD.validBPMMax {
            return .rtHR(bpm: Int(hrValue), timestamp: now)
        } else {
            return .rtHROutOfRange(value: hrValue)
        }
    }

    private static func parseStopPacket(_ packet: [UInt8]) -> RingPacketResult {
        // 0x6A serves double duty:
        //   (a) HR auto-stop notification (Pathway B)
        //   (b) Pathway A data response (SpO2) — packet[1]=DataType, packet[2]=error, packet[3]=value
        if packet.count >= 4,
           let dataType = RealTimeReading(rawValue: packet[1]),
           dataType == .spo2 {
            let errorCode = packet[2]
            let value = packet[3]
            if errorCode == 0, value > 0, value <= 100 {
                return .spo2StopPathwayData(percent: Int(value))
            }
        }
        return .hrAutoStop
    }
}
