//
//  RingDataDelegate.swift
//  Biosense
//
//  Protocol for receiving parsed ring data. Replaces the 7 individual
//  persistence callback closures on RingSessionManager with a single
//  typed delegate interface.
//

import Foundation

protocol RingDataDelegate: AnyObject {
    func ringDidReceiveSleepData(_ data: BigDataSleepData)
    func ringDidReceiveHeartRateLog(_ log: HeartRateLog, requestedDay: Date)
    func ringDidReceiveActivityPacket(_ packet: [UInt8])
    func ringDidReceiveHRVPacket(_ packet: [UInt8])
    func ringDidReceivePressurePacket(_ packet: [UInt8])
    func ringDidReceiveBloodOxygenPayload(_ payload: [UInt8])
    func ringDidReceiveSpotCheckSpO2(percent: Int, time: Date)
}
