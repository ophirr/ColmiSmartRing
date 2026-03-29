//
//  MeasurementChartsView.swift
//  Biosense
//
//  SwiftUI chart views for all measurement types (Activity, HRV, Blood Oxygen, Stress)
//  using SwiftCharts. Each view has a Preview using PreviewData.
//

import SwiftUI
import Charts

// MARK: - Shared X-axis modifier

extension View {
    /// Applies chart X-axis marks and optional X-scale domain for the given time range.
    @ViewBuilder
    func timeRangeXAxis(_ timeRange: TimeRange, domain: ClosedRange<Date>? = nil) -> some View {
        switch timeRange {
        case .hour1:
            self.optionalXDomain(domain).chartXAxis {
                AxisMarks(values: .stride(by: .minute, count: 10)) { _ in
                    AxisValueLabel(format: .dateTime.hour().minute())
                    AxisGridLine()
                }
            }
        case .hour6:
            self.optionalXDomain(domain).chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 1)) { _ in
                    AxisValueLabel(format: .dateTime.hour())
                    AxisGridLine()
                }
            }
        case .hour12:
            self.optionalXDomain(domain).chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 2)) { _ in
                    AxisValueLabel(format: .dateTime.hour())
                    AxisGridLine()
                }
            }
        case .day:
            self.optionalXDomain(domain).chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 4)) { _ in
                    AxisValueLabel(format: .dateTime.hour())
                    AxisGridLine()
                }
            }
        case .week:
            self.optionalXDomain(domain).chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 1)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                    AxisGridLine()
                }
            }
        case .month:
            self.optionalXDomain(domain).chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 5)) { _ in
                    AxisValueLabel(format: .dateTime.day())
                    AxisGridLine()
                }
            }
        }
    }

    @ViewBuilder
    private func optionalXDomain(_ domain: ClosedRange<Date>?) -> some View {
        if let domain {
            self.chartXScale(domain: domain)
        } else {
            self
        }
    }
}

/// Returns a date range spanning most of the calendar day containing `date`,
/// with insets scaled to the time range so bars are visually proportional.
private func dayRange(for date: Date, timeRange: TimeRange) -> ClosedRange<Date> {
    let cal = Calendar.current
    let start = cal.startOfDay(for: date)
    let inset: TimeInterval = timeRange == .week ? 3600 : 1800  // wider gaps for week, tighter for month
    return start.addingTimeInterval(inset)...start.addingTimeInterval(86400 - inset)
}

// MARK: - Activity (Steps, Distance, Calories)

/// Unified bar chart for activity metrics (steps, distance, sleep hours, etc.) —
/// replaces ActivityStepsChartView and ActivityDistanceChartView.
struct ActivityBarChartView: View {
    let data: [TimeSeriesPoint]
    var title: String = "Activity"
    var color: Color = .cyan
    var yLabel: String = "Value"
    var timeRange: TimeRange = .day
    var xDomain: ClosedRange<Date>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Chart(data) { point in
                if timeRange.isSubDay {
                    BarMark(
                        x: .value("Time", point.time),
                        y: .value(yLabel, point.value)
                    )
                    .foregroundStyle(color.gradient)
                } else {
                    BarMark(
                        xStart: .value("Start", dayRange(for: point.time, timeRange: timeRange).lowerBound),
                        xEnd: .value("End", dayRange(for: point.time, timeRange: timeRange).upperBound),
                        y: .value(yLabel, point.value)
                    )
                    .foregroundStyle(color.gradient)
                }
            }
            .timeRangeXAxis(timeRange, domain: xDomain)
            .chartYAxis { AxisMarks(position: .leading) }
            .clipped()
            .frame(height: 180)
        }
        .padding(.vertical, 4)
    }
}

struct ActivityCaloriesChartView: View {
    let data: [TimeSeriesPoint]
    var title: String = "Calories"
    var color: Color = .red
    var timeRange: TimeRange = .day
    var xDomain: ClosedRange<Date>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Chart(data) { point in
                LineMark(
                    x: .value("Time", point.time),
                    y: .value("Kcal", point.value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(color.gradient)
                PointMark(
                    x: .value("Time", point.time),
                    y: .value("Kcal", point.value)
                )
                .foregroundStyle(color)
            }
            .timeRangeXAxis(timeRange, domain: xDomain)
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 180)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Activity cumulative (line charts)

/// Builds cumulative time series from incremental data (sorted by time, running sum).
func cumulativeSeries(from data: [TimeSeriesPoint]) -> [TimeSeriesPoint] {
    let sorted = data.sorted { $0.time < $1.time }
    var running: Double = 0
    return sorted.map { point in
        running += point.value
        return TimeSeriesPoint(time: point.time, value: running)
    }
}

/// Unified cumulative line+area chart — replaces the former per-metric variants
/// (ActivityStepsCumulativeChartView, ActivityDistanceCumulativeChartView,
/// ActivityCaloriesCumulativeChartView).
struct ActivityCumulativeChartView: View {
    let data: [TimeSeriesPoint]
    var title: String = "Cumulative"
    var color: Color = .cyan
    var yLabel: String = "Value"

    private var cumulative: [TimeSeriesPoint] { cumulativeSeries(from: data) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Chart(cumulative) { point in
                LineMark(
                    x: .value("Time", point.time),
                    y: .value(yLabel, point.value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(color.gradient)
                AreaMark(
                    x: .value("Time", point.time),
                    y: .value(yLabel, point.value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(color.gradient.opacity(0.3))
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 4)) { _ in
                    AxisValueLabel(format: .dateTime.hour())
                }
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 180)
            .allowsHitTesting(false)
        }
        .padding(.vertical, 4)
    }
}


// MARK: - Activity cumulative with comparison (no fill: gray weekly avg / yesterday, then today in color)

/// Point with a series label so Chart can color by series via chartForegroundStyleScale.
private struct SeriesTimeSeriesPoint: Identifiable {
    let id = UUID()
    let time: Date
    let value: Double
    let series: String
}

/// Unified cumulative comparison chart (today vs. reference line) — replaces the
/// former per-metric variants (ActivitySteps/Distance/CaloriesCumulativeComparisonChartView).
struct ActivityCumulativeComparisonChartView: View {
    let comparisonData: [TimeSeriesPoint]
    let data: [TimeSeriesPoint]
    var title: String = "Cumulative"
    var comparisonLabel: String = "Weekly average"
    var color: Color = .cyan
    var yLabel: String = "Value"

    private var comparisonCumulative: [TimeSeriesPoint] { cumulativeSeries(from: comparisonData) }
    private var cumulative: [TimeSeriesPoint] { cumulativeSeries(from: data) }

    private var chartData: [SeriesTimeSeriesPoint] {
        comparisonCumulative.map { SeriesTimeSeriesPoint(time: $0.time, value: $0.value, series: "comparison") }
        + cumulative.map { SeriesTimeSeriesPoint(time: $0.time, value: $0.value, series: "today") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Chart(chartData) { point in
                LineMark(
                    x: .value("Time", point.time),
                    y: .value(yLabel, point.value),
                    series: .value("Series", point.series)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(by: .value("Series", point.series))
                .lineStyle(StrokeStyle(lineWidth: point.series == "today" ? 2.5 : 1.5))
            }
            .chartForegroundStyleScale([
                "comparison": Color.gray,
                "today": color
            ])
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 4)) { _ in
                    AxisValueLabel(format: .dateTime.hour())
                }
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 180)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - HRV (ms, line chart 0–178)

struct HRVChartView: View {
    let data: [TimeSeriesPoint]
    var title: String = "HRV"
    var unit: String = "ms"
    var yRange: ClosedRange<Double> = 0...178
    var timeRange: TimeRange = .day
    var xDomain: ClosedRange<Date>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Chart(data) { point in
                LineMark(
                    x: .value("Time", point.time),
                    y: .value(unit, point.value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Color.orange.gradient)
            }
            .chartYScale(domain: yRange)
            .timeRangeXAxis(timeRange, domain: xDomain)
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 200)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Blood Oxygen (%, line+point 85–100)

struct BloodOxygenChartView: View {
    let data: [TimeSeriesPoint]
    var title: String = "Blood Oxygen"
    var unit: String = "%"
    var yRange: ClosedRange<Double> = 85...101
    var timeRange: TimeRange = .day
    var xDomain: ClosedRange<Date>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Chart(data) { point in
                if timeRange.isSubDay {
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value(unit, point.value)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Color.blue.gradient)
                    PointMark(
                        x: .value("Time", point.time),
                        y: .value(unit, point.value)
                    )
                    .symbolSize(20)
                    .foregroundStyle(Color.blue)
                } else {
                    BarMark(
                        xStart: .value("Start", dayRange(for: point.time, timeRange: timeRange).lowerBound),
                        xEnd: .value("End", dayRange(for: point.time, timeRange: timeRange).upperBound),
                        y: .value(unit, point.value)
                    )
                    .foregroundStyle(Color.blue.gradient)
                }
            }
            .chartYScale(domain: yRange)
            .timeRangeXAxis(timeRange, domain: xDomain)
            .chartYAxis { AxisMarks(position: .leading) }
            .clipped()
            .frame(height: 200)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Stress (dynamic range, line chart)

struct StressChartView: View {
    let data: [TimeSeriesPoint]
    var title: String = "Stress"
    var timeRange: TimeRange = .day
    var xDomain: ClosedRange<Date>? = nil

    private var yRange: ClosedRange<Double> {
        let values = data.map(\.value)
        guard let lo = values.min(), let hi = values.max() else { return 0...100 }
        return max(lo - 10, 0)...(hi + 10)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Chart(data) { point in
                if timeRange.isSubDay {
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("Stress", point.value)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Color.mint.gradient)
                } else {
                    BarMark(
                        xStart: .value("Start", dayRange(for: point.time, timeRange: timeRange).lowerBound),
                        xEnd: .value("End", dayRange(for: point.time, timeRange: timeRange).upperBound),
                        y: .value("Stress", point.value)
                    )
                    .foregroundStyle(Color.mint.gradient)
                }
            }
            .chartYScale(domain: yRange)
            .timeRangeXAxis(timeRange, domain: xDomain)
            .chartYAxis { AxisMarks(position: .leading) }
            .clipped()
            .frame(height: 200)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Glucose (mg/dL, line chart with color zones)

struct GlucoseChartView: View {
    let data: [TimeSeriesPoint]
    var title: String = "Glucose"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Chart {
                // Background zone bands
                RectangleMark(yStart: .value("", 0), yEnd: .value("", 70))
                    .foregroundStyle(.red.opacity(0.08))
                RectangleMark(yStart: .value("", 70), yEnd: .value("", 100))
                    .foregroundStyle(.green.opacity(0.08))
                RectangleMark(yStart: .value("", 100), yEnd: .value("", 180))
                    .foregroundStyle(.yellow.opacity(0.08))
                RectangleMark(yStart: .value("", 180), yEnd: .value("", 300))
                    .foregroundStyle(.red.opacity(0.08))
                // Data
                ForEach(data) { point in
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("mg/dL", point.value)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Color.purple.gradient)
                    PointMark(
                        x: .value("Time", point.time),
                        y: .value("mg/dL", point.value)
                    )
                    .symbolSize(16)
                    .foregroundStyle(glucosePointColor(point.value))
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 4)) { _ in
                    AxisValueLabel(format: .dateTime.hour())
                }
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 200)
        }
        .padding(.vertical, 4)
    }

    private func glucosePointColor(_ value: Double) -> Color {
        switch value {
        case ..<70:  return .red
        case 70..<100: return .green
        case 100..<180: return .yellow
        default: return .red
        }
    }
}

// MARK: - Previews

#Preview("Activity – Steps") {
    List {
        ActivityBarChartView(data: PreviewData.stepsPerHour, title: "Steps")
    }
}

#Preview("Activity – Distance") {
    List {
        ActivityBarChartView(data: PreviewData.distancePerHour, title: "Distance", color: .green, yLabel: "Km")
    }
}

#Preview("Activity – Calories") {
    List {
        ActivityCaloriesChartView(data: PreviewData.caloriesPerHour)
    }
}

#Preview("HRV") {
    List {
        HRVChartView(data: PreviewData.hrvPoints)
    }
}

#Preview("Blood Oxygen") {
    List {
        BloodOxygenChartView(data: PreviewData.bloodOxygenPoints)
    }
}

#Preview("Stress") {
    List {
        StressChartView(data: PreviewData.stressPoints)
    }
}

#Preview("All activity charts") {
    List {
        ActivityBarChartView(data: PreviewData.stepsPerHour, title: "Steps")
        ActivityBarChartView(data: PreviewData.distancePerHour, title: "Distance", color: .green, yLabel: "Km")
        ActivityCaloriesChartView(data: PreviewData.caloriesPerHour)
    }
}

#Preview("All activity cumulative") {
    List {
        ActivityCumulativeChartView(data: PreviewData.stepsPerHour, title: "Steps (cumulative)", yLabel: "Steps")
        ActivityCumulativeChartView(data: PreviewData.distancePerHour, title: "Distance (cumulative)", color: .green, yLabel: "Km")
        ActivityCumulativeChartView(data: PreviewData.caloriesPerHour, title: "Calories (cumulative)", color: .red, yLabel: "Kcal")
    }
}

#Preview("All activity cumulative vs weekly avg") {
    List {
        ActivityCumulativeComparisonChartView(
            comparisonData: PreviewData.stepsPerHourWeeklyAverage,
            data: PreviewData.stepsPerHour,
            title: "Steps (cumulative)", yLabel: "Steps"
        )
        ActivityCumulativeComparisonChartView(
            comparisonData: PreviewData.distancePerHourWeeklyAverage,
            data: PreviewData.distancePerHour,
            title: "Distance (cumulative)", color: .green, yLabel: "Km"
        )
        ActivityCumulativeComparisonChartView(
            comparisonData: PreviewData.caloriesPerHourWeeklyAverage,
            data: PreviewData.caloriesPerHour,
            title: "Calories (cumulative)", color: .red, yLabel: "Kcal"
        )
    }
}

#Preview("All metric charts") {
    List {
        HRVChartView(data: PreviewData.hrvPoints)
        BloodOxygenChartView(data: PreviewData.bloodOxygenPoints)
        StressChartView(data: PreviewData.stressPoints)
    }
}
