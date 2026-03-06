//
//  HRLogIntervalSectionView.swift
//  Halo
//
//  HR log interval (1–10 min) slider + enable toggle.
//  Sends CMD_HR_TIMING_MONITOR (0x16) to the ring.
//

import SwiftUI

struct HRLogIntervalSectionView: View {
    @Bindable var ringSessionManager: RingSessionManager

    @AppStorage("hrLogInterval") private var savedInterval: Int = 5
    @State private var sliderValue: Double = 5
    @State private var isSending = false

    private var isConnected: Bool { ringSessionManager.isEffectivelyConnected }
    private var isDemoMode: Bool { ringSessionManager.demoModeActive }
    private var ringInterval: Int? { ringSessionManager.hrLogIntervalMinutes }
    private var ringEnabled: Bool? { ringSessionManager.hrLogEnabled }

    var body: some View {
        Section {
            // Interval slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("HR Sampling Interval", systemImage: "heart.text.square")
                    Spacer()
                    Text("\(Int(sliderValue)) min")
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(intervalColor)
                }

                Slider(
                    value: $sliderValue,
                    in: 1...10,
                    step: 1
                ) {
                    Text("Interval")
                } minimumValueLabel: {
                    Text("1").font(.caption2).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("10").font(.caption2).foregroundStyle(.secondary)
                }
                .disabled(!isConnected || isSending)
                .onChange(of: sliderValue) { _, newValue in
                    let minutes = Int(newValue)
                    savedInterval = minutes
                    sendSettings(enabled: true, interval: minutes)
                }

                // Battery impact hint
                HStack(spacing: 4) {
                    Image(systemName: batteryHintIcon)
                        .font(.caption2)
                    Text(batteryHintText)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }

            // Status row
            HStack {
                if isSending {
                    ProgressView()
                        .controlSize(.small)
                    Text("Sending…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let interval = ringInterval, let enabled = ringEnabled {
                    Image(systemName: enabled ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(enabled ? .green : .secondary)
                    Text(enabled ? "Ring logging every \(interval) min" : "Ring logging disabled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !isConnected {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .foregroundStyle(.secondary)
                    Text("Connect ring to configure")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                    Text("Querying ring…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Heart Rate Logging")
        } footer: {
            Text("Controls how often the ring wakes the PPG sensor for a background heart rate reading. Lower intervals give more data but drain the battery faster.")
        }
        .onAppear {
            // Initialize slider from saved or ring value
            if let ringVal = ringInterval {
                sliderValue = Double(ringVal)
                savedInterval = ringVal
            } else {
                sliderValue = Double(savedInterval)
            }
        }
        .onChange(of: ringInterval) { _, newVal in
            if let newVal {
                sliderValue = Double(newVal)
                savedInterval = newVal
            }
        }
    }

    // MARK: - Helpers

    private var intervalColor: Color {
        let v = Int(sliderValue)
        if v <= 2 { return .red }
        if v <= 4 { return .orange }
        if v <= 6 { return .primary }
        return .green
    }

    private var batteryHintIcon: String {
        let v = Int(sliderValue)
        if v <= 2 { return "battery.25percent" }
        if v <= 4 { return "battery.50percent" }
        if v <= 6 { return "battery.75percent" }
        return "battery.100percent"
    }

    private var batteryHintText: String {
        let v = Int(sliderValue)
        let days: String = switch v {
        case 1:  "~1 day"
        case 2:  "~2 days"
        case 3:  "~3 days"
        case 4:  "~3.5 days"
        case 5:  "~4.5 days"
        case 6:  "~5 days"
        case 7:  "~5.5 days"
        case 8:  "~6 days"
        case 9:  "~6.5 days"
        case 10: "~7 days"
        default: "~4.5 days"
        }
        return "\(days) battery life at \(v)min interval"
    }

    private func sendSettings(enabled: Bool, interval: Int) {
        guard isConnected, !isSending else { return }
        // In demo mode, just update local state — no BLE write
        if isDemoMode {
            ringSessionManager.hrLogIntervalMinutes = interval
            ringSessionManager.hrLogEnabled = enabled
            return
        }
        isSending = true
        Task { @MainActor in
            defer { isSending = false }
            do {
                try await ringSessionManager.writeHRLogSettings(enabled: enabled, intervalMinutes: interval)
            } catch {
                debugPrint("[HRLogInterval] Write failed: \(error)")
            }
        }
    }
}
