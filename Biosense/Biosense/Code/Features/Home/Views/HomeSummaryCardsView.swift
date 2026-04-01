//
//  HomeSummaryCardsView.swift
//  Biosense
//
//  Summary cards for activity and metrics on the home screen.
//

import SwiftUI
import SwiftData

struct HomeSummaryCardsView: View {
    /// Last night's sleep duration in minutes (nil if no data).
    var sleepDurationMinutes: Int?
    /// Today's average heart rate in bpm (nil if no data).
    var heartRateAverage: Int?
    /// Live heart rate from real-time stream (nil when not streaming).
    var currentBPM: Int?
    /// Whether continuous HR streaming is active (controls card appearance).
    var isStreaming: Bool = false
    /// Called when the user taps the heart rate card.
    var onHeartRateTap: (() -> Void)?
    /// Activity: steps, distance km, calories. Uses PreviewData when real data not yet available.
    var steps: Int
    var distanceKm: Double
    var calories: Int
    var activityLabel: String
    /// Running steps from CMD 0x48 (separate from walking steps in 0x43).
    var runningSteps: Int = 0
    /// Number of completed gym workouts today (0 = no workouts).
    var gymWorkoutCount: Int = 0
    /// Total gym workout duration today in minutes.
    var gymDurationMinutes: Int = 0
    /// Latest SpO2 reading (nil if no data).
    var spo2Percent: Int?
    /// Latest temperature reading in Celsius (nil if no data).
    var temperatureCelsius: Double?
    /// Latest glucose reading in mg/dL (nil if no data).
    var glucoseMgdl: Double?
    /// Cardio fitness trend (nil if insufficient data).
    var cardioFitnessTrend: CardioFitnessTrend?
    /// Number of days of CRF data available.
    var cardioFitnessDataPoints: Int = 0

    var body: some View {
        VStack(spacing: 12) {
            activityCard
            HStack(spacing: 12) {
                sleepCard
                heartRateCard
            }
            HStack(spacing: 12) {
                spo2Card
                temperatureCard
            }
            HStack(spacing: 12) {
                CardioFitnessCardView(
                    trend: cardioFitnessTrend,
                    dataPointCount: cardioFitnessDataPoints
                )
                if glucoseMgdl != nil {
                    glucoseCard
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.HomeSummary.activity, systemImage: "figure.walk")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 24) {
                metricCell(value: "\(steps)", unit: L10n.HomeSummary.steps, color: .cyan)
                metricCell(value: String(format: "%.2f", distanceKm), unit: "km", color: .green)
                metricCell(value: "\(calories)", unit: L10n.HomeSummary.calories, color: .red)
            }
            .frame(maxWidth: .infinity)
            if runningSteps > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "figure.run")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("\(runningSteps) running steps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            if gymWorkoutCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text(gymWorkoutCount == 1
                         ? "\(gymDurationMinutes) min workout"
                         : "\(gymWorkoutCount) workouts · \(gymDurationMinutes) min")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else if !activityLabel.isEmpty {
                Text(activityLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .biosenseCardStyle()
    }

    private var sleepCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L10n.HomeSummary.sleep, systemImage: "bed.double.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if let total = sleepDurationMinutes {
                let h = total / 60
                let m = total % 60
                Text("\(h) h \(m) min")
                    .font(.title2.weight(.semibold))
                Text(L10n.HomeSummary.lastNight)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text(L10n.HomeSummary.noData)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
        .biosenseCardStyle()
    }

    private var heartRateCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(L10n.HomeSummary.heartRate, systemImage: "heart.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if isStreaming {
                    Image(systemName: "waveform.path")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .symbolEffect(.variableColor.iterative, isActive: true)
                }
            }
            if let bpm = currentBPM, bpm > 0 {
                Text("\(bpm) \(L10n.HomeSummary.bpm)")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.red)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.3), value: bpm)
                Text("now")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if isStreaming {
                ProgressView()
                    .controlSize(.small)
                Text("measuring...")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if let avg = heartRateAverage {
                Text("\(avg) \(L10n.HomeSummary.bpm)")
                    .font(.title2.weight(.semibold))
                Text("avg today")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text(L10n.HomeSummary.noData)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
        .biosenseCardStyle()
        .onTapGesture { onHeartRateTap?() }
    }

    private var spo2Card: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("SpO2", systemImage: "lungs.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if let spo2 = spo2Percent {
                Text("\(spo2)%")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.cyan)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.3), value: spo2)
                Text("latest")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text(L10n.HomeSummary.noData)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
        .biosenseCardStyle()
    }

    private var temperatureCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Temp", systemImage: "thermometer.medium")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if let celsius = temperatureCelsius {
                Text(String(format: "%.1f°", celsius))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.3), value: celsius)
                Text("latest")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text(L10n.HomeSummary.noData)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
        .biosenseCardStyle()
    }

    private var glucoseCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Glucose", systemImage: "drop.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if let glucose = glucoseMgdl {
                Text("\(Int(glucose)) mg/dL")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(glucoseColor(glucose))
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.3), value: glucose)
                Text(glucoseLabel(glucose))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text(L10n.HomeSummary.noData)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
        .biosenseCardStyle()
    }

    private func glucoseColor(_ value: Double) -> Color {
        switch value {
        case ..<70:  return .red
        case 70..<100: return .green
        case 100..<180: return .yellow
        default: return .red
        }
    }

    private func glucoseLabel(_ value: Double) -> String {
        switch value {
        case ..<70:  return "low"
        case 70..<100: return "normal"
        case 100..<180: return "elevated"
        default: return "high"
        }
    }

    private func metricCell(value: String, unit: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: value.count >= 5 ? 28 : value.count >= 4 ? 34 : 40,
                              weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(unit)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Default data (PreviewData-backed)

extension HomeSummaryCardsView {
    /// Uses PreviewData for activity; pass sleep and HR from SwiftData when available.
    static func withPreviewActivity(
        sleepDurationMinutes: Int? = nil,
        heartRateAverage: Int? = nil,
        currentBPM: Int? = nil,
        spo2Percent: Int? = nil,
        temperatureCelsius: Double? = nil,
        glucoseMgdl: Double? = nil
    ) -> HomeSummaryCardsView {
        let activity = PreviewData.activitySummary
        return HomeSummaryCardsView(
            sleepDurationMinutes: sleepDurationMinutes,
            heartRateAverage: heartRateAverage,
            currentBPM: currentBPM,
            steps: activity.steps,
            distanceKm: activity.distanceKm,
            calories: activity.calories,
            activityLabel: activity.label,
            spo2Percent: spo2Percent,
            temperatureCelsius: temperatureCelsius,
            glucoseMgdl: glucoseMgdl
        )
    }
}

#Preview {
    List {
        Section(L10n.HomeSummary.sectionTitle) {
            HomeSummaryCardsView.withPreviewActivity(
                sleepDurationMinutes: 447,
                heartRateAverage: 76
            )
        }
    }
    .listStyle(.insetGrouped)
    .modelContainer(for: [StoredSleepDay.self, StoredHeartRateLog.self, StoredGlucoseSample.self, StoredPhoneStepSample.self], inMemory: true)
}
