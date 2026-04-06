import SwiftUI
import SwiftData
import SleepChartKit

struct HomeScreenView: View {
    @Bindable var ringSessionManager: RingSessionManager
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \StoredSleepDay.syncDate, order: .reverse) private var storedSleepDays: [StoredSleepDay]
    @Query(sort: \StoredHeartRateLog.timestamp, order: .reverse) private var storedHeartRateLogs: [StoredHeartRateLog]
    @Query(sort: \StoredActivitySample.timestamp, order: .reverse) private var storedActivitySamples: [StoredActivitySample]
    @Query(sort: \StoredGymSession.startTime, order: .reverse) private var storedGymSessions: [StoredGymSession]
    @Query(sort: \StoredGlucoseSample.timestamp, order: .reverse) private var storedGlucoseSamples: [StoredGlucoseSample]
    @Query(sort: \StoredPhoneStepSample.timestamp, order: .reverse) private var storedPhoneStepSamples: [StoredPhoneStepSample]
    @Query(sort: \StoredCRFEstimate.date, order: .reverse) private var storedCRFEstimates: [StoredCRFEstimate]

    private var latestSleepDurationMinutes: Int? {
        // Skip naps — show the most recent overnight sleep
        storedSleepDays
            .first { !$0.toSleepDay().isNap }
            .map { $0.toSleepDay().totalDurationMinutes }
    }

    private var todayHeartRateAverage: Int? {
        guard let log = storedHeartRateLogs.first else { return nil }
        let withTimes = log.toHeartRateLog().heartRatesWithTimes()
        let valid = withTimes.map(\.0).filter { $0 > 0 }
        guard !valid.isEmpty else { return nil }
        return valid.reduce(0, +) / valid.count
    }

    /// Latest glucose reading within the last 4 hours (nil if no recent data).
    private var latestGlucose: Double? {
        storedGlucoseSamples.first(where: {
            Date().timeIntervalSince($0.timestamp) < 4 * 3600
        })?.valueMgdl
    }

    private var latestActivity: (steps: Int, distanceKm: Double, calories: Int, label: String)? {
        let calendar = Calendar.current
        let todayRingSamples = storedActivitySamples.filter { calendar.isDateInToday($0.timestamp) }
        let todayPhoneSamples = storedPhoneStepSamples.filter { calendar.isDateInToday($0.timestamp) }
        let todayGymSessions = storedGymSessions.filter { calendar.isDateInToday($0.startTime) }
        guard !todayRingSamples.isEmpty || !todayPhoneSamples.isEmpty || !todayGymSessions.isEmpty else { return nil }

        // Merge activity: take the higher value per hourly bucket (ring vs phone) for each metric
        let ringByHour = Dictionary(grouping: todayRingSamples) { calendar.component(.hour, from: $0.timestamp) }
        let phoneByHour = Dictionary(grouping: todayPhoneSamples) { calendar.component(.hour, from: $0.timestamp) }
        let allHours = Set(ringByHour.keys).union(phoneByHour.keys)
        var totalSteps = 0
        var totalDistanceKm = 0.0
        var totalCalories = 0
        for hour in allHours {
            let ringSteps = ringByHour[hour]?.reduce(0) { $0 + $1.steps } ?? 0
            let phoneSteps = phoneByHour[hour]?.reduce(0) { $0 + $1.steps } ?? 0
            totalSteps += max(ringSteps, phoneSteps)

            let ringDist = ringByHour[hour]?.reduce(0.0) { $0 + $1.distanceKm } ?? 0
            let phoneDist = phoneByHour[hour]?.reduce(0.0) { $0 + $1.distanceKm } ?? 0
            totalDistanceKm += max(ringDist, phoneDist)

            let ringCal = ringByHour[hour]?.reduce(0) { $0 + $1.calories } ?? 0
            let phoneCal = phoneByHour[hour]?.reduce(0) { $0 + $1.calories } ?? 0
            totalCalories += max(ringCal, phoneCal)
        }

        let gymCalories = todayGymSessions.reduce(0) { $0 + $1.estimatedCalories }
        totalCalories += gymCalories
        return (totalSteps, totalDistanceKm, totalCalories, "")
    }

    /// Number of completed gym workouts today (for the activity card badge).
    private var todayGymWorkoutCount: Int {
        storedGymSessions.filter { Calendar.current.isDateInToday($0.startTime) }.count
    }

    /// Total gym workout duration today in minutes.
    private var todayGymDurationMinutes: Int {
        let todaySessions = storedGymSessions.filter { Calendar.current.isDateInToday($0.startTime) }
        return Int(todaySessions.reduce(0.0) { $0 + $1.durationSeconds } / 60.0)
    }

    /// Current cardio fitness trend from stored estimates.
    private var cardioFitnessTrend: CardioFitnessTrend? {
        guard let latest = storedCRFEstimates.first, latest.confidence >= 1 else { return nil }
        let calendar = Calendar.current
        let now = Date()
        // Get estimates from 7-14 days ago
        let previousWeek = storedCRFEstimates.filter { est in
            guard let daysAgo = calendar.dateComponents([.day], from: est.date, to: now).day else { return false }
            return daysAgo >= 7 && daysAgo < 14 && est.confidence >= 1
        }
        guard !previousWeek.isEmpty else { return .insufficientData }
        let previousAvg = previousWeek.reduce(0.0) { $0 + $1.vo2maxEstimate } / Double(previousWeek.count)
        let delta = latest.vo2maxEstimate - previousAvg
        if delta > 1.0 { return .improving }
        if delta < -1.0 { return .declining }
        return .stable
    }

    private var cardioFitnessDataPoints: Int {
        storedCRFEstimates.filter { $0.confidence >= 1 }.count
    }

    private var todaySleepRecord: StoredSleepDay? {
        // Show last night's sleep — the most recent overnight (non-nap) record.
        // nightDate is the evening sleep started, typically yesterday relative to
        // when the user opens the app in the morning. Match the summary card logic.
        storedSleepDays.first { !$0.toSleepDay().isNap }
    }

    private var todaySleepSamples: [SleepSample] {
        guard let record = todaySleepRecord else { return [] }
        return SleepChartKitAdapter.samples(from: record.toSleepDay(), nightDate: record.sleepDate)
    }

    private var todaySleepTotalMinutes: Int? {
        todaySleepRecord?.toSleepDay().totalDurationMinutes
    }

    var body: some View {
        NavigationStack {
            List {
                Section(L10n.HomeSummary.sectionTitle) {
                    HomeSummaryCardsView(
                        sleepDurationMinutes: latestSleepDurationMinutes,
                        heartRateAverage: todayHeartRateAverage,
                        currentBPM: ringSessionManager.realTimeHeartRateBPM,
                        isStreaming: ringSessionManager.isContinuousHRStreamActive,
                        onHeartRateTap: { ringSessionManager.toggleContinuousHRStream() },
                        steps: latestActivity?.steps ?? 0,
                        distanceKm: latestActivity?.distanceKm ?? 0,
                        calories: latestActivity?.calories ?? 0,
                        activityLabel: latestActivity?.label ?? "",
                        runningSteps: ringSessionManager.todayRunningSteps,
                        gymWorkoutCount: todayGymWorkoutCount,
                        gymDurationMinutes: todayGymDurationMinutes,
                        spo2Percent: ringSessionManager.realTimeBloodOxygenPercent,
                        temperatureCelsius: ringSessionManager.realTimeTemperatureCelsius,
                        glucoseMgdl: latestGlucose,
                        cardioFitnessTrend: cardioFitnessTrend,
                        cardioFitnessDataPoints: cardioFitnessDataPoints
                    )
                }
                Section(L10n.Sleep.sectionTitle) {
                    if todaySleepSamples.isEmpty {
                        Text(L10n.Graphs.noSleepData)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    } else {
                        VStack(spacing: 12) {
                            SleepCircularChartView(samples: todaySleepSamples)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 8)
                            homeSleepLegend
                        }
                        .padding(.bottom, 8)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.Tab.home)
            .navigationBarTitleDisplayMode(.large)
            .refreshable { await refreshHomeData() }
            .onAppear {
                if ringSessionManager.peripheralConnected {
                    ringSessionManager.syncActivityData(dayOffset: 0)
                    ringSessionManager.requestTodaySports()
                }
            }
        }
    }

    /// Pull-to-refresh: re-request today's data from ring + HealthKit.
    private func refreshHomeData() async {
        // Import from HealthKit in background (don't block the spinner)
        let ctx = modelContext
        Task {
            let importer = HealthKitImporter(modelContext: ctx)
            await importer.importAll()
        }

        guard ringSessionManager.peripheralConnected else {
            // Brief pause so the spinner doesn't flash and vanish instantly
            try? await Task.sleep(for: .seconds(1))
            return
        }
        ringSessionManager.getHeartRateLog(dayOffset: 0) { _ in }
        ringSessionManager.syncActivityData(dayOffset: 0)
        ringSessionManager.requestTodaySports()
        ringSessionManager.syncHRVData(dayOffset: 0)
        ringSessionManager.syncBloodOxygen(dayOffset: 0)
        ringSessionManager.syncPressureData(dayOffset: 0)
        // Give the ring time to respond before the spinner dismisses.
        try? await Task.sleep(for: .seconds(2))
    }

    private var homeSleepLegend: some View {
        let items: [(label: String, color: Color)] = [
            (L10n.SleepStageLabel.wakeUp, .orange),
            (L10n.SleepStageLabel.rem, .gray),
            (L10n.SleepStageLabel.lightSleep, Color.purple.opacity(0.6)),
            (L10n.SleepStageLabel.deepSleep, .purple)
        ]
        return VStack(alignment: .leading, spacing: 8) {
            if let total = todaySleepTotalMinutes {
                HStack {
                    Text(L10n.SleepStage.totalDuration)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(L10n.SleepStage.durationHM(hours: total / 60, mins: total % 60))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                }
            }
            HStack(spacing: 12) {
                ForEach(items, id: \.label) { item in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(item.color)
                            .frame(width: 8, height: 8)
                        Text(item.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    HomeScreenView(ringSessionManager: RingSessionManager())
        .modelContainer(
            for: [
                StoredSleepDay.self,
                StoredSleepPeriod.self,
                StoredHeartRateLog.self,
                StoredActivitySample.self,
                StoredGymSession.self,
                GymHRSample.self,
                StoredGlucoseSample.self,
                StoredPhoneStepSample.self
            ],
            inMemory: true
        )
}
