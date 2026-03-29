import SwiftUI
import SwiftData

struct ActivityScreenView: View {
    @Query(sort: \StoredActivitySample.timestamp, order: .reverse) private var storedActivitySamples: [StoredActivitySample]
    @Query(sort: \StoredPhoneStepSample.timestamp, order: .reverse) private var storedPhoneStepSamples: [StoredPhoneStepSample]
    @Query(sort: \StoredGlucoseSample.timestamp, order: .reverse) private var storedGlucoseSamples: [StoredGlucoseSample]

    private var calendar: Calendar { Calendar.current }

    private var todayActivitySamples: [StoredActivitySample] {
        storedActivitySamples
            .filter { calendar.isDateInToday($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private var todayPhoneSamples: [StoredPhoneStepSample] {
        storedPhoneStepSamples
            .filter { calendar.isDateInToday($0.timestamp) }
    }

    private var ringByHour: [Int: [StoredActivitySample]] {
        Dictionary(grouping: todayActivitySamples) { calendar.component(.hour, from: $0.timestamp) }
    }

    private var phoneByHour: [Int: [StoredPhoneStepSample]] {
        Dictionary(grouping: todayPhoneSamples) { calendar.component(.hour, from: $0.timestamp) }
    }

    /// Merged activity: take the higher of ring vs phone per hourly bucket.
    private func mergedData(ring: (StoredActivitySample) -> Double, phone: (StoredPhoneStepSample) -> Double) -> [TimeSeriesPoint] {
        let allHours = Set(ringByHour.keys).union(phoneByHour.keys).sorted()
        return allHours.compactMap { hour -> TimeSeriesPoint? in
            let ringVal = ringByHour[hour]?.reduce(0.0) { $0 + ring($1) } ?? 0
            let phoneVal = phoneByHour[hour]?.reduce(0.0) { $0 + phone($1) } ?? 0
            let best = max(ringVal, phoneVal)
            guard best > 0 else { return nil }
            let ts = ringByHour[hour]?.first?.timestamp ?? phoneByHour[hour]?.first?.timestamp ?? Date()
            return TimeSeriesPoint(time: ts, value: best)
        }
    }

    private var stepsData: [TimeSeriesPoint] {
        mergedData(ring: { Double($0.steps) }, phone: { Double($0.steps) })
    }

    private var distanceData: [TimeSeriesPoint] {
        mergedData(ring: { $0.distanceKm }, phone: { $0.distanceKm })
    }

    private var caloriesData: [TimeSeriesPoint] {
        mergedData(ring: { Double($0.calories) }, phone: { Double($0.calories) })
    }

    private var glucoseData: [TimeSeriesPoint] {
        storedGlucoseSamples
            .filter { calendar.isDateInToday($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }
            .map { TimeSeriesPoint(time: $0.timestamp, value: $0.valueMgdl) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label(L10n.Tab.activity, systemImage: "figure.walk")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.horizontal)

                    VStack(spacing: 20) {
                        ActivityCumulativeChartView(
                            data: stepsData,
                            title: L10n.Activity.stepsTitle,
                            yLabel: "Steps"
                        )
                        .allowsHitTesting(false)
                        .contentShape(Rectangle())

                        ActivityCumulativeChartView(
                            data: distanceData,
                            title: L10n.Activity.distanceTitle,
                            color: .green,
                            yLabel: "Km"
                        )
                        .allowsHitTesting(false)
                        .contentShape(Rectangle())

                        ActivityCumulativeChartView(
                            data: caloriesData,
                            title: L10n.Activity.caloriesTitle,
                            color: .red,
                            yLabel: "Kcal"
                        )
                        .allowsHitTesting(false)
                        .contentShape(Rectangle())

                        if !glucoseData.isEmpty {
                            GlucoseChartView(data: glucoseData)
                                .allowsHitTesting(false)
                                .contentShape(Rectangle())
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.top)
                .padding(.bottom, 40)
            }
            .navigationTitle(L10n.Tab.activity)
            .navigationBarTitleDisplayMode(.large)
        }
    }
}
