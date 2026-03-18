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
    private let healthHRWriter = AppleHealthHeartRateWriter()
    private let influx = InfluxDBWriter.shared

    private static let logDateFormatter = ISO8601DateFormatter()

    init(modelContext: ModelContext, ringSessionManager: RingSessionManager) {
        self.modelContext = modelContext
        self.ringSessionManager = ringSessionManager
        if UserDefaults.standard.bool(forKey: AppSettings.CloudSync.enabled) {
            influx.start()
        }
    }

    func start() {
        SwiftDataMigrations.runAll(context: modelContext)
        ringSessionManager.dataDelegate = self
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
        let newNonZero = log.heartRates.filter { $0 > 0 }.count
        let action: String
        if let existing = (try? modelContext.fetch(descriptor))?.first {
            // Always merge: overlay new non-zero readings onto existing data.
            // This prevents data loss when the ring resets its log (midnight
            // reboot, interval change) and sends back a sparse log that would
            // overwrite a richer existing dataset.
            let fineRange = min(existing.range, log.range)
            let slotsPerDay = (24 * 60) / max(fineRange, 1)
            var merged = expandToSlots(existing.heartRates, fromRange: existing.range, toSlots: slotsPerDay)
            let incoming = expandToSlots(log.heartRates, fromRange: log.range, toSlots: slotsPerDay)
            // Overlay: new non-zero readings replace existing slots.
            for i in 0..<min(merged.count, incoming.count) {
                if incoming[i] > 0 { merged[i] = incoming[i] }
            }
            let existingNonZero = existing.heartRates.filter { $0 > 0 }.count
            let mergedNonZero = merged.filter { $0 > 0 }.count
            // Safety: never reduce the number of non-zero readings.
            // This guards against expand/contract rounding or any edge case
            // where the merge would lose data.
            if mergedNonZero >= existingNonZero {
                existing.heartRates = merged
                existing.range = fineRange
                existing.size = 24
                existing.index = merged.count
                existing.timestamp = log.timestamp
                tLog("[AutoPersist] HR log MERGED — stored range=\(fineRange)min, \(mergedNonZero) non-zero slots (was \(existingNonZero))")
                action = "MERGE"
            } else {
                tLog("[AutoPersist] HR log merge SKIPPED — would reduce non-zero from \(existingNonZero) to \(mergedNonZero), keeping existing")
                action = "KEPT"
            }
        } else {
            let stored = StoredHeartRateLog.from(log)
            stored.dayStart = dayStart   // Override with requested day
            modelContext.insert(stored)
            action = "INSERT"
        }

        tLog("[AutoPersist] Heart rate log save requested. action=\(action) dayStart=\(formatDate(dayStart)) range=\(log.range)min nonZero=\(newNonZero)/\(log.heartRates.count)")
        _ = saveContext(tag: "HeartRate")

        // Stream to InfluxDB using UTC-anchored timestamps (raw ring slots are UTC-indexed).
        let readings = log.heartRatesWithTimesUTC()
        if !readings.isEmpty {
            tLog("[AutoPersist] HR log → InfluxDB: \(readings.count) non-zero readings (UTC-anchored)")
            influx.writeHeartRates(readings.map { (bpm: $0.0, time: $0.1) })

            // Also write to HealthKit so Apple Health reflects the full HR history.
            Task { @MainActor in
                await healthHRWriter.writeHeartRateLog(readings.map { (bpm: $0.0, time: $0.1) })
            }
        } else {
            tLog("[AutoPersist] HR log → InfluxDB: no non-zero readings")
        }
    }

    /// Expand (or contract) an HR slot array to a target number of slots.
    /// E.g. 288 slots at 5-min → 1440 slots at 1-min (each value repeated 5×),
    /// or 1440 slots at 1-min → 288 slots at 5-min (each group of 5 averaged).
    private func expandToSlots(_ heartRates: [Int], fromRange: Int, toSlots: Int) -> [Int] {
        let fromRange = max(fromRange, 1)
        let fromSlots = (24 * 60) / fromRange
        let hrs = Array(heartRates.prefix(fromSlots))
        if toSlots == fromSlots { return hrs }
        if toSlots > fromSlots {
            // Expanding (e.g. 5-min → 1-min): repeat each value
            let factor = toSlots / fromSlots
            return hrs.flatMap { Array(repeating: $0, count: factor) }
        } else {
            // Contracting (e.g. 1-min → 5-min): take first non-zero in each group
            let factor = fromSlots / toSlots
            var result = [Int]()
            for i in 0..<toSlots {
                let group = hrs[i * factor ..< min((i + 1) * factor, hrs.count)]
                result.append(group.first(where: { $0 > 0 }) ?? 0)
            }
            return result
        }
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
            // Fan out to HealthKit + InfluxDB
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

        // Fan out to InfluxDB (deduplicates by timestamp)
        for point in series {
            influx.writeHRV(value: point.value, time: point.time)
        }

        // Fan out to HealthKit (SyncIdentifier deduplicates)
        let hrvReadings = series.map { (sdnn: $0.value, time: $0.time) }
        Task { @MainActor in
            await healthHRWriter.writeHRVSeries(hrvReadings)
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

        // Fan out to InfluxDB (deduplicates by timestamp). No HealthKit equivalent for stress.
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
        let now = Date()
        var points: [TimeSeriesPoint] = []
        var hour = 0
        var i = 0
        while i + 1 < sampleBytes.count, hour < 24 {
            let maxV = Double(sampleBytes[i])
            let minV = Double(sampleBytes[i + 1])
            let avg = (maxV + minV) / 2.0
            let t = RingSlotTimestamp.date(daysAgo: daysAgo, hour: hour)
            // Drop values below 80% (no data / ring not worn) and future timestamps
            // (stale ring data from slots past the current time).
            if avg >= 80, t <= now {
                points.append(TimeSeriesPoint(time: t, value: avg))
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

        // Fan out to InfluxDB (deduplicates by timestamp)
        for point in series {
            influx.writeSpO2(value: point.value, time: point.time)
        }

        // Fan out to HealthKit (SyncIdentifier deduplicates)
        let spo2Readings = series.map { (percent: $0.value, time: $0.time) }
        Task { @MainActor in
            await healthHRWriter.writeSpO2Series(spo2Readings)
        }
    }

    /// Persist a single real-time SpO2 spot-check reading to SwiftData.
    /// The value already went to InfluxDB/HealthKit in RingSessionManager;
    /// this ensures it also appears on the Metrics chart.
    private func persistSpotCheckSpO2(percent: Int, time: Date) {
        let value = Double(percent)
        // Check for an existing sample within the same minute to avoid duplicates.
        let existingSamples = (try? modelContext.fetch(FetchDescriptor<StoredBloodOxygenSample>())) ?? []
        let isDuplicate = existingSamples.contains { abs($0.timestamp.timeIntervalSince(time)) < 60 && $0.value == value }
        guard !isDuplicate else {
            tLog("[AutoPersist] SpO2 spot-check \(percent)% at \(Self.logDateFormatter.string(from: time)) — duplicate, skipping")
            return
        }
        modelContext.insert(StoredBloodOxygenSample(timestamp: time, value: value))
        tLog("[AutoPersist] SpO2 spot-check \(percent)% at \(Self.logDateFormatter.string(from: time)) — saved to SwiftData")
        _ = saveContext(tag: "SpO2SpotCheck")
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

// MARK: - RingDataDelegate

extension RingDataPersistenceCoordinator: RingDataDelegate {
    func ringDidReceiveSleepData(_ data: BigDataSleepData) {
        persistSleepData(data)
    }

    func ringDidReceiveHeartRateLog(_ log: HeartRateLog, requestedDay: Date) {
        persistHeartRateLog(log, requestedDay: requestedDay)
    }

    func ringDidReceiveActivityPacket(_ packet: [UInt8]) {
        consumeActivityPacket(packet)
    }

    func ringDidReceiveHRVPacket(_ packet: [UInt8]) {
        consumeSplitSeriesPacket(packet, isHRV: true)
    }

    func ringDidReceivePressurePacket(_ packet: [UInt8]) {
        consumeSplitSeriesPacket(packet, isHRV: false)
    }

    func ringDidReceiveBloodOxygenPayload(_ payload: [UInt8]) {
        tLog("[AutoPersist] Blood oxygen payload (\(payload.count) bytes): \(payload.prefix(20).map { String($0) }.joined(separator: ","))\(payload.count > 20 ? "…" : "")")
        let decoded = decodeBloodOxygenPayload(payload)
        tLog("[AutoPersist] Blood oxygen decoded \(decoded.count) valid points from \(payload.count) byte payload")
        persistBloodOxygenSeries(decoded)

        // Populate home card with latest SpO2 from today's historical data
        // so it shows immediately on connect (before the spot-check rotation reaches SpO2).
        if ringSessionManager.realTimeBloodOxygenPercent == nil {
            let todayStart = Calendar.current.startOfDay(for: Date())
            if let latest = decoded.filter({ $0.time >= todayStart && $0.value > 0 && $0.value <= 100 })
                .max(by: { $0.time < $1.time }) {
                let pct = Int(latest.value)
                tLog("[AutoPersist] Seeding home SpO2 card with historical value: \(pct)%")
                ringSessionManager.realTimeBloodOxygenPercent = pct
            }
        }

        // Backfill: if a real-time SpO2 value exists and the latest stored sample
        // is older than 30 minutes, persist the current reading so the chart
        // extends closer to "now".
        if let currentPct = ringSessionManager.realTimeBloodOxygenPercent {
            let allSamples = (try? modelContext.fetch(FetchDescriptor<StoredBloodOxygenSample>())) ?? []
            let latestStored = allSamples.max(by: { $0.timestamp < $1.timestamp })
            let gap = Date().timeIntervalSince(latestStored?.timestamp ?? .distantPast)
            if gap > 30 * 60 {
                persistSpotCheckSpO2(percent: currentPct, time: Date())
            }
        }
    }

    func ringDidReceiveSpotCheckSpO2(percent: Int, time: Date) {
        persistSpotCheckSpO2(percent: percent, time: time)
    }
}
