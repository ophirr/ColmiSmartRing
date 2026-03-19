//
//  TrackingSettingsSectionView.swift
//  Biosense
//
//  Settings feature: HRV, Heart Rate, Blood Oxygen, Pressure toggles.
//

import SwiftUI

struct TrackingSettingsSectionView: View {
    @Bindable var ringSessionManager: RingSessionManager
    @AppStorage("trackingSetting.hrv") private var hrvEnabled = true
    @AppStorage("trackingSetting.heartRate") private var heartRateEnabled = true
    @AppStorage("trackingSetting.bloodOxygen") private var bloodOxygenEnabled = true
    @AppStorage("trackingSetting.pressure") private var pressureEnabled = true

    var body: some View {
        Section(L10n.Settings.sectionTitle) {
            ForEach(RingTrackingSetting.allCases, id: \.displayName) { setting in
                trackingSettingRow(
                    setting: setting,
                    enabled: bindingForSetting(setting),
                    isConnected: ringSessionManager.isEffectivelyConnected,
                    isDemoMode: ringSessionManager.demoModeActive,
                    writeTrackingSetting: ringSessionManager.writeTrackingSetting
                )
            }
        }
        .onAppear {
            if ringSessionManager.peripheralConnected {
                Task { @MainActor in await loadTrackingSettingsFromRing() }
            }
        }
        .onChange(of: ringSessionManager.isReadyForSettingsQuery) {
            if ringSessionManager.isReadyForSettingsQuery {
                Task { @MainActor in await loadTrackingSettingsFromRing() }
            }
        }
    }

    private func loadTrackingSettingsFromRing() async {
        guard ringSessionManager.peripheralConnected else { return }
        if let enabled = try? await ringSessionManager.readTrackingSetting(.hrv) { hrvEnabled = enabled }
        if let enabled = try? await ringSessionManager.readTrackingSetting(.heartRate) { heartRateEnabled = enabled }
        if let enabled = try? await ringSessionManager.readTrackingSetting(.bloodOxygen) { bloodOxygenEnabled = enabled }
        if let enabled = try? await ringSessionManager.readTrackingSetting(.pressure) { pressureEnabled = enabled }
    }

    private func bindingForSetting(_ setting: RingTrackingSetting) -> Binding<Bool> {
        switch setting {
        case .hrv: return $hrvEnabled
        case .heartRate: return $heartRateEnabled
        case .bloodOxygen: return $bloodOxygenEnabled
        case .pressure: return $pressureEnabled
        }
    }

    @ViewBuilder
    private func trackingSettingRow(
        setting: RingTrackingSetting,
        enabled: Binding<Bool>,
        isConnected: Bool,
        isDemoMode: Bool,
        writeTrackingSetting: @escaping (RingTrackingSetting, Bool) async throws -> Void
    ) -> some View {
        let toggleBinding = Binding<Bool>(
            get: { enabled.wrappedValue },
            set: { newValue in
                enabled.wrappedValue = newValue
                // In demo mode, just toggle locally — no BLE write
                guard !isDemoMode else { return }
                Task { @MainActor in
                    do {
                        try await writeTrackingSetting(setting, newValue)
                    } catch {
                        enabled.wrappedValue = !newValue
                    }
                }
            }
        )
        let displayName = L10n.Settings.trackingDisplayName(for: setting)
        Toggle(displayName, isOn: toggleBinding)
            .disabled(!isConnected)
            .accessibilityLabel(L10n.A11y.settingsToggle(displayName))
            .accessibilityHint(
                isConnected
                ? Text(L10n.A11y.settingsToggleConnectedHint)
                : Text(L10n.A11y.settingsToggleDisconnectedHint)
            )
    }
}
