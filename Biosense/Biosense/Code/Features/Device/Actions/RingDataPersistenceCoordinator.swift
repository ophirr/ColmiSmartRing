import Foundation
import SwiftData

@MainActor
final class RingDataPersistenceCoordinator {
    private let modelContext: ModelContext
    private unowned let ringSessionManager: RingSessionManager

    private var hrvSeriesAccumulator = SplitSeriesPacketParser.SeriesAccumulator()
    private var stressSeriesAccumulator = SplitSeriesPacketParser.SeriesAccumulator()
    private let healthSleepWriter = AppleHealthSleepWriter()
    private let healthActivityWriter = AppleHealthActivityWriter()
    private let influx = InfluxDBWriter.shared

    private static let logDateFormatter = ISO8601DateFormatter()

    init(modelContext: ModelContext, ringSessionManager: RingSessionManager) {
        self.modelContext = modelContext
        self.ringSessionManager = ringSessionManager
        if UserDefaults.standard.bool(forKey: "cloudSyncEnabled") {
            influx.start()
        }
    }

    func start() {
        // One-time cleanup: purge activity samples that were stored with wrong
        // timestamps by the old parser (which ignored the date in ring packets
        // and stamped everything as "today").  Safe to remove after a few releases.
        purgeStaleActivitySamples()

        // Backfill nightDate for sleep records migrated from schema without it.
        backfillSleepNightDates()

        // One-time: purge HR logs that were stored with wrong dayStart due to
        // the race condition bug (single requestedDay variable overwritten by
        // concurrent requests). Next sync will re-populate with correct dates.
        purgeStaleHeartRateLogs()

        ringSessionManager.bigDataSleepPersistenceCallback = { [weak self] sleepData in
            guard let self else { return }
            self.persistSleepData(sleepData)
        }
        ringSessionManager.heartRateLogPersistenceCallback = { [weak self] heartRateLog, requestedDay in
            guard let self else { return }
            self.persistHeartRateLog(heartRateLog, requestedDay: requestedDay)
        }
        ringSessionManager.activityDataPacketPersistenceCallback = { [weak self] packet in
            guard let self else { return }
            self.consumeActivityPacket(packet)
        }
        ringSessionManager.hrvDataPacketPersistenceCallback = { [weak self] packet in
            guard let self else { return }
            self.consumeSplitSeriesPacket(packet, isHRV: true)
        }
        ringSessionManager.pressureDataPacketPersistenceCallback = { [weak self] packet in
            guard let self else { return }
            self.consumeSplitSeriesPacket(packet, isHRV: false)
        }
        ringSessionManager.bigDataBloodOxygenPayloadPersistenceCallback = { [weak self] payload in
            guard let self else { return }
            tLog("[AutoPersist] Blood oxygen payload (\(payload.count) bytes): \(payload.prefix(20).map { String($0) }.joined(separator: ","))\(payload.count > 20 ? "…" : "")")
            let decoded = self.decodeBloodOxygenPayload(payload)
            tLog("[AutoPersist] Blood oxygen decoded \(decoded.count) valid points from \(payload.count) byte payload")
            self.persistBloodOxygenSeries(decoded)

            // Populate home card with latest SpO2 from today's historical data
            // so it shows immediately on connect (before the spot-check rotation reaches SpO2).
            if self.ringSessionManager.realTimeBloodOxygenPercent == nil {
                let todayStart = Calendar.current.startOfDay(for: Date())
                if let latest = decoded.filter({ $0.time >= todayStart && $0.value > 0 && $0.value <= 100 })
                    .max(by: { $0.time < $1.time }) {
                    let pct = Int(latest.value)
                    tLog("[AutoPersist] Seeding home SpO2 card with historical value: \(pct)%")
                    self.ringSessionManager.realTimeBloodOxygenPercent = pct
                }
            }
        }
    }

    // MARK: - Sleep

    private func persistSleepData(_ bigData: BigDataSleepData) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var insertedDays = 0
        var updatedDays = 0

        for day in bigData.days {
            let daysAgo = Int(day.daysAgo)
            let nightDate = calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today
            // Dedup on the actual calendar date so older syncs are preserved
            // when daysAgo values shift across syncs.
            let nightEnd = calendar.date(byAdding: .day, value: 1, to: nightDate) ?? nightDate
            let descriptor = FetchDescriptor<StoredSleepDay>(
                predicate: #Predicate<StoredSleepDay> { $0.nightDate >= nightDate && $0.nightDate < nightEnd }
            )
            let existing = (try? modelContext.fetch(descriptor))?.first
            if let existingDay = existing {
                updatedDays += 1
                existingDay.daysAgo = daysAgo
                existingDay.sleepStart = Int(day.sleepStart)
                existingDay.sleepEnd = Int(day.sleepEnd)
                existingDay.syncDate = Date()
                existingDay.nightDate = nightDate
                for period in existingDay.periods {
                    modelContext.delete(period)
                }
                existingDay.periods = []
                let newPeriods = makeStoredPeriods(from: day, nightDate: nightDate)
                for period in newPeriods {
                    period.day = existingDay
                    modelContext.insert(period)
                    existingDay.periods.append(period)
                }
            } else {
                insertedDays += 1
                let storedPeriods = makeStoredPeriods(from: day, nightDate: nightDate)
                let storedDay = StoredSleepDay(
                    daysAgo: daysAgo,
                    sleepStart: Int(day.sleepStart),
                    sleepEnd: Int(day.sleepEnd),
                    syncDate: Date(),
                    nightDate: nightDate,
                    periods: storedPeriods
                )
                modelContext.insert(storedDay)
            }
        }

        tLog("[AutoPersist] Sleep save requested. insertedDays=\(insertedDays) updatedDays=\(updatedDays)")
        if saveContext(tag: "Sleep") {
            Task { @MainActor in
                await healthSleepWriter.writeSleepDays(bigData.days, todayStart: today)
            }
            // Stream sleep stages to InfluxDB
            for day in bigData.days {
                let daysAgo = Int(day.daysAgo)
                let nightDate = calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today
                let sleepStartDate = nightDate.addingTimeInterval(TimeInterval(Int(day.sleepStart) * 60))
                var elapsed = 0
                for period in day.periods {
                    let periodStart = sleepStartDate.addingTimeInterval(TimeInterval(elapsed * 60))
                    elapsed += Int(period.minutes)
                    influx.writeSleep(stage: sleepTypeName(period.type), durationMinutes: Int(period.minutes), time: periodStart)
                }
            }
        }
    }

    private func makeStoredPeriods(from day: SleepDay, nightDate: Date) -> [StoredSleepPeriod] {
        let sleepStartDate = nightDate.addingTimeInterval(TimeInterval(Int(day.sleepStart) * 60))
        var elapsedMinutes = 0
        return day.periods.map { period in
            let start = sleepStartDate.addingTimeInterval(TimeInterval(elapsedMinutes * 60))
            elapsedMinutes += Int(period.minutes)
            return StoredSleepPeriod(type: period.type, minutes: Int(period.minutes), startTimestamp: start)
        }
    }

    // MARK: - Heart Rate

    private func persistHeartRateLog(_ log: HeartRateLog, requestedDay: Date) {
        // Use the requested day (local timezone) for dedup, not the ring's UTC timestamp,
        // which can map to a different calendar day due to timezone offset.
        let dayStart = requestedDay
        let ringDayStart = Calendar.current.startOfDay(for: log.timestamp)
        if dayStart != ringDayStart {
            tLog("[AutoPersist] HR dayStart mismatch: requested=\(formatDate(dayStart)) ring=\(formatDate(ringDayStart)) — using requested")
        }
        let descriptor = FetchDescriptor<StoredHeartRateLog>(
            predicate: #Predicate<StoredHeartRateLog> { $0.dayStart == dayStart }
        )
        let action: String
        if let existing = (try? modelContext.fetch(descriptor))?.first {
            existing.timestamp = log.timestamp
            existing.heartRates = log.heartRates
            existing.size = log.size
            existing.index = log.index
            existing.range = log.range
            action = "UPDATE"
        } else {
            let stored = StoredHeartRateLog.from(log)
            stored.dayStart = dayStart   // Override with requested day
            modelContext.insert(stored)
            action = "INSERT"
        }

        let nonZeroCount = log.heartRates.filter { $0 > 0 }.count
        tLog("[AutoPersist] Heart rate log save requested. action=\(action) dayStart=\(formatDate(dayStart)) range=\(log.range)min nonZero=\(nonZeroCount)/\(log.heartRates.count)")
        _ = saveContext(tag: "HeartRate")

        // Stream to InfluxDB using UTC-anchored timestamps (raw ring slots are UTC-indexed).
        let readings = log.heartRatesWithTimesUTC()
        if !readings.isEmpty {
            tLog("[AutoPersist] HR log → InfluxDB: \(readings.count) non-zero readings (UTC-anchored)")
            influx.writeHeartRates(readings.map { (bpm: $0.0, time: $0.1) })
        } else {
            tLog("[AutoPersist] HR log → InfluxDB: no non-zero readings")
        }
    }

    /// Delete all StoredActivitySample rows — the old parser stored every sample
    /// with today's date regardless of actual date, so the DB is unreliable.
    /// The next ring sync will repopulate with correctly-dated data.
    private func purgeStaleHeartRateLogs() {
        let key = "hrLogUTCMapFixPurgeV4"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        do {
            let all = try modelContext.fetch(FetchDescriptor<StoredHeartRateLog>())
            guard !all.isEmpty else {
                UserDefaults.standard.set(true, forKey: key)
                return
            }
            for log in all { modelContext.delete(log) }
            try modelContext.save()
            tLog("[HRLogMigration] Purged \(all.count) stale HR logs (dayStart race fix)")
        } catch {
            tLog("[HRLogMigration] Purge failed: \(error)")
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    private func purgeStaleActivitySamples() {
        let key = "activityParserV4Migrated"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        do {
            let all = try modelContext.fetch(FetchDescriptor<StoredActivitySample>())
            guard !all.isEmpty else {
                UserDefaults.standard.set(true, forKey: key)
                return
            }
            for sample in all { modelContext.delete(sample) }
            try modelContext.save()
            tLog("[ActivityMigration] Purged \(all.count) stale activity samples")
        } catch {
            tLog("[ActivityMigration] Purge failed: \(error)")
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Backfill `nightDate` for StoredSleepDay records created before the field existed.
    /// After lightweight migration these rows have `Date.distantPast`; recompute from
    /// `syncDate` and `daysAgo`.
    private func backfillSleepNightDates() {
        let key = "sleepNightDateBackfilled"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        do {
            let sentinel = Date.distantPast
            let descriptor = FetchDescriptor<StoredSleepDay>(
                predicate: #Predicate<StoredSleepDay> { $0.nightDate == sentinel }
            )
            let stale = try modelContext.fetch(descriptor)
            guard !stale.isEmpty else {
                UserDefaults.standard.set(true, forKey: key)
                return
            }
            let calendar = Calendar.current
            for day in stale {
                let base = calendar.startOfDay(for: day.syncDate)
                day.nightDate = calendar.date(byAdding: .day, value: -day.daysAgo, to: base) ?? base
            }
            try modelContext.save()
            tLog("[SleepMigration] Backfilled nightDate for \(stale.count) sleep records")
        } catch {
            tLog("[SleepMigration] Backfill failed: \(error)")
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    // MARK: - Activity (CMD_GET_STEP_SOMEDAY / 0x43)
    //
    // Protocol (from colmi_r02_client reference):
    //   Packet 0 (version header):  byte[1] == 0xF0, byte[3] == 1 → new calorie protocol
    //   Packet 0 (no data):         byte[1] == 0xFF → ring has no data for this day
    //   Data packets:
    //     byte[1..3]  = BCD-encoded date (year-2000, month, day)
    //     byte[4]     = time_index (15-minute slot, 0..95)
    //     byte[5]     = current packet index (0-based)
    //     byte[6]     = total packet count
    //     byte[7..8]  = calories (little-endian; ×10 if new calorie protocol)
    //     byte[9..10] = steps (little-endian)
    //     byte[11..12]= distance in meters (little-endian)

    private struct ParsedActivitySlot {
        let date: Date       // start-of-day for the slot's date
        let hour: Int
        let minute: Int
        let steps: Int
        let distanceMeters: Int
        let calories: Int
    }

    private var activityBatch: [ParsedActivitySlot] = []
    private var activityFlushWorkItem: DispatchWorkItem?
    private var activityNewCalorieProtocol = false
    private var activityPacketIndex = 0

    /// Decode a BCD-encoded byte: 0x23 → 23, 0x08 → 8, etc.
    private static func bcdToDecimal(_ b: UInt8) -> Int {
        return Int((b >> 4) & 0x0F) * 10 + Int(b & 0x0F)
    }

    /// Format a Date as local "yyyy-MM-dd HH:mm" for logging.
    private static func localTimeStr(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        fmt.timeZone = .current
        return fmt.string(from: date)
    }

    private func consumeActivityPacket(_ packet: [UInt8]) {
        guard packet.count >= 13, packet[0] == 67 else { return }

        let hex = packet.map { String(format: "%02X", $0) }.joined(separator: " ")
        tLog("[Activity] Raw packet (\(packet.count)B): \(hex)")

        // --- Handle special packet types (detect regardless of index state) ---
        // The version header (0xF0) and no-data marker (0xFF) always signal the
        // start of a new response sequence.  Recognise them even if a previous
        // sync was interrupted and activityPacketIndex is non-zero.

        if packet[1] == 0xFF {
            if activityPacketIndex != 0 {
                tLog("[Activity] ⚠️ no-data marker received with stale index \(activityPacketIndex) — resetting")
            }
            tLog("[Activity] Ring reports no data for this day")
            activityPacketIndex = 0
            activityNewCalorieProtocol = false
            return
        }

        if packet[1] == 0xF0 {
            if activityPacketIndex != 0 {
                tLog("[Activity] ⚠️ version header received with stale index \(activityPacketIndex) — resetting (previous sync likely interrupted)")
            }
            // Protocol version header — not a data packet
            activityNewCalorieProtocol = (packet[3] == 1)
            activityPacketIndex = 1
            tLog("[Activity] Version header: newCalorieProtocol=\(activityNewCalorieProtocol)")
            return
        }

        // --- Parse data packet ---

        let year = Self.bcdToDecimal(packet[1]) + 2000
        let month = Self.bcdToDecimal(packet[2])
        let day = Self.bcdToDecimal(packet[3])
        let timeIndex = Int(packet[4])                                  // 15-min slot 0..95
        let hour = timeIndex / 4
        let minute = (timeIndex % 4) * 15

        let steps = Int(packet[9]) | (Int(packet[10]) << 8)
        // Bytes 7-8 are labelled "calories" in the Python reference but on our
        // ring they contain values ~3× the step count — not plausible as kcal.
        // Estimate from steps instead (~0.04 kcal/step walking average).
        let calories = Int(round(Double(steps) * 0.04))
        let distanceMeters = Int(packet[11]) | (Int(packet[12]) << 8)

        let currentIdx = Int(packet[5])                                  // 0-based
        let totalPackets = Int(packet[6])                                // total count

        // Build the slot's actual UTC timestamp from BCD date + slot time,
        // then derive the local date for grouping.  The ring reports dates/times
        // in UTC, so we must interpret them in UTC first, then convert to local.
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        var utcComps = DateComponents()
        utcComps.year = year; utcComps.month = month; utcComps.day = day
        utcComps.hour = hour; utcComps.minute = minute
        let slotUTCDate = utcCal.date(from: utcComps) ?? Date()
        let localDay = Calendar.current.startOfDay(for: slotUTCDate)
        let localHour = Calendar.current.component(.hour, from: slotUTCDate)

        tLog("[Activity] \(year)-\(String(format:"%02d-%02d", month, day)) slot=\(timeIndex) (\(String(format:"%02d:%02d", hour, minute)) UTC → \(Self.localTimeStr(slotUTCDate)) local)  steps=\(steps) dist=\(distanceMeters)m cal=\(calories)  pkt \(currentIdx+1)/\(totalPackets)")

        if steps > 0 || distanceMeters > 0 || calories > 0 {
            activityBatch.append(ParsedActivitySlot(
                date: localDay,
                hour: localHour, minute: minute,
                steps: steps, distanceMeters: distanceMeters, calories: calories))
        }

        activityPacketIndex += 1

        // Check if this is the last data packet in the sequence
        let isLast = (currentIdx == totalPackets - 1)
        if isLast {
            activityPacketIndex = 0
            activityNewCalorieProtocol = false
        }

        // Schedule a flush after a short delay so all packets from this sync
        // arrive before we write.  Reset on each packet; fires 1s after the last.
        activityFlushWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.flushActivityBatch()
        }
        activityFlushWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    /// Upsert activity samples grouped by their actual date (from the ring).
    /// Each 15-minute slot is stored individually; multiple slots in the same
    /// hour are stored separately so the Activity chart can show intra-hour data.
    private func flushActivityBatch() {
        let batch = activityBatch
        activityBatch = []
        activityFlushWorkItem = nil

        guard !batch.isEmpty else { return }

        // Group by date so we can fetch/upsert per-day
        let byDate = Dictionary(grouping: batch) { $0.date }

        var totalUpdated = 0
        var totalInserted = 0

        for (dayStart, slots) in byDate {
            let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)!
            let descriptor = FetchDescriptor<StoredActivitySample>(
                predicate: #Predicate<StoredActivitySample> { $0.timestamp >= dayStart && $0.timestamp < dayEnd }
            )
            let existing = (try? modelContext.fetch(descriptor)) ?? []
            // Index by hour for upsert (one sample per hour)
            let existingByHour = Dictionary(grouping: existing) { sample in
                Calendar.current.component(.hour, from: sample.timestamp)
            }

            // Aggregate 15-min slots into hourly buckets for storage
            let hourlyBuckets = Dictionary(grouping: slots) { $0.hour }

            for (hour, hourSlots) in hourlyBuckets {
                let totalSteps = hourSlots.reduce(0) { $0 + $1.steps }
                let totalDist = hourSlots.reduce(0) { $0 + $1.distanceMeters }
                let totalCal = hourSlots.reduce(0) { $0 + $1.calories }
                let distanceKm = Double(totalDist) / 1000.0
                let timestamp = dayStart.addingTimeInterval(TimeInterval(hour * 3600))

                if let match = existingByHour[hour]?.first {
                    match.steps = totalSteps
                    match.distanceKm = distanceKm
                    match.calories = totalCal
                    match.timestamp = timestamp
                    totalUpdated += 1
                } else {
                    modelContext.insert(StoredActivitySample(
                        timestamp: timestamp, steps: totalSteps,
                        distanceKm: distanceKm, calories: totalCal))
                    totalInserted += 1
                }
            }
        }

        tLog("[AutoPersist] Activity flush: updated \(totalUpdated), inserted \(totalInserted) across \(byDate.count) day(s)")

        if saveContext(tag: "Activity") {
            // Group for HealthKit / InfluxDB writes
            let hourlyByDate = Dictionary(grouping: batch) { $0.date }
            for (dayStart, slots) in hourlyByDate {
                let hourlyBuckets = Dictionary(grouping: slots) { $0.hour }
                for (hour, hourSlots) in hourlyBuckets {
                    let totalSteps = hourSlots.reduce(0) { $0 + $1.steps }
                    let totalDist = hourSlots.reduce(0) { $0 + $1.distanceMeters }
                    let totalCal = hourSlots.reduce(0) { $0 + $1.calories }
                    let distanceKm = Double(totalDist) / 1000.0
                    let timestamp = dayStart.addingTimeInterval(TimeInterval(hour * 3600))
                    Task { @MainActor in
                        await healthActivityWriter.writeActivitySample(timestamp: timestamp, steps: totalSteps, calories: totalCal)
                    }
                    influx.writeActivity(steps: totalSteps, calories: totalCal, distanceKm: distanceKm, time: timestamp)
                }
            }
        }
    }

    // MARK: - HRV / Stress split-series

    private func consumeSplitSeriesPacket(_ packet: [UInt8], isHRV: Bool) {
        let series: [TimeSeriesPoint]?
        if isHRV {
            series = hrvSeriesAccumulator.consume(packet)
        } else {
            series = stressSeriesAccumulator.consume(packet)
        }
        guard let series else { return }

        if isHRV {
            persistHRVSeries(series)
        } else {
            persistStressSeries(series)
        }
    }

    private func persistHRVSeries(_ series: [TimeSeriesPoint]) {
        let existingSamples = (try? modelContext.fetch(FetchDescriptor<StoredHRVSample>())) ?? []
        var inserted = 0
        var updated = 0
        for point in series {
            if let existing = existingSamples.first(where: { $0.timestamp == point.time }) {
                existing.value = point.value
                updated += 1
            } else {
                modelContext.insert(StoredHRVSample(timestamp: point.time, value: point.value))
                inserted += 1
            }
        }
        tLog("[AutoPersist] HRV save requested. inserted=\(inserted) updated=\(updated) total=\(series.count)")
        _ = saveContext(tag: "HRV")

        // Always write all points — InfluxDB deduplicates by timestamp.
        for point in series {
            influx.writeHRV(value: point.value, time: point.time)
        }
    }

    private func persistStressSeries(_ series: [TimeSeriesPoint]) {
        let existingSamples = (try? modelContext.fetch(FetchDescriptor<StoredStressSample>())) ?? []
        var inserted = 0
        var updated = 0
        for point in series {
            if let existing = existingSamples.first(where: { $0.timestamp == point.time }) {
                existing.value = point.value
                updated += 1
            } else {
                modelContext.insert(StoredStressSample(timestamp: point.time, value: point.value))
                inserted += 1
            }
        }
        tLog("[AutoPersist] Stress save requested. inserted=\(inserted) updated=\(updated) total=\(series.count)")
        _ = saveContext(tag: "Stress")

        // Always write all points — InfluxDB deduplicates by timestamp.
        for point in series {
            influx.writeStress(value: point.value, time: point.time)
        }
    }

    // MARK: - Blood oxygen

    private func decodeBloodOxygenPayload(_ payload: [UInt8]) -> [TimeSeriesPoint] {
        // Payload is groups of 49 bytes: [dayIndex, 24×(max,min)].
        // dayIndex: 0 = today, 1 = yesterday, 2 = two days ago, etc.
        let groupSize = 49
        guard payload.count >= groupSize else { return [] }

        var allPoints: [TimeSeriesPoint] = []
        var offset = 0
        while offset + groupSize <= payload.count {
            let dayIndex = Int(payload[offset])
            let sampleBytes = Array(payload[(offset + 1) ..< (offset + groupSize)])
            let points = decodeBloodOxygenHourlyPairs(sampleBytes: sampleBytes, daysAgo: dayIndex)
            allPoints.append(contentsOf: points)
            offset += groupSize
        }
        return allPoints
    }

    private func decodeBloodOxygenHourlyPairs(sampleBytes: [UInt8], daysAgo: Int) -> [TimeSeriesPoint] {
        var points: [TimeSeriesPoint] = []
        var hour = 0
        var i = 0
        while i + 1 < sampleBytes.count, hour < 24 {
            let maxV = Double(sampleBytes[i])
            let minV = Double(sampleBytes[i + 1])
            let avg = (maxV + minV) / 2.0
            if avg >= 80 {  // Values below 80% indicate no data / ring not worn
                points.append(TimeSeriesPoint(time: dayAtHour(daysAgo: daysAgo, hour: hour), value: avg))
            }
            i += 2
            hour += 1
        }
        return points
    }

    private func persistBloodOxygenSeries(_ series: [TimeSeriesPoint]) {
        guard !series.isEmpty else { return }
        let existingSamples = (try? modelContext.fetch(FetchDescriptor<StoredBloodOxygenSample>())) ?? []
        var inserted = 0
        var updated = 0
        for point in series {
            if let existing = existingSamples.first(where: { $0.timestamp == point.time }) {
                existing.value = point.value
                updated += 1
            } else {
                modelContext.insert(StoredBloodOxygenSample(timestamp: point.time, value: point.value))
                inserted += 1
            }
        }
        tLog("[AutoPersist] Blood oxygen save requested. inserted=\(inserted) updated=\(updated) total=\(series.count)")
        _ = saveContext(tag: "BloodOxygen")

        // Always write all points to InfluxDB (not just new inserts).
        // InfluxDB deduplicates by timestamp, so re-sending is safe and
        // ensures data reaches InfluxDB even on re-syncs / updates.
        for point in series {
            influx.writeSpO2(value: point.value, time: point.time)
        }
    }

    /// Build an absolute timestamp from a ring-reported daysAgo + UTC hour.
    /// The ring indexes hours from UTC midnight, so we compute the UTC time
    /// then return it as an absolute Date (correct for both chart and InfluxDB).
    private func dayAtHour(daysAgo: Int, hour: Int) -> Date {
        RingSlotTimestamp.date(daysAgo: daysAgo, hour: hour)
    }

    // MARK: - Shared

    @discardableResult
    private func saveContext(tag: String) -> Bool {
        do {
            try modelContext.save()
            tLog("[AutoPersist] SwiftData save SUCCESS (\(tag))")
            return true
        } catch {
            tLog("[AutoPersist] SwiftData save FAILED (\(tag)): \(error)")
            return false
        }
    }

    private func formatDate(_ date: Date) -> String {
        Self.logDateFormatter.string(from: date)
    }

    private func sleepTypeName(_ type: SleepType) -> String {
        switch type {
        case .noData: return "no_data"
        case .error: return "error"
        case .light: return "light"
        case .deep: return "deep"
        case .core: return "core"
        case .awake: return "awake"
        }
    }
}
