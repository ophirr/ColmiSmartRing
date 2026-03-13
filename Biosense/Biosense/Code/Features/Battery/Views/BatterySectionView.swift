//
//  BatterySectionView.swift
//  Biosense
//
//  Battery feature: compact row with icon, level bar, and estimate.
//

import SwiftUI

struct BatterySectionView: View {
    @Bindable var ringSessionManager: RingSessionManager

    var body: some View {
        Section(L10n.Battery.sectionTitle) {
            if let info = ringSessionManager.currentBatteryInfo {
                HStack(spacing: 10) {
                    batteryIcon(level: info.batteryLevel, charging: info.charging)
                        .font(.system(size: 20))
                        .foregroundStyle(batteryColor(info.batteryLevel))
                        .symbolEffect(.pulse, options: .repeating, isActive: info.charging)

                    Text("\(info.batteryLevel)%")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(.systemGray5))
                                .frame(height: 6)

                            RoundedRectangle(cornerRadius: 3)
                                .fill(batteryColor(info.batteryLevel).gradient)
                                .frame(width: geo.size.width * CGFloat(info.batteryLevel) / 100.0, height: 6)
                        }
                    }
                    .frame(height: 6)

                    if info.charging {
                        HStack(spacing: 2) {
                            Image(systemName: "bolt.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                            Text("Charging")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .fixedSize()
                    } else {
                        Text(batteryEstimate(info.batteryLevel))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "battery.0percent")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    Text("--%")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Connect ring")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Helpers

    private func batteryIcon(level: Int, charging: Bool) -> Image {
        if charging {
            return Image(systemName: "battery.100percent.bolt")
        }
        switch level {
        case 0..<13:  return Image(systemName: "battery.0percent")
        case 13..<38: return Image(systemName: "battery.25percent")
        case 38..<63: return Image(systemName: "battery.50percent")
        case 63..<88: return Image(systemName: "battery.75percent")
        default:      return Image(systemName: "battery.100percent")
        }
    }

    private func batteryColor(_ level: Int) -> Color {
        switch level {
        case 0..<20:  return .red
        case 20..<40: return .orange
        case 40..<60: return .yellow
        default:      return .green
        }
    }

    private func batteryEstimate(_ level: Int) -> String {
        let interval = ringSessionManager.hrLogIntervalMinutes ?? 5
        let baseDays: Double = switch interval {
        case 1:  1.2
        case 2:  2.0
        case 3:  2.8
        case 4:  3.5
        case 5:  4.5
        case 6:  5.0
        case 7:  5.5
        case 8:  6.0
        case 9:  6.5
        case 10: 7.0
        default: 4.5
        }
        let daysRemaining = Double(level) / 100.0 * baseDays
        if daysRemaining < 0.5 {
            return "Low"
        } else if daysRemaining < 1.0 {
            return "~\(Int(daysRemaining * 24))h left"
        } else {
            let d = Int(daysRemaining)
            return "~\(d)d left"
        }
    }
}
