//
//  CloudSyncSectionView.swift
//  Halo
//
//  Settings section showing InfluxDB cloud sync status and toggle.
//

import SwiftUI

struct CloudSyncSectionView: View {
    @AppStorage("cloudSyncEnabled") private var syncEnabled = true
    @State private var stats: String = ""
    private let timer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        Section {
            Toggle(isOn: $syncEnabled) {
                Label("Cloud Sync", systemImage: "icloud.and.arrow.up")
            }
            .onChange(of: syncEnabled) { _, enabled in
                if enabled {
                    InfluxDBWriter.shared.start()
                } else {
                    InfluxDBWriter.shared.stop()
                }
            }

            if syncEnabled {
                HStack {
                    Text("Bucket")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("ringie")
                        .foregroundStyle(.primary)
                }

                HStack {
                    Text("Region")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("us-east-1")
                        .foregroundStyle(.primary)
                }

                if !stats.isEmpty {
                    HStack {
                        Text("Status")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(stats)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("InfluxDB")
        } footer: {
            Text(syncEnabled
                 ? "Heart rate, HRV, SpO2, stress, sleep, and activity sync to InfluxDB Cloud."
                 : "Data is stored locally on-device only.")
        }
        .onReceive(timer) { _ in
            if syncEnabled {
                stats = InfluxDBWriter.shared.stats
            }
        }
        .onAppear {
            if syncEnabled {
                stats = InfluxDBWriter.shared.stats
            }
        }
    }
}
