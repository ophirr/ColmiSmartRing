//
//  GymSessionDetailView.swift
//  Biosense
//
//  Detailed post-workout view showing HR over time with zone coloring,
//  zone time breakdown, and summary statistics.
//

import SwiftUI
import Charts
import SwiftData

struct GymSessionDetailView: View {
    let session: StoredGymSession
    @State private var editingLabel = false
    @State private var labelText = ""
    @Environment(\.modelContext) private var modelContext

    private var zoneConfig: HRZoneConfig {
        HRZoneConfig(maxHR: session.maxHR)
    }

    private var sortedSamples: [GymHRSample] {
        session.samples.sorted { $0.timestamp < $1.timestamp }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                headerSection

                // HR Chart
                hrChartSection

                // Zone breakdown
                zoneBreakdownSection

                // Stats
                statsSection

                // Export
                exportSection
            }
            .padding()
        }
        .navigationTitle(session.label ?? "Workout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editingLabel = true } label: {
                    Image(systemName: "pencil")
                }
            }
        }
        .alert("Name This Workout", isPresented: $editingLabel) {
            TextField("e.g. Leg Day", text: $labelText)
            Button("Save") {
                session.label = labelText.isEmpty ? nil : labelText
                try? modelContext.save()
            }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear {
            labelText = session.label ?? ""
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.startTime, style: .date)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Text(session.startTime, style: .time)
                Text("–")
                Text(session.endTime, style: .time)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - HR Chart

    private var hrChartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Heart Rate")
                .font(.headline)

            if sortedSamples.count > 1 {
                Chart {
                    ForEach(sortedSamples) { sample in
                        let elapsed = sample.timestamp.timeIntervalSince(session.startTime) / 60.0
                        let zone = zoneConfig.zone(for: sample.bpm)
                        LineMark(
                            x: .value("Time (min)", elapsed),
                            y: .value("BPM", sample.bpm)
                        )
                        .foregroundStyle(zone.color)
                        .interpolationMethod(.catmullRom)

                        AreaMark(
                            x: .value("Time (min)", elapsed),
                            y: .value("BPM", sample.bpm)
                        )
                        .foregroundStyle(
                            .linearGradient(
                                colors: [zone.color.opacity(0.3), zone.color.opacity(0.0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)
                    }

                    // Yellow dots for cadence-filtered readings
                    ForEach(sortedSamples.filter { $0.cadenceFiltered == true }) { sample in
                        let elapsed = sample.timestamp.timeIntervalSince(session.startTime) / 60.0
                        PointMark(
                            x: .value("Time (min)", elapsed),
                            y: .value("BPM", sample.bpm)
                        )
                        .foregroundStyle(.yellow.opacity(0.6))
                        .symbolSize(20)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .chartXAxisLabel("Minutes")
                .chartYAxisLabel("BPM")
                .frame(height: 220)
            } else {
                Text("Not enough data points to chart.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Zone Breakdown

    private var zoneBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Time in Zones")
                .font(.headline)

            let total = session.zoneTimeSeconds.reduce(0, +)

            // Full-width bar
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(HRZone.allCases, id: \.rawValue) { zone in
                        let secs = zone.rawValue < session.zoneTimeSeconds.count ? session.zoneTimeSeconds[zone.rawValue] : 0
                        let fraction = total > 0 ? secs / total : 0
                        if fraction > 0.01 {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(zone.color)
                                .frame(width: geo.size.width * fraction)
                        }
                    }
                }
            }
            .frame(height: 14)

            // Zone rows
            ForEach(HRZone.allCases.filter { $0 != .rest }, id: \.rawValue) { zone in
                let secs = zone.rawValue < session.zoneTimeSeconds.count ? session.zoneTimeSeconds[zone.rawValue] : 0
                let pct = total > 0 ? (secs / total) * 100 : 0
                HStack {
                    Circle()
                        .fill(zone.color)
                        .frame(width: 10, height: 10)
                    Text(zone.label)
                        .font(.subheadline)
                    Text("– \(zone.subtitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formatZoneTime(secs))
                        .font(.subheadline.monospacedDigit())
                    Text(String(format: "(%.0f%%)", pct))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
    }

    // MARK: - Stats

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Summary")
                .font(.headline)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                statCard(title: "Duration", value: session.formattedDuration, icon: "timer")
                statCard(title: "Avg HR", value: "\(session.avgBPM)", icon: "heart.fill")
                statCard(title: "Peak HR", value: "\(session.peakBPM)", icon: "arrow.up.heart.fill")
                statCard(title: "Calories", value: "\(session.estimatedCalories)", icon: "flame.fill")
                statCard(title: "Samples", value: "\(session.samples.count)", icon: "waveform.path")
                if let steps = session.sportRTSteps, steps > 0 {
                    statCard(title: "Steps", value: "\(steps)", icon: "figure.run")
                }
                if let distM = session.sportDistanceM, distM > 0 {
                    statCard(title: "Distance", value: String(format: "%.2f km", Double(distM) / 1000.0), icon: "point.topleft.down.to.point.bottomright.curvepath")
                }
            }
        }
    }

    private func statCard(title: String, value: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.orange)
            Text(value)
                .font(.title3.bold())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemGray6))
        )
    }

    // MARK: - Export

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Export")
                .font(.headline)

            Button {
                exportCSV()
            } label: {
                Label("Export as CSV", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.systemGray6))
                    )
            }
        }
    }

    // MARK: - Helpers

    private func formatZoneTime(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private func exportCSV() {
        var csv = "timestamp,elapsed_seconds,bpm,zone,cadence_filtered\n"
        let formatter = ISO8601DateFormatter()
        for sample in sortedSamples {
            let elapsed = sample.timestamp.timeIntervalSince(session.startTime)
            let zone = zoneConfig.zone(for: sample.bpm)
            csv += "\(formatter.string(from: sample.timestamp)),\(String(format: "%.1f", elapsed)),\(sample.bpm),\(zone.label),\(sample.cadenceFiltered ?? false)\n"
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "workout_\(formatter.string(from: session.startTime)).csv"
        )
        try? csv.write(to: tempURL, atomically: true, encoding: .utf8)

        // Present share sheet
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else { return }
        let activityVC = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
        rootVC.present(activityVC, animated: true)
    }
}
