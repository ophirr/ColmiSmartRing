//
//  BatterySectionView.swift
//  Halo
//
//  Battery feature: visual gauge with color-coded level and charging indicator.
//

import SwiftUI

struct BatterySectionView: View {
    @Bindable var ringSessionManager: RingSessionManager

    var body: some View {
        Section(L10n.Battery.sectionTitle) {
            if let info = ringSessionManager.currentBatteryInfo {
                HStack(spacing: 14) {
                    // Battery icon
                    batteryIcon(level: info.batteryLevel, charging: info.charging)
                        .font(.system(size: 36))
                        .foregroundStyle(batteryColor(info.batteryLevel))
                        .symbolEffect(.pulse, options: .repeating, isActive: info.charging)

                    VStack(alignment: .leading, spacing: 6) {
                        // Percentage
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text("\(info.batteryLevel)")
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text("%")
                                .font(.system(size: 18, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }

                        // Progress bar
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(.systemGray5))
                                    .frame(height: 8)

                                RoundedRectangle(cornerRadius: 4)
                                    .fill(batteryColor(info.batteryLevel).gradient)
                                    .frame(width: geo.size.width * CGFloat(info.batteryLevel) / 100.0, height: 8)
                            }
                        }
                        .frame(height: 8)

                        // Status label
                        HStack(spacing: 4) {
                            if info.charging {
                                Image(systemName: "bolt.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.yellow)
                                Text("Charging")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(batteryEstimate(info.batteryLevel))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            } else {
                HStack(spacing: 14) {
                    Image(systemName: "battery.0percent")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("--%")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                        Text("Connect ring to check battery")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
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

    /// Rough battery life estimate scaled by HR log interval.
    /// Baseline model: 17mAh battery, PPG sensor is the dominant drain.
    /// At 5 min interval ≈ 5 days. Each PPG wake costs roughly the same energy,
    /// so total life scales roughly linearly with interval.
    private func batteryEstimate(_ level: Int) -> String {
        let interval = ringSessionManager.hrLogIntervalMinutes ?? 5
        // Baseline: 5 days at 5-min interval. Scale linearly.
        // 1 min → 5x more wakes → ~1 day. 10 min → 0.5x wakes → ~7 days (capped by idle drain).
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
            return "Low — charge soon"
        } else if daysRemaining < 1.0 {
            return "~\(Int(daysRemaining * 24))h remaining @ \(interval)min interval"
        } else {
            let d = Int(daysRemaining)
            return "~\(d) day\(d == 1 ? "" : "s") remaining @ \(interval)min interval"
        }
    }
}
