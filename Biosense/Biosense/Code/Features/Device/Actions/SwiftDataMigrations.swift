import Foundation
import SwiftData

/// One-time data migrations run at app launch.
///
/// Each migration is gated by a UserDefaults flag so it only runs once.
/// These address bugs from earlier versions where data was stored with
/// incorrect timestamps or missing fields.
@MainActor
enum SwiftDataMigrations {

    /// Purge all StoredActivitySample rows — the old parser stored every sample
    /// with today's date regardless of actual date, so the DB is unreliable.
    /// The next ring sync will repopulate with correctly-dated data.
    static func purgeStaleActivitySamples(context: ModelContext) {
        let key = AppSettings.Migration.activityParserV4
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        do {
            let all = try context.fetch(FetchDescriptor<StoredActivitySample>())
            guard !all.isEmpty else {
                UserDefaults.standard.set(true, forKey: key)
                return
            }
            for sample in all { context.delete(sample) }
            try context.save()
            tLog("[ActivityMigration] Purged \(all.count) stale activity samples")
        } catch {
            tLog("[ActivityMigration] Purge failed: \(error)")
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Backfill `nightDate` for StoredSleepDay records created before the field existed.
    /// After lightweight migration these rows have `Date.distantPast`; recompute from
    /// `syncDate` and `daysAgo`.
    static func backfillSleepNightDates(context: ModelContext) {
        let key = AppSettings.Migration.sleepNightDateBackfill
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        do {
            let sentinel = Date.distantPast
            let descriptor = FetchDescriptor<StoredSleepDay>(
                predicate: #Predicate<StoredSleepDay> { $0.nightDate == sentinel }
            )
            let stale = try context.fetch(descriptor)
            guard !stale.isEmpty else {
                UserDefaults.standard.set(true, forKey: key)
                return
            }
            let calendar = Calendar.current
            for day in stale {
                let base = calendar.startOfDay(for: day.syncDate)
                day.nightDate = calendar.date(byAdding: .day, value: -day.daysAgo, to: base) ?? base
            }
            try context.save()
            tLog("[SleepMigration] Backfilled nightDate for \(stale.count) sleep records")
        } catch {
            tLog("[SleepMigration] Backfill failed: \(error)")
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Purge HR logs that were stored with wrong dayStart due to
    /// the race condition bug (single requestedDay variable overwritten by
    /// concurrent requests). Next sync will re-populate with correct dates.
    static func purgeStaleHeartRateLogs(context: ModelContext) {
        let key = AppSettings.Migration.hrLogUTCPurgeV4
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        do {
            let all = try context.fetch(FetchDescriptor<StoredHeartRateLog>())
            guard !all.isEmpty else {
                UserDefaults.standard.set(true, forKey: key)
                return
            }
            for log in all { context.delete(log) }
            try context.save()
            tLog("[HRLogMigration] Purged \(all.count) stale HR logs (dayStart race fix)")
        } catch {
            tLog("[HRLogMigration] Purge failed: \(error)")
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Run all pending one-time migrations.
    static func runAll(context: ModelContext) {
        purgeStaleActivitySamples(context: context)
        backfillSleepNightDates(context: context)
        purgeStaleHeartRateLogs(context: context)
    }
}
