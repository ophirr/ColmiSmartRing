//
//  SleepSectionView.swift
//  Biosense
//
//  Sleep feature: request sleep data, display sleep stages and stored nights.
//

import SwiftUI
import SwiftData

struct SleepSectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var ringSessionManager: RingSessionManager
    @Query(sort: \StoredSleepDay.syncDate, order: .reverse) private var storedSleepDays: [StoredSleepDay]
    @State private var lastSleepData: SleepData?
    @State private var lastBigDataSleep: BigDataSleepData?
    @State private var selectedStoredSleepDay: StoredSleepDay?
    private static let swiftDataLogDateFormatter = ISO8601DateFormatter()

    private var sortedStoredSleepDays: [StoredSleepDay] {
        storedSleepDays.sorted { $0.sleepDate > $1.sleepDate }
    }

    var body: some View {
        Section(L10n.Sleep.sectionTitle) {
            Button {
                ringSessionManager.syncSleep(dayOffset: 0)
            } label: {
                Label(L10n.Sleep.requestData, systemImage: "bed.double.fill")
                    .frame(maxWidth: .infinity)
                    .font(Font.headline.weight(.semibold))
                    .padding()
                    .background(Color.indigo)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            .disabled(!ringSessionManager.peripheralConnected)
            .accessibilityLabel(L10n.A11y.sleepRequest)
            .accessibilityHint(Text(L10n.A11y.sleepRequestHint))

            if let sleep = lastBigDataSleep, let firstDay = sleep.days.first {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.Sleep.daysCount(sleep.days.count))
                        .font(.subheadline.weight(.medium))
                        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
                    SleepStageGraphView(day: firstDay)
                    SleepChartKitView(day: firstDay)
                    if sleep.days.count > 1 {
                        DisclosureGroup(L10n.Sleep.otherNights) {
                            ForEach(Array(sleep.days.dropFirst().enumerated()), id: \.offset) { _, day in
                                SleepStageGraphView(day: day)
                                SleepChartKitView(day: day)
                            }
                        }
                    }
                }
            } else if let sleep = lastSleepData {
                VStack(alignment: .leading, spacing: 4) {
                    if let date = sleep.date {
                        Text(date, style: .date)
                            .font(.subheadline.weight(.medium))
                    }
                    Text(L10n.Sleep.timeQualities(time: sleep.time, qualities: sleep.sleepQualities))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !sortedStoredSleepDays.isEmpty {
                DisclosureGroup(L10n.Sleep.storedNights(sortedStoredSleepDays.count)) {
                    ForEach(sortedStoredSleepDays) { storedDay in
                        Button {
                            selectedStoredSleepDay = selectedStoredSleepDay?.id == storedDay.id ? nil : storedDay
                        } label: {
                            HStack {
                                Text(storedDay.sleepDate, style: .date)
                                Text(L10n.Sleep.daysAgo(Int(storedDay.daysAgo)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(storedDay.sleepDate, style: .date))
                        .accessibilityHint(Text(L10n.A11y.sleepStoredDayHint))
                        if selectedStoredSleepDay?.id == storedDay.id {
                            let day = storedDay.toSleepDay()
                            VStack(alignment: .leading, spacing: 8) {
                                SleepStageGraphView(day: day)
                                SleepChartKitView(day: day, nightDate: storedDay.sleepDate)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            ringSessionManager.sleepDataCallback = { lastSleepData = $0 }
            ringSessionManager.bigDataSleepCallback = { bigData in
                Task { @MainActor in
                    lastBigDataSleep = bigData
                    saveBigDataSleep(bigData)
                }
            }
        }
    }

    private func saveBigDataSleep(_ bigData: BigDataSleepData) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var insertedDays = 0
        var updatedDays = 0
        var dayLogs: [String] = []
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
                for p in existingDay.periods { modelContext.delete(p) }
                existingDay.periods = []
                let newPeriods = makeStoredPeriods(from: day, nightDate: nightDate)
                for p in newPeriods {
                    p.day = existingDay
                    modelContext.insert(p)
                    existingDay.periods.append(p)
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
            let periodLog = day.periods.map { period in
                "{type: \(period.type.rawValue), minutes: \(period.minutes)}"
            }.joined(separator: ", ")
            dayLogs.append(
                "{daysAgo: \(daysAgo), nightDate: \(swiftDataLogDate(nightDate)), sleepStartMin: \(day.sleepStart), sleepEndMin: \(day.sleepEnd), periods: [\(periodLog)]}"
            )
        }

        tLog("=========== SWIFTDATA SAVE: Sleep ===========")
        tLog("insertedDays: \(insertedDays), updatedDays: \(updatedDays), totalDays: \(bigData.days.count)")
        tLog("days: [\(dayLogs.joined(separator: ", "))]")
        do {
            try modelContext.save()
            tLog("result: SUCCESS")
        } catch {
            tLog("result: FAILED - \(error)")
        }
        tLog("=============================================")
    }

    private func makeStoredPeriods(from day: SleepDay, nightDate: Date) -> [StoredSleepPeriod] {
        // Ring clock is UTC, so sleepStart is minutes-after-UTC-midnight.
        // nightDate is local midnight. Apply UTC offset to convert.
        let utcOffsetSeconds = TimeZone.current.secondsFromGMT(for: nightDate)
        let localSleepStartSeconds = Int(day.sleepStart) * 60 + utcOffsetSeconds
        let sleepStartDate = nightDate.addingTimeInterval(TimeInterval(localSleepStartSeconds))
        var elapsedMinutes = 0
        return day.periods.map { period in
            let start = sleepStartDate.addingTimeInterval(TimeInterval(elapsedMinutes * 60))
            elapsedMinutes += Int(period.minutes)
            return StoredSleepPeriod(type: period.type, minutes: Int(period.minutes), startTimestamp: start)
        }
    }

    private func swiftDataLogDate(_ date: Date) -> String {
        Self.swiftDataLogDateFormatter.string(from: date)
    }
}
