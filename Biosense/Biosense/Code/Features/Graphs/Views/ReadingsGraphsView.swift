//
//  ReadingsGraphsView.swift
//  Biosense
//
//  Graphs tab: sleep, heart rate, activity, HRV, blood oxygen, stress.
//

import SwiftUI
import SwiftData

struct ReadingsGraphsView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var ringSessionManager: RingSessionManager
    private let includeActivitySection: Bool
    @Query(sort: \StoredSleepDay.syncDate, order: .reverse) private var storedSleepDays: [StoredSleepDay]
    @Query(sort: \StoredHeartRateLog.timestamp, order: .reverse) private var storedHeartRateLogs: [StoredHeartRateLog]
    @Query(sort: \StoredActivitySample.timestamp, order: .reverse) private var storedActivitySamples: [StoredActivitySample]
    @Query(sort: \StoredHRVSample.timestamp, order: .reverse) private var storedHRVSamples: [StoredHRVSample]
    @Query(sort: \StoredBloodOxygenSample.timestamp, order: .reverse) private var storedBloodOxygenSamples: [StoredBloodOxygenSample]
    @Query(sort: \StoredStressSample.timestamp, order: .reverse) private var storedStressSamples: [StoredStressSample]

    @State private var hrvSeriesAccumulator = SplitSeriesPacketParser.SeriesAccumulator()
    @State private var stressSeriesAccumulator = SplitSeriesPacketParser.SeriesAccumulator()
    @State private var selectedTimeRange: TimeRange = .day
    @State private var selectedWeekOffset: Int = 0
    @State private var selectedMonthOffset: Int = 0
    @State private var selectedDate: Date = Date()
    @State private var visibleWeekOffset: Int?

    private let maxPastWeeks = 104
    private static let swiftDataLogDateFormatter = ISO8601DateFormatter()

    private var sortedSleepDays: [StoredSleepDay] {
        storedSleepDays.sorted { $0.sleepDate > $1.sleepDate }
    }

    private var selectedSleepDays: [StoredSleepDay] {
        sortedSleepDays.filter { mondayCalendar.isDate($0.sleepDate, inSameDayAs: selectedDayStart) }
    }

    private var selectedSleepDay: StoredSleepDay? {
        selectedSleepDays.first
    }

    private var mondayCalendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2 // Monday
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    private var todayStart: Date {
        mondayCalendar.startOfDay(for: Date())
    }

    private var currentWeekStart: Date {
        let comps = mondayCalendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: todayStart)
        return mondayCalendar.date(from: comps) ?? todayStart
    }

    private var selectedDayStart: Date {
        mondayCalendar.startOfDay(for: selectedDate)
    }

    private var selectedDayEnd: Date {
        mondayCalendar.date(byAdding: .day, value: 1, to: selectedDayStart) ?? selectedDayStart.addingTimeInterval(24 * 60 * 60)
    }

    // MARK: - Multi-day range (week / month)

    private func monthStart(for offset: Int) -> Date {
        let comps = mondayCalendar.dateComponents([.year, .month], from: Date())
        let thisMonthStart = mondayCalendar.date(from: comps) ?? Date()
        return mondayCalendar.date(byAdding: .month, value: -offset, to: thisMonthStart) ?? thisMonthStart
    }

    private var selectedRangeStart: Date {
        switch selectedTimeRange {
        case .day:   return selectedDayStart
        case .week:  return weekStart(for: selectedWeekOffset)
        case .month: return monthStart(for: selectedMonthOffset)
        }
    }

    private var selectedRangeEnd: Date {
        switch selectedTimeRange {
        case .day:   return selectedDayEnd
        case .week:
            return mondayCalendar.date(byAdding: .day, value: 7, to: weekStart(for: selectedWeekOffset)) ?? selectedDayEnd
        case .month:
            return mondayCalendar.date(byAdding: .month, value: 1, to: monthStart(for: selectedMonthOffset)) ?? selectedDayEnd
        }
    }

    /// X-axis domain for week/month charts (nil for day mode).
    private var chartXDomain: ClosedRange<Date>? {
        guard selectedTimeRange != .day else { return nil }
        return selectedRangeStart...selectedRangeEnd
    }

    /// Label for the currently selected week (e.g. "Mar 3 – 9, 2026").
    private var selectedWeekLabel: String {
        let start = weekStart(for: selectedWeekOffset)
        let end = mondayCalendar.date(byAdding: .day, value: 6, to: start) ?? start
        let fmt = Date.FormatStyle().month(.abbreviated).day()
        let yearFmt = Date.FormatStyle().year()
        return "\(start.formatted(fmt)) – \(end.formatted(fmt)), \(end.formatted(yearFmt))"
    }

    /// Label for the currently selected month (e.g. "February 2026").
    private var selectedMonthLabel: String {
        let start = monthStart(for: selectedMonthOffset)
        return start.formatted(.dateTime.month(.wide).year())
    }

    // MARK: - Range-filtered data (week / month)

    private var rangeActivitySamples: [StoredActivitySample] {
        storedActivitySamples.filter { $0.timestamp >= selectedRangeStart && $0.timestamp < selectedRangeEnd }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private var rangeHRVSamples: [StoredHRVSample] {
        storedHRVSamples.filter { $0.timestamp >= selectedRangeStart && $0.timestamp < selectedRangeEnd }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private var rangeBloodOxygenSamples: [StoredBloodOxygenSample] {
        storedBloodOxygenSamples.filter { $0.timestamp >= selectedRangeStart && $0.timestamp < selectedRangeEnd }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private var rangeStressSamples: [StoredStressSample] {
        storedStressSamples.filter { $0.timestamp >= selectedRangeStart && $0.timestamp < selectedRangeEnd }
            .sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Daily aggregation helpers

    /// Groups points by calendar day and reduces each day to a single value.
    private func dailyAggregated(_ points: [TimeSeriesPoint], reduce: ([Double]) -> Double) -> [TimeSeriesPoint] {
        let grouped = Dictionary(grouping: points) { mondayCalendar.startOfDay(for: $0.time) }
        return grouped.map { (day, pts) in
            TimeSeriesPoint(time: day, value: reduce(pts.map(\.value)))
        }.sorted { $0.time < $1.time }
    }

    private func dailySum(_ points: [TimeSeriesPoint]) -> [TimeSeriesPoint] {
        dailyAggregated(points) { $0.reduce(0, +) }
    }

    private func dailyAverage(_ points: [TimeSeriesPoint]) -> [TimeSeriesPoint] {
        dailyAggregated(points) { vals in vals.isEmpty ? 0 : vals.reduce(0, +) / Double(vals.count) }
    }

    // MARK: - Aggregated range data

    private var rangeActivityStepsDaily: [TimeSeriesPoint] {
        dailySum(rangeActivitySamples.map { TimeSeriesPoint(time: $0.timestamp, value: Double($0.steps)) })
    }
    private var rangeActivityDistanceDaily: [TimeSeriesPoint] {
        dailySum(rangeActivitySamples.map { TimeSeriesPoint(time: $0.timestamp, value: $0.distanceKm) })
    }
    private var rangeActivityCaloriesDaily: [TimeSeriesPoint] {
        dailySum(rangeActivitySamples.map { TimeSeriesPoint(time: $0.timestamp, value: Double($0.calories)) })
    }
    private var rangeHRVDaily: [TimeSeriesPoint] {
        dailyAverage(rangeHRVSamples.map { TimeSeriesPoint(time: $0.timestamp, value: $0.value) })
    }
    private var rangeBloodOxygenDaily: [TimeSeriesPoint] {
        dailyAverage(rangeBloodOxygenSamples.map { TimeSeriesPoint(time: $0.timestamp, value: $0.value) })
    }
    private var rangeStressDaily: [TimeSeriesPoint] {
        dailyAverage(rangeStressSamples.map { TimeSeriesPoint(time: $0.timestamp, value: $0.value) })
    }

    /// Daily average heart rate from StoredHeartRateLog (one log per day).
    private var rangeHeartRateDailyAverages: [TimeSeriesPoint] {
        storedHeartRateLogs
            .filter { $0.dayStart >= selectedRangeStart && $0.dayStart < selectedRangeEnd }
            .compactMap { log in
                let valid = log.heartRates.filter { $0 > 0 }
                guard !valid.isEmpty else { return nil }
                let avg = Double(valid.reduce(0, +)) / Double(valid.count)
                return TimeSeriesPoint(time: log.dayStart, value: avg)
            }
            .sorted { $0.time < $1.time }
    }

    /// Sleep duration per night (in hours) for the selected range.
    private var rangeSleepDurationDaily: [TimeSeriesPoint] {
        sortedSleepDays
            .filter { $0.sleepDate >= selectedRangeStart && $0.sleepDate < selectedRangeEnd }
            .map { day in
                let hours = Double(day.toSleepDay().totalDurationMinutes) / 60.0
                return TimeSeriesPoint(time: day.sleepDate, value: hours)
            }
            .sorted { $0.time < $1.time }
    }

    private var selectedDayHeartRateLogs: [StoredHeartRateLog] {
        storedHeartRateLogs
            .filter { isWithinSelectedDay($0.dayStart) }
            .sorted { $0.timestamp > $1.timestamp }
    }

    private var selectedDayActivitySamples: [StoredActivitySample] {
        storedActivitySamples
            .filter { isWithinSelectedDay($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private var selectedDayHRVSamples: [StoredHRVSample] {
        storedHRVSamples
            .filter { isWithinSelectedDay($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private var selectedDayBloodOxygenSamples: [StoredBloodOxygenSample] {
        storedBloodOxygenSamples
            .filter { isWithinSelectedDay($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private var selectedDayStressSamples: [StoredStressSample] {
        storedStressSamples
            .filter { isWithinSelectedDay($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private var weekOffsets: [Int] {
        Array(stride(from: maxPastWeeks, through: 0, by: -1))
    }

    init(ringSessionManager: RingSessionManager, includeActivitySection: Bool = true) {
        self.ringSessionManager = ringSessionManager
        self.includeActivitySection = includeActivitySection
    }

    private var activityStepsData: [TimeSeriesPoint] {
        return selectedDayActivitySamples
            .map { TimeSeriesPoint(time: $0.timestamp, value: Double($0.steps)) }
    }

    private var activityDistanceData: [TimeSeriesPoint] {
        return selectedDayActivitySamples
            .map { TimeSeriesPoint(time: $0.timestamp, value: $0.distanceKm) }
    }

    private var activityCaloriesData: [TimeSeriesPoint] {
        return selectedDayActivitySamples
            .map { TimeSeriesPoint(time: $0.timestamp, value: Double($0.calories)) }
    }

    private var hrvData: [TimeSeriesPoint] {
        let now = Date()
        return selectedDayHRVSamples
            .filter { $0.timestamp <= now }
            .map { TimeSeriesPoint(time: $0.timestamp, value: $0.value) }
    }

    private var bloodOxygenData: [TimeSeriesPoint] {
        let now = Date()
        return selectedDayBloodOxygenSamples
            .filter { $0.timestamp <= now }
            .map { TimeSeriesPoint(time: $0.timestamp, value: $0.value) }
    }

    private var stressData: [TimeSeriesPoint] {
        let now = Date()
        return selectedDayStressSamples
            .filter { $0.timestamp <= now }
            .map { TimeSeriesPoint(time: $0.timestamp, value: $0.value) }
    }

    var body: some View {
        NavigationStack {
            List {
                realTimeTrackingSection
                timeRangePickerSection
                heartRateSection
                bloodOxygenSection
                if includeActivitySection {
                    activitySection
                }
                hrvSection
                stressSection
                sleepSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.Graphs.navTitle)
            .navigationBarTitleDisplayMode(.large)
            .refreshable { await refreshAllMetrics() }
            .simultaneousGesture(
                DragGesture(minimumDistance: 50)
                    .onEnded { value in
                        // Require clearly horizontal swipe (not vertical scroll)
                        guard abs(value.translation.width) > abs(value.translation.height) * 2.0 else { return }
                        guard abs(value.translation.width) > 80 else { return }
                        let swipedRight = value.translation.width > 0
                        navigateTimePeriod(forward: !swipedRight)
                    }
            )
            .onAppear {
                selectedDate = todayStart
                visibleWeekOffset = selectedWeekOffset
                wireLiveMetricCallbacks()
            }
            .onChange(of: selectedTimeRange) { _, _ in
                // Reset to current date/week/month so user doesn't land on an empty historical period
                selectedDate = todayStart
                selectedWeekOffset = 0
                selectedMonthOffset = 0
                visibleWeekOffset = 0
            }
        }
    }

    // MARK: - Time range picker

    private var timeRangePickerSection: some View {
        Section {
            Picker("Time Range", selection: $selectedTimeRange) {
                ForEach(TimeRange.allCases) { range in
                    Text(range.displayName).tag(range)
                }
            }
            .pickerStyle(.segmented)

            switch selectedTimeRange {
            case .day:
                dayPickerInline
            case .week:
                weekNavigationRow
            case .month:
                monthNavigationRow
            }
        }
    }

    private var dayPickerInline: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 12) {
                ForEach(weekOffsets, id: \.self) { weekOffset in
                    weekRow(for: weekOffset)
                        .id(weekOffset)
                        .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $visibleWeekOffset, anchor: .center)
        .onChange(of: visibleWeekOffset) { _, newValue in
            guard let newValue else { return }
            let weekday = weekdayIndex(for: selectedDate, weekStart: weekStart(for: selectedWeekOffset))
            selectedWeekOffset = newValue
            moveSelectedDateToCurrentDisplayedWeek(weekdayIndex: weekday)
        }
    }

    private var weekNavigationRow: some View {
        HStack {
            Button { selectedWeekOffset += 1 } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(selectedWeekOffset >= maxPastWeeks)
            Spacer()
            Text(selectedWeekLabel)
                .font(.subheadline.weight(.medium))
            Spacer()
            Button { selectedWeekOffset -= 1 } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(selectedWeekOffset <= 0)
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 4)
    }

    private var monthNavigationRow: some View {
        HStack {
            Button { selectedMonthOffset += 1 } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(selectedMonthOffset >= 24)
            Spacer()
            Text(selectedMonthLabel)
                .font(.subheadline.weight(.medium))
            Spacer()
            Button { selectedMonthOffset -= 1 } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(selectedMonthOffset <= 0)
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func weekRow(for weekOffset: Int) -> some View {
        let weekStart = weekStart(for: weekOffset)
        let dates = weekDates(for: weekOffset)
        HStack(spacing: 8) {
            ForEach(Array(dates.enumerated()), id: \.offset) { index, date in
                let selected = weekOffset == selectedWeekOffset && mondayCalendar.isDate(date, inSameDayAs: selectedDayStart)
                let isFuture = date > todayStart
                Button {
                    guard !isFuture else { return }
                    selectedWeekOffset = weekOffset
                    visibleWeekOffset = weekOffset
                    selectedDate = mondayCalendar.startOfDay(for: date)
                } label: {
                    VStack(spacing: 6) {
                        Text(date, format: .dateTime.weekday(.abbreviated))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(isFuture ? .tertiary : .secondary)
                        Text(date, format: .dateTime.day())
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(
                                selected ? Color.white : (isFuture ? Color.gray : Color.primary)
                            )
                            .frame(width: 34, height: 34)
                            .background(selected ? Color.purple : Color.clear)
                            .clipShape(Circle())
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(isFuture)
                .buttonStyle(.plain)
                .accessibilityLabel(Text(date, format: .dateTime.weekday(.wide).day().month().year()))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity)
        .onAppear {
            // Keep selection valid if user scrolls far while focused on a future day in current week.
            if weekOffset == 0 && selectedDayStart > todayStart {
                selectedDate = todayStart
            }
        }
        .id(weekStart)
    }

    // MARK: - Sleep

    private var sleepSection: some View {
        Section {
            switch selectedTimeRange {
            case .day:
                if let storedDay = selectedSleepDay {
                    let day = storedDay.toSleepDay()
                    VStack(alignment: .leading, spacing: 16) {
                        SleepChartKitView(day: day, nightDate: storedDay.sleepDate)
                        SleepStageGraphView(day: day)
                    }
                    .padding(.vertical, 8)
                } else {
                    emptyStateView(message: L10n.Graphs.noSleepData)
                }
            case .week, .month:
                if rangeSleepDurationDaily.isEmpty {
                    emptyStateView(message: L10n.Graphs.noSleepData)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        sleepSummaryRow
                        ActivityStepsChartView(
                            data: rangeSleepDurationDaily,
                            title: "Sleep (hours)",
                            color: .indigo,
                            timeRange: selectedTimeRange,
                            xDomain: chartXDomain
                        )
                    }
                    .padding(.vertical, 8)
                }
            }
        } header: {
            Label(L10n.Graphs.sleepSection, systemImage: "bed.double.fill")
        }
    }

    private var sleepSummaryRow: some View {
        let values = rangeSleepDurationDaily.map(\.value)
        let avg = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        let avgH = Int(avg)
        let avgM = Int((avg - Double(avgH)) * 60)
        return HStack {
            summaryPill(label: "Avg sleep", value: "\(avgH)h \(avgM)m")
            summaryPill(label: "Nights", value: "\(values.count)")
        }
    }

    /// Navigate the selected time period by one increment.
    /// `forward: true` moves toward the present; `forward: false` moves into the past.
    private func navigateTimePeriod(forward: Bool) {
        switch selectedTimeRange {
        case .day:
            if forward {
                guard selectedDayStart < todayStart else { return }
                selectedDate = mondayCalendar.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
            } else {
                selectedDate = mondayCalendar.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
            }
            // Keep the week offset & visible week in sync with the new date.
            let dayWeekStart = mondayCalendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: selectedDate)
            let dateWeekStart = mondayCalendar.date(from: dayWeekStart) ?? currentWeekStart
            let weekDelta = mondayCalendar.dateComponents([.day], from: dateWeekStart, to: currentWeekStart).day ?? 0
            let newWeekOffset = weekDelta / 7
            selectedWeekOffset = newWeekOffset
            visibleWeekOffset = newWeekOffset
        case .week:
            if forward {
                guard selectedWeekOffset > 0 else { return }
                selectedWeekOffset -= 1
            } else {
                guard selectedWeekOffset < maxPastWeeks else { return }
                selectedWeekOffset += 1
            }
            visibleWeekOffset = selectedWeekOffset
        case .month:
            if forward {
                guard selectedMonthOffset > 0 else { return }
                selectedMonthOffset -= 1
            } else {
                guard selectedMonthOffset < 24 else { return }
                selectedMonthOffset += 1
            }
        }
    }

    private func moveSelectedDateToCurrentDisplayedWeek(weekdayIndex: Int) {
        guard let target = mondayCalendar.date(byAdding: .day, value: weekdayIndex, to: weekStart(for: selectedWeekOffset)) else { return }
        let start = mondayCalendar.startOfDay(for: target)
        if selectedWeekOffset == 0 && start > todayStart {
            selectedDate = todayStart
        } else {
            selectedDate = start
        }
    }

    private func weekStart(for weekOffset: Int) -> Date {
        mondayCalendar.date(byAdding: .day, value: -7 * weekOffset, to: currentWeekStart) ?? currentWeekStart
    }

    private func weekDates(for weekOffset: Int) -> [Date] {
        let start = weekStart(for: weekOffset)
        return (0..<7).compactMap { mondayCalendar.date(byAdding: .day, value: $0, to: start) }
    }

    private func weekdayIndex(for date: Date, weekStart: Date) -> Int {
        let start = mondayCalendar.startOfDay(for: weekStart)
        let selected = mondayCalendar.startOfDay(for: date)
        let delta = mondayCalendar.dateComponents([.day], from: start, to: selected).day ?? 0
        return min(max(delta, 0), 6)
    }

    // MARK: - Heart rate

    private var heartRateSection: some View {
        Section {
            switch selectedTimeRange {
            case .day:
                if selectedDayHeartRateLogs.isEmpty {
                    emptyStateView(message: L10n.Graphs.noHeartRateData)
                } else {
                    if let log = selectedHeartRateLog {
                        heartRateDetailChart(log: log)
                    }
                }
            case .week, .month:
                if rangeHeartRateDailyAverages.isEmpty {
                    emptyStateView(message: L10n.Graphs.noHeartRateData)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        heartRateSummaryRow
                        // Reuse HeartRateDataPoint for the daily-avg line chart
                        let dailyPoints = rangeHeartRateDailyAverages.map {
                            HeartRateDataPoint(heartRate: Int($0.value), time: $0.time)
                        }
                        Text("Daily average heart rate")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        HeartRateGraphView(data: dailyPoints, timeRange: selectedTimeRange, xDomain: chartXDomain)
                    }
                    .padding(.vertical, 8)
                }
            }
        } header: {
            Label(L10n.Graphs.heartRateSection, systemImage: "heart.fill")
        }
    }

    private var heartRateSummaryRow: some View {
        let values = rangeHeartRateDailyAverages.map(\.value)
        let avg = values.isEmpty ? 0 : Int(values.reduce(0, +) / Double(values.count))
        let minV = values.isEmpty ? 0 : Int(values.min() ?? 0)
        let maxV = values.isEmpty ? 0 : Int(values.max() ?? 0)
        return HStack {
            summaryPill(label: "Avg", value: "\(avg) bpm")
            summaryPill(label: "Min", value: "\(minV) bpm")
            summaryPill(label: "Max", value: "\(maxV) bpm")
        }
    }

    private var selectedHeartRateLog: StoredHeartRateLog? {
        selectedDayHeartRateLogs.first
    }

    private func heartRateDetailChart(log: StoredHeartRateLog) -> some View {
        let points: [HeartRateDataPoint] = log.toHeartRateLog().heartRatesWithTimes()
            .map { HeartRateDataPoint(heartRate: $0.0, time: $0.1) }
        let interval = ringSessionManager.hrLogIntervalMinutes ?? 5
        return VStack(alignment: .leading, spacing: 8) {
            Text("Heart rate (\(interval)‑min intervals)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            if points.isEmpty {
                Text(L10n.Graphs.noValidReadings)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                HeartRateGraphView(data: points, xDomain: selectedDayStart...selectedDayEnd)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Activity

    private var activitySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                switch selectedTimeRange {
                case .day:
                    if activityStepsData.isEmpty || activityDistanceData.isEmpty || activityCaloriesData.isEmpty {
                        Text(L10n.Graphs.sampleActivity)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        ActivityStepsChartView(data: activityStepsData)
                        ActivityStepsCumulativeComparisonChartView(
                            comparisonData: PreviewData.stepsPerHourWeeklyAverage,
                            data: activityStepsData
                        )
                        ActivityDistanceChartView(data: activityDistanceData)
                        ActivityDistanceCumulativeComparisonChartView(
                            comparisonData: PreviewData.distancePerHourWeeklyAverage,
                            data: activityDistanceData
                        )
                        ActivityCaloriesChartView(data: activityCaloriesData)
                        ActivityCaloriesCumulativeComparisonChartView(
                            comparisonData: PreviewData.caloriesPerHourWeeklyAverage,
                            data: activityCaloriesData
                        )
                    }
                case .week, .month:
                    if rangeActivityStepsDaily.isEmpty {
                        Text(L10n.Graphs.sampleActivity)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        activitySummaryRow
                        ActivityStepsChartView(data: rangeActivityStepsDaily, title: "Steps per day", timeRange: selectedTimeRange, xDomain: chartXDomain)
                        ActivityDistanceChartView(data: rangeActivityDistanceDaily, title: "Distance per day", timeRange: selectedTimeRange, xDomain: chartXDomain)
                        ActivityCaloriesChartView(data: rangeActivityCaloriesDaily, title: "Calories per day", timeRange: selectedTimeRange, xDomain: chartXDomain)
                    }
                }
            }
        } header: {
            Label(L10n.Graphs.activitySection, systemImage: "figure.walk")
        }
    }

    private var activitySummaryRow: some View {
        let totalSteps = Int(rangeActivityStepsDaily.map(\.value).reduce(0, +))
        let totalDist = rangeActivityDistanceDaily.map(\.value).reduce(0, +)
        let totalCal = Int(rangeActivityCaloriesDaily.map(\.value).reduce(0, +))
        return HStack {
            summaryPill(label: "Steps", value: "\(totalSteps)")
            summaryPill(label: "Distance", value: String(format: "%.1f km", totalDist))
            summaryPill(label: "Calories", value: "\(totalCal)")
        }
    }

    // MARK: - HRV

    private var hrvSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                switch selectedTimeRange {
                case .day:
                    if hrvData.isEmpty {
                        Text(L10n.Graphs.sampleHRV)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        HRVChartView(data: hrvData, xDomain: selectedDayStart...selectedDayEnd)
                    }
                case .week, .month:
                    if rangeHRVDaily.isEmpty {
                        Text(L10n.Graphs.sampleHRV)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        metricSummaryRow(data: rangeHRVDaily, unit: "ms")
                        HRVChartView(data: rangeHRVDaily, title: "HRV (daily avg)", timeRange: selectedTimeRange, xDomain: chartXDomain)
                    }
                }
            }
        } header: {
            Label(L10n.Graphs.hrvSection, systemImage: "waveform.path.ecg")
        }
    }

    // MARK: - Blood oxygen

    private var bloodOxygenSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                switch selectedTimeRange {
                case .day:
                    if bloodOxygenData.isEmpty {
                        Text(L10n.Graphs.sampleBloodOxygen)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        BloodOxygenChartView(data: bloodOxygenData, xDomain: selectedDayStart...selectedDayEnd)
                    }
                case .week, .month:
                    if rangeBloodOxygenDaily.isEmpty {
                        Text(L10n.Graphs.sampleBloodOxygen)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        metricSummaryRow(data: rangeBloodOxygenDaily, unit: "%")
                        BloodOxygenChartView(data: rangeBloodOxygenDaily, title: "Blood Oxygen (daily avg)", timeRange: selectedTimeRange, xDomain: chartXDomain)
                    }
                }
            }
        } header: {
            Label(L10n.Graphs.bloodOxygenSection, systemImage: "drop.fill")
        }
    }

    // MARK: - Stress

    private var stressSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                switch selectedTimeRange {
                case .day:
                    if stressData.isEmpty {
                        Text(L10n.Graphs.sampleStress)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        StressChartView(data: stressData, xDomain: selectedDayStart...selectedDayEnd)
                    }
                case .week, .month:
                    if rangeStressDaily.isEmpty {
                        Text(L10n.Graphs.sampleStress)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        metricSummaryRow(data: rangeStressDaily, unit: "")
                        StressChartView(data: rangeStressDaily, title: "Stress (daily avg)", timeRange: selectedTimeRange, xDomain: chartXDomain)
                    }
                }
            }
        } header: {
            Label(L10n.Graphs.stressSection, systemImage: "leaf.fill")
        }
    }

    // MARK: - Real-time tracking

    private var realTimeTrackingSection: some View {
        Section {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    // Heart Rate
                    realTimeCard(
                        icon: "heart.fill",
                        label: L10n.Graphs.heartRateSection,
                        value: ringSessionManager.realTimeHeartRateBPM.map { "\($0)" },
                        unit: L10n.HomeSummary.bpm,
                        color: .red
                    )
                    // Blood Oxygen
                    realTimeCard(
                        icon: "lungs.fill",
                        label: "SpO2",
                        value: ringSessionManager.realTimeBloodOxygenPercent.map { "\($0)" },
                        unit: "%",
                        color: .cyan
                    )
                }
                HStack(spacing: 12) {
                    // Body Temperature
                    realTimeCard(
                        icon: "thermometer.medium",
                        label: "Temp",
                        value: ringSessionManager.realTimeTemperatureCelsius.map { String(format: "%.1f", $0) },
                        unit: "°C",
                        color: .orange
                    )
                }
            }
            .padding(.vertical, 4)
        } header: {
            Label(L10n.Graphs.realtimeSection, systemImage: "waveform.path.ecg")
        }
    }

    private func realTimeCard(icon: String, label: String, value: String?, unit: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Label(label, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if let value {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(color)
                        .contentTransition(.numericText())
                    Text(unit)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(L10n.HomeSummary.noData)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func wireLiveMetricCallbacks() {
        // Auto-persistence is wired globally by RingDataPersistenceCoordinator in BiosenseApp.
        // Keep only the explicit refresh requests when opening the Graphs screen.
        if ringSessionManager.peripheralConnected {
            ringSessionManager.syncActivityData(dayOffset: 0)
            ringSessionManager.syncHRVData(dayOffset: 0)
            ringSessionManager.syncBloodOxygen(dayOffset: 0)
            ringSessionManager.syncPressureData(dayOffset: 0)
        }
    }

    /// Pull-to-refresh: re-request today's data for all metrics from the ring.
    private func refreshAllMetrics() async {
        guard ringSessionManager.peripheralConnected else { return }
        ringSessionManager.getHeartRateLog(dayOffset: 0) { _ in }
        ringSessionManager.syncActivityData(dayOffset: 0)
        ringSessionManager.syncHRVData(dayOffset: 0)
        ringSessionManager.syncBloodOxygen(dayOffset: 0)
        ringSessionManager.syncPressureData(dayOffset: 0)
        // Give the ring time to respond before the spinner dismisses.
        try? await Task.sleep(for: .seconds(2))
    }

    private func todayAtHour(_ hour: Int) -> Date {
        Calendar.current.date(bySettingHour: max(0, min(23, hour)), minute: 0, second: 0, of: Date()) ?? Date()
    }

    private func consumeActivityPacket(_ packet: [UInt8]) {
        // Commands 67 (SportsData): [cmd, year, month, day, time, calories(2), steps(2), distance(2), ...]
        guard packet.count >= 11, packet[0] == 67 else { return }
        let hour = Int(packet[4])
        // SportsDataResponse fields are uint16 and ring payload uses little-endian across this protocol.
        let calories = Int(packet[5]) | (Int(packet[6]) << 8)
        let steps = Int(packet[7]) | (Int(packet[8]) << 8)
        let distanceRaw = Int(packet[9]) | (Int(packet[10]) << 8)
        let distanceKm = Double(distanceRaw) / 100.0

        upsertStoredActivitySample(timestamp: todayAtHour(hour), steps: steps, distanceKm: distanceKm, calories: calories)
    }

    private func consumeSplitSeriesPacket(_ packet: [UInt8], isHRV: Bool) {
        // Commands 57 (HRV) / 55 (Pressure): split array format.
        if isHRV {
            guard let series = hrvSeriesAccumulator.consume(packet) else { return }
            persistHRVSeries(series)
        } else {
            guard let series = stressSeriesAccumulator.consume(packet) else { return }
            persistStressSeries(series)
        }
    }

    private func consumeBloodOxygenPayload(_ payload: [UInt8]) {
        let decoded = decodeBigDataBloodOxygen(payload)
        if !decoded.isEmpty {
            persistBloodOxygenSeries(decoded)
        }
    }

    private func upsertStoredActivitySample(timestamp: Date, steps: Int, distanceKm: Double, calories: Int) {
        let action: String
        if let existing = storedActivitySamples.first(where: { $0.timestamp == timestamp }) {
            existing.steps = steps
            existing.distanceKm = distanceKm
            existing.calories = calories
            action = "UPDATE"
        } else {
            modelContext.insert(StoredActivitySample(timestamp: timestamp, steps: steps, distanceKm: distanceKm, calories: calories))
            action = "INSERT"
        }
        tLog("========== SWIFTDATA SAVE: Activity ==========")
        tLog("action: \(action)")
        tLog("timestamp: \(swiftDataLogDate(timestamp))")
        tLog("steps: \(steps), distanceKm: \(distanceKm), calories: \(calories)")
        do {
            try modelContext.save()
            tLog("result: SUCCESS")
        } catch {
            tLog("result: FAILED - \(error)")
        }
        tLog("==============================================")
    }

    private func persistHRVSeries(_ series: [TimeSeriesPoint]) {
        var inserted: [TimeSeriesPoint] = []
        var updated: [TimeSeriesPoint] = []
        for point in series {
            if let existing = storedHRVSamples.first(where: { $0.timestamp == point.time }) {
                existing.value = point.value
                updated.append(point)
            } else {
                modelContext.insert(StoredHRVSample(timestamp: point.time, value: point.value))
                inserted.append(point)
            }
        }
        tLog("============ SWIFTDATA SAVE: HRV =============")
        tLog("inserted: \(inserted.count), updated: \(updated.count), totalSeriesPoints: \(series.count)")
        tLog("insertedPoints: \(formatSeriesPointsForLog(inserted))")
        tLog("updatedPoints: \(formatSeriesPointsForLog(updated))")
        do {
            try modelContext.save()
            tLog("result: SUCCESS")
        } catch {
            tLog("result: FAILED - \(error)")
        }
        tLog("==============================================")
    }

    private func persistBloodOxygenSeries(_ series: [TimeSeriesPoint]) {
        var inserted: [TimeSeriesPoint] = []
        var updated: [TimeSeriesPoint] = []
        for point in series {
            if let existing = storedBloodOxygenSamples.first(where: { $0.timestamp == point.time }) {
                existing.value = point.value
                updated.append(point)
            } else {
                modelContext.insert(StoredBloodOxygenSample(timestamp: point.time, value: point.value))
                inserted.append(point)
            }
        }
        tLog("====== SWIFTDATA SAVE: Blood Oxygen ======")
        tLog("inserted: \(inserted.count), updated: \(updated.count), totalSeriesPoints: \(series.count)")
        tLog("insertedPoints: \(formatSeriesPointsForLog(inserted))")
        tLog("updatedPoints: \(formatSeriesPointsForLog(updated))")
        do {
            try modelContext.save()
            tLog("result: SUCCESS")
        } catch {
            tLog("result: FAILED - \(error)")
        }
        tLog("==========================================")
    }

    private func persistStressSeries(_ series: [TimeSeriesPoint]) {
        var inserted: [TimeSeriesPoint] = []
        var updated: [TimeSeriesPoint] = []
        for point in series {
            if let existing = storedStressSamples.first(where: { $0.timestamp == point.time }) {
                existing.value = point.value
                updated.append(point)
            } else {
                modelContext.insert(StoredStressSample(timestamp: point.time, value: point.value))
                inserted.append(point)
            }
        }
        tLog("=========== SWIFTDATA SAVE: Stress ===========")
        tLog("inserted: \(inserted.count), updated: \(updated.count), totalSeriesPoints: \(series.count)")
        tLog("insertedPoints: \(formatSeriesPointsForLog(inserted))")
        tLog("updatedPoints: \(formatSeriesPointsForLog(updated))")
        do {
            try modelContext.save()
            tLog("result: SUCCESS")
        } catch {
            tLog("result: FAILED - \(error)")
        }
        tLog("==============================================")
    }

    private func swiftDataLogDate(_ date: Date) -> String {
        Self.swiftDataLogDateFormatter.string(from: date)
    }

    private func formatSeriesPointsForLog(_ points: [TimeSeriesPoint]) -> String {
        guard !points.isEmpty else { return "[]" }
        let values = points.map { point in
            "{time: \(swiftDataLogDate(point.time)), value: \(point.value)}"
        }
        return "[\(values.joined(separator: ", "))]"
    }

    private func decodeBigDataBloodOxygen(_ payload: [UInt8]) -> [TimeSeriesPoint] {
        guard payload.count >= 4 else { return [] }

        // Candidate A: concatenated day blocks.
        // Seen on some firmware as repeated blocks in one payload (multi-day response).
        // We support common block sizes and pick the decode with most valid points.
        let multiDayCandidates = [50, 49, 48].compactMap { blockSize in
            decodeBloodOxygenFixedBlocks(payload, blockSize: blockSize)
        }
        if let best = multiDayCandidates.max(by: { $0.count < $1.count }), best.count >= 24 {
            return best
        }

        // Candidate B: documented single-day payload: [unk, daysAgo, (min,max)...]
        let daysAgo = Int(payload[1])
        let sampleBytes = Array(payload.dropFirst(2))
        let singleDay = decodeBloodOxygenDaySamples(sampleBytes, daysAgo: daysAgo)
        if !singleDay.isEmpty {
            return singleDay
        }

        return []
    }

    private func decodeBloodOxygenFixedBlocks(_ payload: [UInt8], blockSize: Int) -> [TimeSeriesPoint]? {
        guard blockSize >= 4, payload.count % blockSize == 0 else { return nil }
        let blockCount = payload.count / blockSize
        guard blockCount > 1 else { return nil }

        var result: [TimeSeriesPoint] = []
        var offset = 0
        for _ in 0..<blockCount {
            let block = Array(payload[offset..<(offset + blockSize)])
            offset += blockSize
            guard block.count >= 3 else { return nil }

            let daysAgo = Int(block[1])
            let dayBytes = Array(block.dropFirst(2))

            // If odd-sized day bytes, treat first byte as optional count/marker and decode the remainder.
            let normalized: [UInt8]
            if dayBytes.count % 2 == 1, dayBytes.count > 3 {
                normalized = Array(dayBytes.dropFirst())
            } else {
                normalized = dayBytes
            }

            let points = decodeBloodOxygenDaySamples(normalized, daysAgo: daysAgo)
            if points.isEmpty { return nil }
            result.append(contentsOf: points)
        }
        return result
    }

    private func decodeBloodOxygenDaySamples(_ sampleBytes: [UInt8], daysAgo: Int) -> [TimeSeriesPoint] {
        guard sampleBytes.count >= 2 else { return [] }

        // Primary: min/max pairs (hourly averages) as documented.
        if sampleBytes.count % 2 == 0 {
            var points: [TimeSeriesPoint] = []
            var hour = 0
            var i = 0
            while i + 1 < sampleBytes.count, hour < 24 {
                let minV = Double(sampleBytes[i])
                let maxV = Double(sampleBytes[i + 1])
                let avg = (minV + maxV) / 2.0
                points.append(TimeSeriesPoint(time: dayAtHour(daysAgo: daysAgo, hour: hour), value: avg))
                i += 2
                hour += 1
            }
            return points.filter { $0.value > 0 }
        }

        // Fallback: single-value samples with 30-minute interval.
        return sampleBytes.enumerated().map { idx, value in
            let hour = idx / 2
            let minute = (idx % 2) * 30
            return TimeSeriesPoint(time: dayAtTime(daysAgo: daysAgo, hour: hour, minute: minute), value: Double(value))
        }.filter { $0.value > 0 }
    }

    private func dayAtHour(daysAgo: Int, hour: Int) -> Date {
        RingSlotTimestamp.date(daysAgo: daysAgo, hour: hour)
    }

    private func dayAtTime(daysAgo: Int, hour: Int, minute: Int) -> Date {
        // For sub-hour precision (30-min SpO2 fallback), start from the UTC hour
        // and add the minute offset.
        let hourDate = RingSlotTimestamp.date(daysAgo: daysAgo, hour: hour)
        return hourDate.addingTimeInterval(TimeInterval(max(0, min(59, minute)) * 60))
    }

    // MARK: - Summary helpers

    private func summaryPill(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Generic summary row for metrics with avg/min/max.
    private func metricSummaryRow(data: [TimeSeriesPoint], unit: String) -> some View {
        let values = data.map(\.value)
        let avg = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        let minV = values.min() ?? 0
        let maxV = values.max() ?? 0
        let suffix = unit.isEmpty ? "" : " \(unit)"
        return HStack {
            summaryPill(label: "Avg", value: String(format: "%.0f%@", avg, suffix))
            summaryPill(label: "Min", value: String(format: "%.0f%@", minV, suffix))
            summaryPill(label: "Max", value: String(format: "%.0f%@", maxV, suffix))
        }
    }

    private func emptyStateView(message: String) -> some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
    }

    private func isWithinSelectedDay(_ date: Date) -> Bool {
        let candidate = mondayCalendar.startOfDay(for: date)
        return candidate >= selectedDayStart && candidate < selectedDayEnd
    }
}

#Preview {
    ReadingsGraphsView(ringSessionManager: RingSessionManager())
        .modelContainer(
            for: [
                StoredSleepDay.self,
                StoredSleepPeriod.self,
                StoredHeartRateLog.self,
                StoredActivitySample.self,
                StoredHRVSample.self,
                StoredBloodOxygenSample.self,
                StoredStressSample.self
            ],
            inMemory: true
        )
}
