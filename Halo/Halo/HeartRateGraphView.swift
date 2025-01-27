//
//  HeartRateGraphView.swift
//  Halo
//
//  Created by Yannis De Cleene on 27/01/2025.
//

import SwiftUI
import Charts

struct HeartRateDataPoint: Identifiable {
    let id = UUID()
    let heartRate: Int
    let time: Date
}

struct HeartRateGraphView: View {
    let data: [HeartRateDataPoint]

    var body: some View {
        Chart {
            ForEach(data) { point in
                LineMark(
                    x: .value("Time", point.time),
                    y: .value("Heart Rate", point.heartRate)
                )
                .interpolationMethod(.catmullRom) // Smooth the line
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) // Y-axis on the left
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour)) // Customize x-axis labels
        }
        .padding()
        .frame(height: 300) // Adjust graph size
    }
}

struct HeartRateGraphContainerView: View {
    @State private var data: [HeartRateDataPoint] = []

    var body: some View {
        VStack {
            if data.isEmpty {
                Text("No Data Available")
                    .foregroundColor(.gray)
            } else {
                HeartRateGraphView(data: data)
            }
        }
    }
}
