//
//  ReadingsGraphsView.swift
//  Biosense
//
//  Graphs tab: sleep, heart rate, activity, HRV, blood oxygen, stress.
//

import SwiftUI
import SwiftData
import Charts

struct ReadingsGraphsView: View {
    @Bindable var ringSessionManager: RingSessionManager
    private let includeActivitySection: Bool
    @Query(sort: \StoredSleepDay.syncDate, order: .reverse) private var storedSleepDays: [StoredSleepDay]
    @Query(sort: \StoredHeartRateLog.timestamp, order: .reverse) private var storedHeartRateLogs: [StoredHeartRateLog]
    @Query(sort: \StoredActivitySample.timestamp, order: .reverse) private var storedActivitySamples: [StoredActivitySample]
    @Query(sort: \StoredHRVSample.timestamp, order: .reverse) private var storedHRVSamples: [StoredHRVSample]
    @Query(sort: \StoredBloodOxygenSample.timestamp, order: .reverse) private var storedBloodOxygenSamples: [StoredBloodOxygenSample]
    @Query(sort: \StoredStressSample.timestamp, order: .reverse) private var storedStressSamples: [StoredStressSample]

    @State private var selectedTimeRange: TimeRange = .day
    @State private var selectedWeekOffset: Int = 0
    @State private var selectedMonthOffset: Int = 0
    @State private var selectedDate: Date = Date()
    @State private var visibleWeekOffset: Int?

    /// For sub-day ranges (1H/6H/12H): offset in number-of-windows from now.
    /// 0 = most recent window ending at now, 1 = one window back, etc.
    @State private var selectedSubDayOffset: Int = 0

    private let maxPastWeeks = 104

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

    // MARK: - Sub-day range (1H / 6H / 12H)

    /// End of the sub-day window.
    /// Offset 0: end = now (trailing window shows most recent data).
    /// Offset ≥ 1: snapped to clean hour-aligned boundaries stepping back from now.
    private var subDayRangeEnd: Date {
        let cal = mondayCalendar
        let now = Date()
        let duration = selectedTimeRange.durationSeconds
        let blockHours = Int(duration / 3600)  // 1, 6, or 12

        if selectedSubDayOffset == 0 {
            return now
        }

        // Snap "now" down to the current block boundary to create a clean anchor.
        // e.g. at 16:20 with 1H blocks → anchor = 16:00; with 6H → anchor = 12:00
        let hour = cal.component(.hour, from: now)
        let blockStart = (hour / blockHours) * blockHours
        let comps = cal.dateComponents([.year, .month, .day], from: now)
        let dayStart = cal.date(from: comps) ?? now
        let anchor = dayStart.addingTimeInterval(TimeInterval(blockStart) * 3600)

        // offset 1 = the block ending at anchor, offset 2 = one before that, etc.
        return anchor.addingTimeInterval(-Double(selectedSubDayOffset - 1) * duration)
    }

    /// Start of the sub-day window.
    private var subDayRangeStart: Date {
        subDayRangeEnd.addingTimeInterval(-selectedTimeRange.durationSeconds)
    }

    /// Label for the sub-day navigation row.
    /// Always includes the date so context is clear when navigating into the past.
    /// Offset 0 shows "Now" label; historical offsets show clean hour ranges.
    private var subDayLabel: String {
        let start = subDayRangeStart
        let end = subDayRangeEnd
        let dateFmt = Date.FormatStyle().month(.abbreviated).day()
        let startDay = mondayCalendar.startOfDay(for: start)
        let endDay = mondayCalendar.startOfDay(for: end)

        if selectedSubDayOffset == 0 {
            // Trailing window: show "Mar 19, 3:20 PM – Now"
            let timeFmt = Date.FormatStyle().hour().minute()
            return "\(start.formatted(dateFmt)), \(start.formatted(timeFmt)) – Now"
        }

        // Historical: clean hour boundaries
        let timeFmt = Date.FormatStyle().hour()
        if startDay == endDay {
            return "\(start.formatted(dateFmt)), \(start.formatted(timeFmt)) – \(end.formatted(timeFmt))"
        } else {
            let dayTimeFmt = Date.FormatStyle().month(.abbreviated).day().hour()
            return "\(start.formatted(dayTimeFmt)) – \(end.formatted(dayTimeFmt))"
        }
    }

    // MARK: - Multi-day range (week / month)

    private func monthStart(for offset: Int) -> Date {
        let comps = mondayCalendar.dateComponents([.year, .month], from: Date())
        let thisMonthStart = mondayCalendar.date(from: comps) ?? Date()
        return mondayCalendar.date(byAdding: .month, value: -offset, to: thisMonthStart) ?? thisMonthStart
    }

    private var selectedRangeStart: Date {
        switch selectedTimeRange {
        case .hour1, .hour6, .hour12:
            return subDayRangeStart
        case .day:   return selectedDayStart
        case .week:  return weekStart(for: selectedWeekOffset)
        case .month: return monthStart(for: selectedMonthOffset)
        }
    }

    private var selectedRangeEnd: Date {
        switch selectedTimeRange {
        case .hour1, .hour6, .hour12:
            return subDayRangeEnd
        case .day:   return selectedDayEnd
        case .week:
            return mondayCalendar.date(byAdding: .day, value: 7, to: weekStart(for: selectedWeekOffset)) ?? selectedDayEnd
        case .month:
            return mondayCalendar.date(byAdding: .month, value: 1, to: monthStart(for: selectedMonthOffset)) ?? selectedDayEnd
        }
    }

    /// X-axis domain for charts. nil for day mode (automatic scaling), explicit for everything else.
    private var chartXDomain: ClosedRange<Date>? {
        switch selectedTimeRange {
        case .hour1, .hour6, .hour12:
            return subDayRangeStart...subDayRangeEnd
        case .day:
            return nil
        case .week, .month:
            return selectedRangeStart...selectedRangeEnd
        }
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

    // MARK: - Range-filtered data (all ranges)

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
    private var rangeBloodOxygenDaily: [TimeSeriesPoint] {
        dailyAverage(rangeBloodOxygenSamples.map { TimeSeriesPoint(time: $0.timestamp, value: $0.value) })
    }

    // MARK: - Derived autonomic metrics

    /// Get locally-rotated HR log with artifact rejection.
    /// Sleep HR is bimodal: real readings at 50-60 + motion artifact tail at 80-170.
    /// Median is robust to outliers, so cap at median + 10 bpm.
    private func cleanedHR(from log: StoredHeartRateLog) -> [Int] {
        let localLog = log.toHeartRateLog()
        let rangeMin = max(localLog.range, 1)
        let slotsPerHour = 60 / rangeMin
        let nightEnd = 6 * slotsPerHour

        let nightValid = localLog.heartRates.prefix(nightEnd).filter { $0 > 0 }.sorted()
        let nightCap: Int
        if nightValid.count >= 5 {
            nightCap = nightValid[nightValid.count / 2] + 10
        } else {
            nightCap = 70
        }

        return localLog.heartRates.enumerated().map { idx, bpm in
            guard bpm > 0 else { return 0 }
            if idx < nightEnd && bpm > nightCap { return 0 }
            if bpm > 100 { return 0 }
            return bpm
        }
    }

    private func computeNightDipRatio(from logs: [StoredHeartRateLog]) -> [TimeSeriesPoint] {
        logs.compactMap { log -> TimeSeriesPoint? in
                let hrs = cleanedHR(from: log)
                let range = max(log.range, 1)
                let slotsPerHour = 60 / range
                // Night: slots covering 0:00-6:00 local
                let nightSlots = Array(hrs.prefix(6 * slotsPerHour))
                // Day: slots covering 9:00-17:00 local
                let dayStart = 9 * slotsPerHour
                let dayEnd = min(17 * slotsPerHour, hrs.count)
                let daySlots = dayStart < dayEnd ? Array(hrs[dayStart..<dayEnd]) : []

                let nightValid = nightSlots.filter { $0 > 0 }
                let dayValid = daySlots.filter { $0 > 0 }
                // Require at least 5 night and 5 day readings. The ring's internal
                // HR log records every 5-30 min — even 6-10 readings across a sleep
                // period are representative. These are averaged values, not noisy
                // real-time samples.
                guard nightValid.count >= 5, dayValid.count >= 5 else { return nil }

                let nightAvg = Double(nightValid.reduce(0, +)) / Double(nightValid.count)
                let dayAvg = Double(dayValid.reduce(0, +)) / Double(dayValid.count)
                guard dayAvg > 0 else { return nil }
                return TimeSeriesPoint(time: log.dayStart, value: nightAvg / dayAvg)
            }
            .sorted { $0.time < $1.time }
    }

    private var nightDipRatioDaily: [TimeSeriesPoint] {
        computeNightDipRatio(from: storedHeartRateLogs.filter { $0.dayStart >= selectedRangeStart && $0.dayStart < selectedRangeEnd })
    }

    private var nightDipRatioAll: [TimeSeriesPoint] {
        computeNightDipRatio(from: Array(storedHeartRateLogs))
    }

    private func computeSDHR(from logs: [StoredHeartRateLog]) -> [TimeSeriesPoint] {
        logs.compactMap { log -> TimeSeriesPoint? in
                let hrs = cleanedHR(from: log)
                let rangeMin = max(log.range, 1)
                let slotsPerHour = 60 / rangeMin
                // Only sleep hours (0:00-6:00 local)
                let nightSlots = Array(hrs.prefix(6 * slotsPerHour))
                let valid = nightSlots.filter { $0 > 0 }.map(Double.init)
                guard valid.count >= 5 else { return nil }
                let mean = valid.reduce(0, +) / Double(valid.count)
                let variance = valid.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(valid.count)
                return TimeSeriesPoint(time: log.dayStart, value: variance.squareRoot())
            }
            .sorted { $0.time < $1.time }
    }

    private var sdhrDaily: [TimeSeriesPoint] {
        computeSDHR(from: storedHeartRateLogs.filter { $0.dayStart >= selectedRangeStart && $0.dayStart < selectedRangeEnd })
    }

    private var sdhrAll: [TimeSeriesPoint] {
        computeSDHR(from: Array(storedHeartRateLogs))
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

    // MARK: - Day-specific data (used for sub-day and day ranges)

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

    // MARK: - Sub-day & day range data accessors

    /// Activity data for sub-day ranges: filter the range-filtered samples.
    private var subDayActivityStepsData: [TimeSeriesPoint] {
        rangeActivitySamples.map { TimeSeriesPoint(time: $0.timestamp, value: Double($0.steps)) }
    }

    private var subDayActivityDistanceData: [TimeSeriesPoint] {
        rangeActivitySamples.map { TimeSeriesPoint(time: $0.timestamp, value: $0.distanceKm) }
    }

    private var subDayActivityCaloriesData: [TimeSeriesPoint] {
        rangeActivitySamples.map { TimeSeriesPoint(time: $0.timestamp, value: Double($0.calories)) }
    }

    private var subDayHRVData: [TimeSeriesPoint] {
        let now = Date()
        return rangeHRVSamples
            .filter { $0.timestamp <= now }
            .map { TimeSeriesPoint(time: $0.timestamp, value: $0.value) }
    }

    private var subDayBloodOxygenData: [TimeSeriesPoint] {
        let now = Date()
        return rangeBloodOxygenSamples
            .filter { $0.timestamp <= now }
            .map { TimeSeriesPoint(time: $0.timestamp, value: $0.value) }
    }

    private var subDayStressData: [TimeSeriesPoint] {
        let now = Date()
        return rangeStressSamples
            .filter { $0.timestamp <= now }
            .map { TimeSeriesPoint(time: $0.timestamp, value: $0.value) }
    }

    /// Heart rate points for sub-day ranges: extract from day HR logs that overlap the window.
    /// When the window spans midnight we need logs from both days.
    private var subDayHeartRatePoints: [HeartRateDataPoint] {
        return subDayHeartRateLogs.flatMap { log in
            log.toHeartRateLog().heartRatesWithTimes()
                .map { HeartRateDataPoint(heartRate: $0.0, time: $0.1) }
        }
        .filter { $0.time >= subDayRangeStart && $0.time < subDayRangeEnd }
        .sorted { $0.time < $1.time }
    }

    /// For sub-day HR: find HR logs whose day overlaps the sub-day window.
    /// A 12H or 6H window can span midnight, so we may need logs from two adjacent days.
    private var subDayHeartRateLogs: [StoredHeartRateLog] {
        let windowStartDay = mondayCalendar.startOfDay(for: subDayRangeStart)
        let windowEndDay = mondayCalendar.startOfDay(for: subDayRangeEnd)
        // Collect all days that intersect the window
        var days: Set<Date> = [windowStartDay]
        if windowEndDay != windowStartDay {
            days.insert(windowEndDay)
        }
        return days.compactMap { dayStart in
            let dayEnd = mondayCalendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
            return storedHeartRateLogs.first { $0.dayStart >= dayStart && $0.dayStart < dayEnd }
        }
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
                autonomicSection
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
                selectedSubDayOffset = 0
                visibleWeekOffset = 0
            }
        }
    }

    // MARK: - Time range picker

    private var timeRangePickerSection: some View {
        Section {
            VStack(spacing: 8) {
                // Sub-day pills row (smaller)
                HStack(spacing: 6) {
                    ForEach([TimeRange.hour1, .hour6, .hour12], id: \.self) { range in
                        Button {
                            selectedTimeRange = range
                        } label: {
                            Text(range.displayName)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity)
                                .background(selectedTimeRange == range ? Color.purple : Color(.tertiarySystemGroupedBackground))
                                .foregroundStyle(selectedTimeRange == range ? .white : .primary)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Standard range picker (Day / Week / Month)
                Picker("Time Range", selection: $selectedTimeRange) {
                    ForEach([TimeRange.day, .week, .month], id: \.self) { range in
                        Text(range.displayName).tag(range)
                    }
                }
                .pickerStyle(.segmented)
            }

            switch selectedTimeRange {
            case .hour1, .hour6, .hour12:
                subDayNavigationRow
            case .day:
                dayPickerInline
            case .week:
                weekNavigationRow
            case .month:
                monthNavigationRow
            }
        }
    }

    // MARK: - Sub-day navigation

    private var subDayNavigationRow: some View {
        HStack {
            Button { selectedSubDayOffset += 1 } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            Spacer()
            Text(subDayLabel)
                .font(.subheadline.weight(.medium))
            Spacer()
            Button { selectedSubDayOffset -= 1 } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(selectedSubDayOffset <= 0)
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 4)
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
            case .hour1, .hour6, .hour12:
                // Sleep doesn't make sense at sub-day granularity; show day-level data
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
                        ActivityBarChartView(
                            data: rangeSleepDurationDaily,
                            title: "Sleep (hours)",
                            color: .indigo,
                            yLabel: "Hours",
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
        case .hour1, .hour6, .hour12:
            if forward {
                guard selectedSubDayOffset > 0 else { return }
                selectedSubDayOffset -= 1
            } else {
                selectedSubDayOffset += 1
            }
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
            case .hour1, .hour6, .hour12:
                if subDayHeartRatePoints.isEmpty {
                    emptyStateView(message: L10n.Graphs.noHeartRateData)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Heart rate")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        HeartRateGraphView(data: subDayHeartRatePoints, timeRange: selectedTimeRange, xDomain: chartXDomain)
                    }
                    .padding(.vertical, 8)
                }
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
        let interval = log.range > 0 ? log.range : 5
        return VStack(alignment: .leading, spacing: 8) {
            Text("Heart rate (\(interval)-min intervals)")
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
                case .hour1, .hour6, .hour12:
                    if subDayActivityStepsData.isEmpty {
                        Text(L10n.Graphs.sampleActivity)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        ActivityBarChartView(data: subDayActivityStepsData, title: "Steps", timeRange: selectedTimeRange, xDomain: chartXDomain)
                        ActivityBarChartView(data: subDayActivityDistanceData, title: "Distance", color: .green, yLabel: "Km", timeRange: selectedTimeRange, xDomain: chartXDomain)
                        ActivityCaloriesChartView(data: subDayActivityCaloriesData, timeRange: selectedTimeRange, xDomain: chartXDomain)
                    }
                case .day:
                    if activityStepsData.isEmpty || activityDistanceData.isEmpty || activityCaloriesData.isEmpty {
                        Text(L10n.Graphs.sampleActivity)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        ActivityBarChartView(data: activityStepsData, title: "Steps")
                        ActivityCumulativeComparisonChartView(
                            comparisonData: PreviewData.stepsPerHourWeeklyAverage,
                            data: activityStepsData,
                            title: "Steps (cumulative)", yLabel: "Steps"
                        )
                        ActivityBarChartView(data: activityDistanceData, title: "Distance", color: .green, yLabel: "Km")
                        ActivityCumulativeComparisonChartView(
                            comparisonData: PreviewData.distancePerHourWeeklyAverage,
                            data: activityDistanceData,
                            title: "Distance (cumulative)", color: .green, yLabel: "Km"
                        )
                        ActivityCaloriesChartView(data: activityCaloriesData)
                        ActivityCumulativeComparisonChartView(
                            comparisonData: PreviewData.caloriesPerHourWeeklyAverage,
                            data: activityCaloriesData,
                            title: "Calories (cumulative)", color: .red, yLabel: "Kcal"
                        )
                    }
                case .week, .month:
                    if rangeActivityStepsDaily.isEmpty {
                        Text(L10n.Graphs.sampleActivity)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        activitySummaryRow
                        ActivityBarChartView(data: rangeActivityStepsDaily, title: "Steps per day", timeRange: selectedTimeRange, xDomain: chartXDomain)
                        ActivityBarChartView(data: rangeActivityDistanceDaily, title: "Distance per day", color: .green, yLabel: "Km", timeRange: selectedTimeRange, xDomain: chartXDomain)
                        ActivityBarChartView(data: rangeActivityCaloriesDaily, title: "Calories per day", color: .red, yLabel: "Kcal", timeRange: selectedTimeRange, xDomain: chartXDomain)
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

    @State private var showingAutonomicInfo = false

    private var autonomicSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                // Night Dip Ratio — fall back to most recent available if today
                // doesn't have enough data yet (e.g., early morning before daytime HR).
                if !nightDipRatioDaily.isEmpty || !nightDipRatioAll.isEmpty {
                    nightDipRatioView
                } else {
                    Text("Sync HR data to see autonomic metrics.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                // SDHR — same fallback logic
                if !sdhrDaily.isEmpty || !sdhrAll.isEmpty {
                    Divider()
                    sdhrView
                }
            }
        } header: {
            HStack {
                Label("Autonomic Health", systemImage: "heart.text.clipboard")
                Spacer()
                Button { showingAutonomicInfo = true } label: {
                    Image(systemName: "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showingAutonomicInfo) {
            AutonomicHealthInfoView()
        }
    }

    /// Trend indicator: compares latest value to previous. Returns (icon, color, delta).
    /// When the visible data has only one point (day view), looks back at all stored
    /// logs to find the previous day's value for comparison.
    private func trend(data: [TimeSeriesPoint], allData: [TimeSeriesPoint]? = nil) -> (icon: String, color: Color, delta: Double)? {
        let latest: Double
        let previous: Double
        if data.count >= 2 {
            latest = data[data.count - 1].value
            previous = data[data.count - 2].value
        } else if data.count == 1, let all = allData, all.count >= 2 {
            // Day view: only one point in range, use full dataset for previous
            latest = data[0].value
            let sorted = all.sorted { $0.time < $1.time }
            if let idx = sorted.lastIndex(where: { $0.time < data[0].time }) {
                previous = sorted[idx].value
            } else {
                return nil
            }
        } else {
            return nil
        }
        let delta = latest - previous
        if abs(delta) < 0.001 { return ("minus", .gray, 0) }
        return delta > 0
            ? ("arrow.up.right", .green, delta)
            : ("arrow.down.right", .orange, delta)
    }

    private var nightDipRatioView: some View {
        let data = nightDipRatioDaily.isEmpty ? nightDipRatioAll : nightDipRatioDaily
        let latest = data.last?.value ?? 0
        let avg = data.isEmpty ? 0 : data.map(\.value).reduce(0, +) / Double(data.count)
        let assessment: String
        let color: Color
        if avg < 0.80 { assessment = "Extreme dipper"; color = .blue }
        else if avg < 0.90 { assessment = "Normal dipper"; color = .green }
        else if avg < 1.00 { assessment = "Non-dipper"; color = .orange }
        else { assessment = "Reverse dipper"; color = .red }
        // For night dip, lower is better (stronger dip), so invert arrow meaning
        let dipTrend = trend(data: data, allData: nightDipRatioAll)
        let trendIcon = dipTrend.map { $0.delta < 0 ? "arrow.down.right" : "arrow.up.right" }
        let trendColor: Color? = dipTrend.map { $0.delta < 0 ? .green : .orange }

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Night Dip Ratio")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let icon = trendIcon, let tc = trendColor, let t = dipTrend {
                    Image(systemName: icon)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tc)
                    Text(String(format: "%+.3f", t.delta))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(tc)
                }
                Text(String(format: "%.3f", latest))
                    .font(.title2.weight(.bold).monospacedDigit())
            }
            HStack(spacing: 12) {
                Text(assessment)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                Text("Avg: \(String(format: "%.3f", avg))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Sleep HR ÷ Day HR")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if data.count > 1 {
                Chart(data, id: \.time) { point in
                    LineMark(x: .value("Date", point.time), y: .value("Ratio", point.value))
                        .foregroundStyle(.green.gradient)
                        .interpolationMethod(.catmullRom)
                    PointMark(x: .value("Date", point.time), y: .value("Ratio", point.value))
                        .foregroundStyle(point.value < 0.90 ? .green : .orange)
                        .symbolSize(20)
                }
                .chartYScale(domain: max(0.6, (data.map(\.value).min() ?? 0.7) - 0.05)...1.1)
                .padding(.top, 4)
                .chartYAxis {
                    AxisMarks(values: [0.8, 0.9, 1.0]) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(String(format: "%.1f", v))
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .frame(height: 120)
            }
        }
    }

    private var sdhrView: some View {
        let data = sdhrDaily.isEmpty ? sdhrAll : sdhrDaily
        let latest = data.last?.value ?? 0
        let avg = data.isEmpty ? 0 : data.map(\.value).reduce(0, +) / Double(data.count)
        // Higher SDHR = better autonomic flexibility
        let sdhrTrend = trend(data: data, allData: sdhrAll)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("HR Variability (SDHR)")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let t = sdhrTrend {
                    Image(systemName: t.icon)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(t.color)
                    Text(String(format: "%+.1f", t.delta))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(t.color)
                }
                Text(String(format: "%.1f", latest))
                    .font(.title2.weight(.bold).monospacedDigit())
                Text("bpm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text("Avg: \(String(format: "%.1f", avg)) bpm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Sleep HR variability")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if data.count > 1 {
                Chart(data, id: \.time) { point in
                    BarMark(x: .value("Date", point.time, unit: .day), y: .value("SDHR", point.value))
                        .foregroundStyle(.purple.gradient)
                }
                .frame(height: 120)
            }
        }
    }

    // MARK: - Blood oxygen

    private var bloodOxygenSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                switch selectedTimeRange {
                case .hour1, .hour6, .hour12:
                    if subDayBloodOxygenData.isEmpty {
                        Text(L10n.Graphs.sampleBloodOxygen)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        BloodOxygenChartView(data: subDayBloodOxygenData, timeRange: selectedTimeRange, xDomain: chartXDomain)
                    }
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

    // MARK: - (Stress section removed — replaced by derived autonomic metrics)

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
