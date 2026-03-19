//
//  SleepSectionView.swift
//  Biosense
//
//  Sleep feature: request sleep data, display sleep stages and stored nights.
//

import SwiftUI
import SwiftData

struct SleepSectionView: View {
    @Bindable var ringSessionManager: RingSessionManager
    @Query(sort: \StoredSleepDay.syncDate, order: .reverse) private var storedSleepDays: [StoredSleepDay]
    @State private var selectedStoredSleepDay: StoredSleepDay?

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

            if let sleep = ringSessionManager.lastBigDataSleep, let firstDay = sleep.days.first {
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
            } else if let sleep = ringSessionManager.lastSleepData {
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
    }
}
