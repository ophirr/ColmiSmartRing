//
//  DemoModeSectionView.swift
//  Halo
//
//  Toggle for demo data generation — synthetic biometrics for testing.
//

import SwiftUI
import SwiftData

struct DemoModeSectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var ringSessionManager: RingSessionManager
    @State private var isEnabled = false
    @State private var sampleCount: Int = 0
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        Section {
            Toggle(isOn: $isEnabled) {
                Label("Demo Mode", systemImage: "waveform.path.ecg.rectangle")
            }
            .tint(.orange)
            .onChange(of: isEnabled) { _, enabled in
                if enabled {
                    DemoDataGenerator.shared.start(modelContext: modelContext, ringSessionManager: ringSessionManager)
                } else {
                    DemoDataGenerator.shared.stop()
                }
            }

            if isEnabled {
                HStack {
                    Text("Samples generated")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(sampleCount)")
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                        .fontWeight(.medium)
                }

                HStack {
                    Text("Emit rate")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Every 10s")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Streams")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("HR · HRV · SpO2 · Stress")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Demo")
        } footer: {
            Text(isEnabled
                 ? "Generating synthetic biometrics. Data flows to local charts and InfluxDB. Activity tag affects generated values."
                 : "Enable to simulate ring data for testing without a physical ring.")
        }
        .onReceive(timer) { _ in
            sampleCount = DemoDataGenerator.shared.samplesGenerated
        }
        .onAppear {
            isEnabled = DemoDataGenerator.shared.isRunning
            sampleCount = DemoDataGenerator.shared.samplesGenerated
        }
    }
}
