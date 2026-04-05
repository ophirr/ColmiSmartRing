//
//  AutonomicHealthInfoView.swift
//  Biosense
//
//  Modal explaining how the derived autonomic health metrics work.
//

import SwiftUI

struct AutonomicHealthInfoView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Hero
                    HStack {
                        Spacer()
                        Image(systemName: "heart.text.clipboard")
                            .font(.system(size: 60))
                            .foregroundStyle(.green)
                        Spacer()
                    }
                    .padding(.top, 8)

                    Text("Autonomic Health")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity, alignment: .center)

                    infoSection(
                        title: "What is this?",
                        icon: "questionmark.circle",
                        text: "These metrics measure how well your autonomic nervous system regulates your heart rate across sleep and waking hours. They replace the ring's built-in HRV and stress values, which lack the resolution for meaningful trend analysis."
                    )

                    // Night Dip Ratio
                    infoSection(
                        title: "Night Dip Ratio",
                        icon: "moon.zzz.fill",
                        text: "The ratio of your average sleeping heart rate (12 AM – 6 AM) to your average daytime heart rate (9 AM – 5 PM)."
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        rangeRow(range: "< 0.80", color: .blue, label: "Extreme dipper", detail: "Very strong parasympathetic tone during sleep. Common in highly fit individuals.")
                        rangeRow(range: "0.80 – 0.90", color: .green, label: "Normal dipper", detail: "Healthy autonomic function. Your nervous system properly shifts into rest mode at night.")
                        rangeRow(range: "0.90 – 1.00", color: .orange, label: "Non-dipper", detail: "Blunted nighttime HR drop. Can be associated with cardiovascular risk, poor sleep quality, or stress.")
                        rangeRow(range: "> 1.00", color: .red, label: "Reverse dipper", detail: "Night HR exceeds day HR. Uncommon — may indicate sleep-disordered breathing or autonomic dysfunction.")
                    }
                    .padding(.leading, 4)

                    // SDHR
                    infoSection(
                        title: "HR Variability (SDHR)",
                        icon: "waveform.path.ecg",
                        text: "The standard deviation of your heart rate readings across each day. This is a proxy for heart rate variability (HRV) — it captures how much your heart rate naturally fluctuates in response to activity, rest, and stress."
                    )

                    VStack(alignment: .leading, spacing: 12) {
                        signalRow(
                            icon: "arrow.up.right.circle.fill",
                            color: .purple,
                            title: "Higher SDHR",
                            detail: "More autonomic flexibility. Your heart rate responds dynamically to demands — a sign of good cardiovascular fitness and recovery."
                        )
                        signalRow(
                            icon: "arrow.down.right.circle.fill",
                            color: .orange,
                            title: "Lower SDHR",
                            detail: "Less variability. Can indicate fatigue, overtraining, illness, or chronic stress. A sustained downward trend is worth paying attention to."
                        )
                    }
                    .padding(.leading, 4)

                    // How it works
                    infoSection(
                        title: "How these are computed",
                        icon: "gearshape.2",
                        text: "Both metrics are derived from your ring's heart rate log, which records a reading every 5 minutes throughout the day. A Kalman filter first removes motion artifacts (false high readings when the ring shifts on your finger), then the cleaned data is used to compute the daily metrics.\n\nNo additional sensors or ring queries are needed — these are computed entirely from data already on your phone."
                    )

                    // Why not ring HRV
                    infoSection(
                        title: "Why not the ring's HRV?",
                        icon: "exclamationmark.triangle",
                        text: "True HRV (RMSSD, SDNN) requires millisecond-precision timing between individual heartbeats. The Colmi R02 reports only beats-per-minute, not beat-to-beat intervals. Its built-in HRV value is a heavily quantized estimate that shows almost no day-to-day variation.\n\nSDHR and Night Dip Ratio use the data the ring actually provides well — aggregate heart rate over time — to extract meaningful autonomic signals."
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

    private func rangeRow(range: String, color: Color, label: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(range)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
                .frame(width: 70, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
