//
//  AppSettings.swift
//  Biosense
//
//  Centralized UserDefaults key constants. All persisted preferences
//  reference these instead of hardcoded strings, so key typos become
//  compile-time errors.
//

import Foundation

enum AppSettings {

    /// Full version string shown in the Profile view.
    /// Update this on each commit (matches git tag).
    static let appVersion = "1.5.7"

    // MARK: - Ring identity & connection

    enum Ring {
        static let savedIdentifier = "savedRingIdentifier"
        static let savedDisplayName = "savedRingDisplayName"
        static let preferredTimeZone = "preferredDataTimeZoneIdentifier"
        static let hrLogInterval = "hrLogInterval"
    }

    // MARK: - Cloud sync (InfluxDB)

    enum CloudSync {
        static let enabled = "cloudSyncEnabled"
    }

    enum InfluxDB {
        static let url = "influxdb.url"
        static let org = "influxdb.org"
        static let bucket = "influxdb.bucket"
        static let token = "influxdb.token"  // legacy — migrated to Keychain
        static let activeTag = "influxdb.activeTag"
    }

    // MARK: - Gym workout

    enum Gym {
        static let zoneConfig = "gymZoneConfig"
        static let ringFinger = "gymRingFinger"
        static let hapticsEnabled = "gymHapticsEnabled"
    }

    // MARK: - Data migration flags

    enum Migration {
        static let activityParserV4 = "activityParserV4Migrated"
        static let sleepNightDateBackfill = "sleepNightDateBackfilled"
        static let hrLogUTCPurgeV4 = "hrLogUTCMapFixPurgeV4"
    }
}
