import SwiftUI
import SwiftData

struct ActivityScreenView: View {
    @Query(sort: \StoredActivitySample.timestamp, order: .reverse) private var storedActivitySamples: [StoredActivitySample]

    private var calendar: Calendar { Calendar.current }

    private var todayActivitySamples: [StoredActivitySample] {
        storedActivitySamples
            .filter { calendar.isDateInToday($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private var stepsData: [TimeSeriesPoint] {
        todayActivitySamples.map { TimeSeriesPoint(time: $0.timestamp, value: Double($0.steps)) }
    }

    private var distanceData: [TimeSeriesPoint] {
        todayActivitySamples.map { TimeSeriesPoint(time: $0.timestamp, value: $0.distanceKm) }
    }

    private var caloriesData: [TimeSeriesPoint] {
        todayActivitySamples.map { TimeSeriesPoint(time: $0.timestamp, value: Double($0.calories)) }
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
                        ActivityStepsCumulativeChartView(
                            data: stepsData,
                            title: L10n.Activity.stepsTitle
                        )
                        .allowsHitTesting(false)
                        .contentShape(Rectangle())

                        ActivityDistanceCumulativeChartView(
                            data: distanceData,
                            title: L10n.Activity.distanceTitle
                        )
                        .allowsHitTesting(false)
                        .contentShape(Rectangle())

                        ActivityCaloriesCumulativeChartView(
                            data: caloriesData,
                            title: L10n.Activity.caloriesTitle
                        )
                        .allowsHitTesting(false)
                        .contentShape(Rectangle())
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
