//
//  HRLogIntervalSectionView.swift
//  Biosense
//
//  HR log interval (1–10 min) slider + enable toggle.
//  Sends CMD_HR_TIMING_MONITOR (0x16) to the ring.
//

import SwiftUI

struct HRLogIntervalSectionView: View {
    @Bindable var ringSessionManager: RingSessionManager

    @AppStorage(AppSettings.Ring.hrLogInterval) private var savedInterval: Int = 1
    @State private var sliderValue: Double = 1
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
                } onEditingChanged: { editing in
                    // Only save and send when the user finishes dragging.
                    // This prevents ring-response-driven slider updates from
                    // triggering BLE writes or overwriting savedInterval.
                    if !editing {
                        let minutes = Int(sliderValue)
                        savedInterval = minutes
                        sendSettings(enabled: true, interval: minutes)
                    }
                }
                .disabled(!isConnected || isSending)

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
                } else if let enabled = ringEnabled ?? (isConnected ? true : nil) {
                    let displayInterval = savedInterval
                    Image(systemName: enabled ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(enabled ? .green : .secondary)
                    Text(enabled ? "Ring logging every \(displayInterval) min" : "Ring logging disabled")
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
            sliderValue = Double(savedInterval)
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
                if enabled {
                    // Ensure the Heart Rate tracking setting (command 22) is also
                    // enabled so the ring's PPG sensor is active for logging.
                    try await ringSessionManager.writeTrackingSetting(.heartRate, enabled: true)
                }
                try await ringSessionManager.writeHRLogSettings(enabled: enabled, intervalMinutes: interval)
            } catch {
                tLog("[HRLogInterval] Write failed: \(error)")
            }
        }
    }
}
