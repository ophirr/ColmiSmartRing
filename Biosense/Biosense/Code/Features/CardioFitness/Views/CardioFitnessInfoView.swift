//
//  CardioFitnessInfoView.swift
//  Biosense
//
//  Modal explaining how the Cardio Fitness Trend feature works.
//

import SwiftUI

struct CardioFitnessInfoView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Hero
                    HStack {
                        Spacer()
                        Image(systemName: "heart.circle.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(.red)
                        Spacer()
                    }
                    .padding(.top, 8)

                    Text("Cardio Fitness Trend")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity, alignment: .center)

                    // What it is
                    infoSection(
                        title: "What is this?",
                        icon: "questionmark.circle",
                        text: "Cardio Fitness Trend tracks changes in your cardiovascular fitness over time. It shows whether your fitness is improving, stable, or declining — without claiming a specific number."
                    )

                    // How it works
                    infoSection(
                        title: "How it works",
                        icon: "gearshape.2",
                        text: "Your trend is estimated from two signals:"
                    )

                    VStack(alignment: .leading, spacing: 12) {
                        signalRow(
                            icon: "moon.zzz.fill",
                            color: .indigo,
                            title: "Resting Heart Rate",
                            detail: "Measured during sleep using your ring's PPG sensor. A lower resting heart rate generally indicates better cardiovascular fitness. We compute the 5th percentile of your sleeping HR over the past 7 nights."
                        )

                        signalRow(
                            icon: "arrow.down.heart.fill",
                            color: .red,
                            title: "Heart Rate Recovery",
                            detail: "After you stop a workout, your heart rate is recorded for 3 minutes. Faster recovery (a bigger drop in the first 60 seconds) correlates with better fitness. This is captured automatically when you use the Gym feature."
                        )
                    }
                    .padding(.leading, 4)

                    // What the arrows mean
                    infoSection(
                        title: "Reading the trend",
                        icon: "chart.line.uptrend.xyaxis",
                        text: "The trend compares your current week's estimate against the previous week:"
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        trendRow(icon: "arrow.up.right", color: .green, label: "Improving", detail: "Your fitness is trending upward")
                        trendRow(icon: "minus", color: .gray, label: "Stable", detail: "No significant change")
                        trendRow(icon: "arrow.down.right", color: .orange, label: "Declining", detail: "Your fitness is trending downward")
                    }
                    .padding(.leading, 4)

                    // Accuracy note
                    infoSection(
                        title: "Good to know",
                        icon: "exclamationmark.triangle",
                        text: "This is a fitness trend indicator, not a clinical measurement. It's most useful for tracking your personal progress over weeks and months. Factors like medication, caffeine, sleep quality, and hydration can affect your resting heart rate day-to-day — the 7-day average smooths out these variations."
                    )

                    // Getting started
                    infoSection(
                        title: "Getting started",
                        icon: "checkmark.circle",
                        text: "To see your trend, you need:\n\n1. Your profile set up (age is required)\n2. At least 3 nights of sleep data with heart rate\n3. For best results, use the Gym feature so recovery data can refine your estimate"
                    )
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func infoSection(title: String, icon: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.headline)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func signalRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func trendRow(icon: String, color: Color, label: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 24)
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 80, alignment: .leading)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
