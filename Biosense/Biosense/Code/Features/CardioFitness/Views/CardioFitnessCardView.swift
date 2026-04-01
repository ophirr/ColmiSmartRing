//
//  CardioFitnessCardView.swift
//  Biosense
//
//  Home screen card showing cardio fitness trend (improving/stable/declining).
//  Never displays raw VO2max numbers — only trend direction.
//

import SwiftUI

struct CardioFitnessCardView: View {
    let trend: CardioFitnessTrend?
    let dataPointCount: Int

    @State private var showingInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Cardio Fitness", systemImage: "heart.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { showingInfo = true } label: {
                    Image(systemName: "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if let trend, trend != .insufficientData {
                HStack(spacing: 6) {
                    Image(systemName: trendIcon(trend))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(trendColor(trend))
                    Text(trendLabel(trend))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(trendColor(trend))
                }

                Text("Based on \(dataPointCount) days")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Needs more data")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                if dataPointCount > 0 {
                    Text("\(dataPointCount) of 7 days")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .biosenseCardStyle()
        .sheet(isPresented: $showingInfo) {
            CardioFitnessInfoView()
        }
    }

    private func trendIcon(_ trend: CardioFitnessTrend) -> String {
        switch trend {
        case .improving: return "arrow.up.right"
        case .stable: return "minus"
        case .declining: return "arrow.down.right"
        case .insufficientData: return "questionmark"
        }
    }

    private func trendColor(_ trend: CardioFitnessTrend) -> Color {
        switch trend {
        case .improving: return .green
        case .stable: return .gray
        case .declining: return .orange
        case .insufficientData: return .gray
        }
    }

    private func trendLabel(_ trend: CardioFitnessTrend) -> String {
        switch trend {
        case .improving: return "Improving"
        case .stable: return "Stable"
        case .declining: return "Declining"
        case .insufficientData: return "Needs data"
        }
    }
}
