//
//  GymHistoryView.swift
//  Biosense
//
//  Lists saved gym workout sessions with summary stats.
//  Tap a session to see the detailed HR chart.
//

import SwiftUI
import SwiftData

struct GymHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \StoredGymSession.startTime, order: .reverse) private var sessions: [StoredGymSession]

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "No Workouts Yet",
                        systemImage: "figure.strengthtraining.traditional",
                        description: Text("Complete a gym session and it will appear here.")
                    )
                } else {
                    List {
                        ForEach(sessions) { session in
                            NavigationLink(destination: GymSessionDetailView(session: session)) {
                                sessionRow(session)
                            }
                        }
                        .onDelete(perform: deleteSessions)
                    }
                }
            }
            .navigationTitle("Workout History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func sessionRow(_ session: StoredGymSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(session.label ?? "Workout")
                    .font(.headline)
                Spacer()
                Text(session.startTime, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                Label(session.formattedDuration, systemImage: "timer")
                Label("\(session.avgBPM) avg", systemImage: "heart.fill")
                    .foregroundStyle(.red)
                Label("\(session.peakBPM) peak", systemImage: "arrow.up.heart.fill")
                    .foregroundStyle(.orange)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let distM = session.sportDistanceM, distM > 0 {
                HStack(spacing: 16) {
                    if let steps = session.sportRTSteps, steps > 0 {
                        Label("\(steps) steps", systemImage: "figure.run")
                    }
                    Label(String(format: "%.2f km", Double(distM) / 1000.0), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    Label("\(session.estimatedCalories) cal", systemImage: "flame.fill")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // Mini zone bar
            miniZoneBar(session.zoneTimeSeconds)
                .frame(height: 6)
        }
        .padding(.vertical, 4)
    }

    private func miniZoneBar(_ zoneTimes: [Double]) -> some View {
        let total = zoneTimes.reduce(0, +)
        return GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(HRZone.allCases, id: \.rawValue) { zone in
                    let secs = zone.rawValue < zoneTimes.count ? zoneTimes[zone.rawValue] : 0
                    let fraction = total > 0 ? secs / total : 0
                    if fraction > 0.01 {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(zone.color)
                            .frame(width: geo.size.width * fraction)
                    }
                }
            }
        }
    }

    private func deleteSessions(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(sessions[index])
        }
        try? modelContext.save()
    }
}
