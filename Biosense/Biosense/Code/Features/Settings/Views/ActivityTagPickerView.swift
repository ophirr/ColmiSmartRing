//
//  ActivityTagPickerView.swift
//  Biosense
//
//  Lets the user tag incoming ring data with an activity context.
//  Tags are appended to all InfluxDB writes as an indexed tag.
//

import SwiftUI

struct ActivityTagPickerView: View {
    @State private var selectedTag: ActivityTag = InfluxDBWriter.shared.activeTag

    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible())
    ]

    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Section {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(ActivityTag.allCases) { tag in
                    TagButton(tag: tag, isSelected: selectedTag == tag) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedTag = tag
                            InfluxDBWriter.shared.activeTag = tag
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Activity Tag")
        } footer: {
            Text(selectedTag == .none
                 ? "No tag applied — data streams without activity context."
                 : "Tagging all data as \"\(selectedTag.displayName)\". Change anytime — tags apply to new samples only.")
        }
        .onReceive(refreshTimer) { _ in
            let current = InfluxDBWriter.shared.activeTag
            if current != selectedTag {
                withAnimation(.easeInOut(duration: 0.15)) {
                    selectedTag = current
                }
            }
        }
        .onAppear {
            selectedTag = InfluxDBWriter.shared.activeTag
        }
    }
}

// MARK: - Tag Button

private struct TagButton: View {
    let tag: ActivityTag
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: tag.icon)
                    .font(.system(size: 20))
                    .frame(height: 24)
                Text(tag.displayName)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.2) : Color(.systemGray6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
    }
}
