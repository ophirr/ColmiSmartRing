//
//  HeartRateGraphView.swift
//  Biosense
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
    var timeRange: TimeRange = .day
    var xDomain: ClosedRange<Date>? = nil

    private var yDomain: ClosedRange<Int> {
        let values = data.map(\.heartRate)
        guard let lo = values.min(), let hi = values.max() else { return 40...150 }
        return max(lo - 10, 0)...hi + 10
    }

    var body: some View {
        Chart {
            ForEach(data) { point in
                LineMark(
                    x: .value(L10n.HeartRateGraph.axisTime, point.time),
                    y: .value(L10n.HeartRateGraph.axisHeartRate, point.heartRate)
                )
                .interpolationMethod(.catmullRom)
            }
        }
        .chartYScale(domain: yDomain)
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .timeRangeXAxis(timeRange, domain: xDomain)
        .padding()
        .frame(height: 300)
    }
}

#Preview("Heart Rate (PreviewData)") {
    List {
        HeartRateGraphView(data: PreviewData.heartRatePoints)
    }
}
