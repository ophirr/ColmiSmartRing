//
//  GymScreenView.swift
//  Halo
//
//  Main gym workout screen. Shows real-time heart rate with OTF-style
//  zone coloring, elapsed time, live HR sparkline, and zone bar.
//

import SwiftUI
import SwiftData

struct GymScreenView: View {
    var gymManager: GymSessionManager
    var ringSessionManager: RingSessionManager
    @Environment(\.modelContext) private var modelContext

    @State private var showingSettings = false
    @State private var showingHistory = false
    @State private var showingSaveConfirm = false
    @State private var completedWorkout: CompletedWorkout?
    @State private var finishedZoneTimeSeconds: [Double] = Array(repeating: 0, count: 6)
    @State private var finishedDurationSeconds: Double = 0
    @Environment(\.colorScheme) private var colorScheme
    private let healthWriter = AppleHealthGymWriter()

    /// Adaptive zone background — dark tint in dark mode, light tint in light mode.
    private var zoneBackground: Color {
        colorScheme == .dark ? gymManager.currentZone.darkColor : gymManager.currentZone.lightColor
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Full-screen zone gradient background
                let isActive = gymManager.workoutState == .active || gymManager.workoutState == .paused
                LinearGradient(
                    colors: isActive
                        ? [zoneBackground, zoneBackground.opacity(0.4), Color(red: 0.05, green: 0.05, blue: 0.08)]
                        : [Color(red: 0.08, green: 0.08, blue: 0.12), Color(red: 0.05, green: 0.05, blue: 0.08)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.8), value: gymManager.currentZone)
                .animation(.easeInOut(duration: 0.5), value: isActive)

                VStack(spacing: 0) {
                    switch gymManager.workoutState {
                    case .idle:
                        idleContent
                    case .active, .paused:
                        activeContent
                    case .finished:
                        finishedContent
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if gymManager.workoutState == .finished {
                    gymManager.resetToIdle()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingHistory = true } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.primary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(.primary)
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                GymSettingsSheet(gymManager: gymManager)
            }
            .sheet(isPresented: $showingHistory) {
                GymHistoryView()
            }
        }
    }

    // MARK: - Idle

    private var idleContent: some View {
        VStack(spacing: 32) {
            Spacer()

            // Connection status
            VStack(spacing: 8) {
                Image(systemName: ringSessionManager.isEffectivelyConnected ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.system(size: 40))
                    .foregroundStyle(ringSessionManager.isEffectivelyConnected ? .green : .orange)

                Text(ringSessionManager.demoModeActive ? "Demo Mode" :
                     ringSessionManager.peripheralConnected ? "Ring Connected" : "Ring Not Connected")
                    .font(.headline)
                    .foregroundStyle(.primary.opacity(0.8))
            }

            // Zone ranges — Z5 (All Out) at top
            VStack(spacing: 8) {
                ForEach((1..<6).reversed(), id: \.self) { i in
                    if let zone = HRZone(rawValue: i) {
                        let range = gymManager.zoneConfig.bpmRange(for: zone)
                        HStack {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(zone.color)
                                .frame(width: 52, height: 32)
                                .overlay {
                                    Text("Z\(i)")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            Text(zone.subtitle)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(.primary.opacity(0.7))
                                .frame(width: 90, alignment: .leading)
                            Spacer()
                            Text("\(range.lowerBound)–\(range.upperBound) BPM")
                                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.primary.opacity(0.6))
                        }
                        .padding(.horizontal, 24)
                    }
                }
            }

            // Color bar — Z5 (red) on left, Z1 (gray) on right
            HStack(spacing: 2) {
                ForEach((1..<6).reversed(), id: \.self) { i in
                    if let zone = HRZone(rawValue: i) {
                        Rectangle()
                            .fill(zone.color)
                            .frame(height: 6)
                    }
                }
            }
            .clipShape(Capsule())
            .padding(.horizontal, 32)

            // Start button
            Button {
                gymManager.startWorkout()
            } label: {
                Text("START WORKOUT")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(ringSessionManager.isEffectivelyConnected ?
                                  Color(red: 1.0, green: 0.55, blue: 0.0) :
                                    Color.gray.opacity(0.5))
                    )
            }
            .disabled(!ringSessionManager.isEffectivelyConnected)
            .padding(.horizontal, 32)

            Spacer()
        }
    }

    // MARK: - Active workout

    private var activeContent: some View {
        VStack(spacing: 0) {
            // Timer
            Text(gymManager.formattedElapsed)
                .font(.system(size: 22, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.7))
                .padding(.top, 20)

            Spacer()

            // Big HR number or warmup indicator
            if gymManager.currentBPM > 0 {
                VStack(spacing: 4) {
                    Text("\(gymManager.currentBPM)")
                        .font(.system(size: 120, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)

                    Text("BPM")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.primary.opacity(0.6))
                }

                // Zone label
                Text(gymManager.currentZone.colorLabel.uppercased())
                    .font(.system(size: 24, weight: .heavy))
                    .foregroundStyle(gymManager.currentZone.color)
                    .padding(.top, 4)

                Text(gymManager.currentZone.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.primary.opacity(0.5))
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.primary.opacity(0.6))
                    Text("Warming up sensor...")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.primary.opacity(0.6))
                    Text("Keep the ring snug on your finger")
                        .font(.subheadline)
                        .foregroundStyle(.primary.opacity(0.4))
                }
            }

            Spacer()

            // HR sparkline
            if gymManager.samples.count > 1 {
                HRSparkline(
                    samples: gymManager.recentSamples(count: 60),
                    currentZone: gymManager.currentZone,
                    zoneConfig: gymManager.zoneConfig
                )
                .frame(height: 80)
                .padding(.horizontal, 16)
            }

            // Zone time bar
            ZoneTimeBar(zoneTimeSeconds: gymManager.zoneTimeSeconds)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            // Stats row
            HStack(spacing: 40) {
                StatPill(title: "AVG", value: "\(gymManager.avgBPM)")
                StatPill(title: "PEAK", value: "\(gymManager.peakBPM)")
            }
            .padding(.top, 12)

            // Control buttons
            HStack(spacing: 24) {
                if gymManager.workoutState == .paused {
                    Button { gymManager.resumeWorkout() } label: {
                        ControlCircle(icon: "play.fill", color: .green)
                    }
                } else {
                    Button { gymManager.pauseWorkout() } label: {
                        ControlCircle(icon: "pause.fill", color: .yellow)
                    }
                }

                Button {
                    completedWorkout = gymManager.stopWorkout()
                    if let w = completedWorkout {
                        finishedZoneTimeSeconds = w.zoneTimeSeconds
                        finishedDurationSeconds = w.durationSeconds
                    }
                    showingSaveConfirm = completedWorkout != nil
                } label: {
                    ControlCircle(icon: "stop.fill", color: .red)
                }
            }
            .padding(.vertical, 20)
        }
        .alert("Save Workout?", isPresented: $showingSaveConfirm) {
            Button("Save") { saveWorkout() }
            Button("Discard", role: .destructive) { completedWorkout = nil }
            Button("Cancel", role: .cancel) { }
        } message: {
            if let w = completedWorkout {
                Text("\(w.samples.count) HR samples over \(formatDuration(w.durationSeconds))\nAvg: \(w.avgBPM) BPM  Peak: \(w.peakBPM) BPM")
            }
        }
    }

    // MARK: - Finished

    private var finishedContent: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)

            Text("Workout Complete")
                .font(.title.bold())
                .foregroundStyle(.primary)

            Text(formatDuration(finishedDurationSeconds))
                .font(.title3)
                .foregroundStyle(.secondary)

            // Zone time breakdown — include all zones (rest through Z5)
            let zones = HRZone.allCases
            let hasAnyTime = finishedZoneTimeSeconds.reduce(0, +) > 0

            if hasAnyTime {
                VStack(spacing: 8) {
                    ForEach(zones, id: \.rawValue) { zone in
                        let secs = zone.rawValue < finishedZoneTimeSeconds.count ? finishedZoneTimeSeconds[zone.rawValue] : 0
                        if secs > 0 {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(zone.color)
                                    .frame(width: 12, height: 12)
                                Text(zone.colorLabel)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(formatDuration(secs))
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, 8)
            }

            Spacer()
        }
    }

    // MARK: - Actions

    private func saveWorkout() {
        guard let w = completedWorkout else { return }
        let stored = w.toStoredSession()
        modelContext.insert(stored)
        try? modelContext.save()

        // Write to Apple Health
        Task {
            await healthWriter.writeGymSession(stored)
        }

        completedWorkout = nil
        // Stay in .finished state — auto-resets after 5 seconds
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Extracted subviews

private struct HRSparkline: View {
    let samples: [LiveHRSample]
    let currentZone: HRZone
    let zoneConfig: HRZoneConfig

    var body: some View {
        let bpms = samples.map(\.bpm)
        let minBPM = max(40, (bpms.min() ?? 60) - 10)
        let maxBPM = min(220, (bpms.max() ?? 180) + 10)

        Canvas { context, size in
            let w = size.width
            let h = size.height
            let count = samples.count
            guard count > 1 else { return }

            var path = Path()
            for (i, sample) in samples.enumerated() {
                let x = w * CGFloat(i) / CGFloat(count - 1)
                let y = yPos(bpm: sample.bpm, min: minBPM, max: maxBPM, height: h)
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(currentZone.color), lineWidth: 2.5)

            if let last = samples.last {
                let x = w
                let y = yPos(bpm: last.bpm, min: minBPM, max: maxBPM, height: h)
                let rect = CGRect(x: x - 4, y: y - 4, width: 8, height: 8)
                context.fill(Path(ellipseIn: rect), with: .color(.primary))
            }
        }
    }

    private func yPos(bpm: Int, min: Int, max: Int, height: CGFloat) -> CGFloat {
        let range = CGFloat(max - min)
        guard range > 0 else { return height / 2 }
        return height * (1 - CGFloat(bpm - min) / range)
    }
}

private struct ZoneTimeBar: View {
    let zoneTimeSeconds: [Double]

    var body: some View {
        let total = zoneTimeSeconds.reduce(0, +)
        let zones = HRZone.allCases.filter { $0 != .rest }

        VStack(spacing: 6) {
            // Proportional bar
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(zones, id: \.rawValue) { zone in
                        let secs = zone.rawValue < zoneTimeSeconds.count ? zoneTimeSeconds[zone.rawValue] : 0
                        let fraction = total > 0 ? secs / total : 0
                        RoundedRectangle(cornerRadius: 4)
                            .fill(fraction > 0 ? zone.color : zone.color.opacity(0.15))
                            .frame(width: max(6, geo.size.width * max(fraction, 0.04)))
                    }
                }
            }
            .frame(height: 10)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            // Time per zone
            HStack(spacing: 0) {
                ForEach(zones, id: \.rawValue) { zone in
                    let secs = zone.rawValue < zoneTimeSeconds.count ? zoneTimeSeconds[zone.rawValue] : 0
                    VStack(spacing: 2) {
                        Circle()
                            .fill(zone.color)
                            .frame(width: 6, height: 6)
                        Text(formatZoneTime(secs))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(secs > 0 ? Color.secondary : Color.secondary.opacity(0.3))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func formatZoneTime(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        if m > 0 {
            return "\(m):\(String(format: "%02d", s))"
        }
        return "\(s)s"
    }
}

private struct StatPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
        }
    }
}

private struct ControlCircle: View {
    let icon: String
    let color: Color

    var body: some View {
        Image(systemName: icon)
            .font(.title2.bold())
            .foregroundStyle(.white)
            .frame(width: 64, height: 64)
            .background(Circle().fill(color))
    }
}

// MARK: - Settings Sheet

struct GymSettingsSheet: View {
    var gymManager: GymSessionManager
    @Environment(\.dismiss) private var dismiss
    @State private var maxHRText: String = ""

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Heart Rate
                Section("Max Heart Rate") {
                    HStack {
                        TextField("Max HR", text: $maxHRText)
                            .keyboardType(.numberPad)
                            .font(.title2.bold())
                        Text("BPM")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Zone Ranges") {
                    ForEach(1..<6) { i in
                        if let zone = HRZone(rawValue: i) {
                            let range = gymManager.zoneConfig.bpmRange(for: zone)
                            HStack {
                                Circle()
                                    .fill(zone.color)
                                    .frame(width: 12, height: 12)
                                Text(zone.label)
                                    .font(.headline)
                                Text("– \(zone.subtitle)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(range.lowerBound) – \(range.upperBound) BPM")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if gymManager.zoneConfig.customBoundaries != nil {
                        Text("Using exact Orangetheory boundaries for \(gymManager.zoneConfig.maxHR) max HR.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Zones calculated from max HR using OTF-style percentages.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                // MARK: Ring Fit
                Section("Ring Placement") {
                    Picker("Finger", selection: Binding(
                        get: { gymManager.ringFinger },
                        set: { gymManager.ringFinger = $0 }
                    )) {
                        ForEach(RingFinger.allCases) { finger in
                            Text(finger.rawValue).tag(finger)
                        }
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Signal Quality", systemImage: "waveform.path")
                            .font(.subheadline.bold())
                        Text(gymManager.ringFinger.sensorNote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Fit Tip", systemImage: "hand.raised")
                            .font(.subheadline.bold())
                        Text(gymManager.ringFinger.fitTip)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                // MARK: Haptics
                Section("Feedback") {
                    Toggle("Zone Change Haptics", isOn: Binding(
                        get: { gymManager.hapticsEnabled },
                        set: { gymManager.hapticsEnabled = $0 }
                    ))

                    if gymManager.hapticsEnabled {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Haptic Pattern")
                                .font(.subheadline.bold())
                            Text("Light tap when dropping zones. Medium tap when climbing. Double tap when entering Zone 5 (All Out).")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }

                // MARK: Info
                Section("About") {
                    HStack {
                        Text("Sensor")
                        Spacer()
                        Text("Colmi R02 PPG")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Sampling")
                        Spacer()
                        Text("Real-time BLE stream")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Data")
                        Spacer()
                        Text("Stored locally on device")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Gym Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if let hr = Int(maxHRText), hr > 100, hr < 250 {
                            gymManager.zoneConfig = gymManager.zoneConfig.withMaxHR(hr)
                        }
                        dismiss()
                    }
                }
            }
            .onAppear {
                maxHRText = "\(gymManager.zoneConfig.maxHR)"
            }
        }
    }
}
