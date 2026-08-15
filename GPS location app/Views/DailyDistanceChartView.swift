//
//  DailyDistanceChartView.swift
//  GPS location app
//
//  Created by Claude on 2/26/26.
//

import SwiftUI
import Charts

struct DailyDistanceChartView: View {
    @ObservedObject var analytics: WorkoutAnalyticsManager
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selectedDay: Int? = nil

    private var isIPad: Bool { sizeClass == .regular }
    private var chartHeight: CGFloat { isIPad ? 380 : 250 }

    private var selectedData: AnalyticsDailyDistance? {
        guard let day = selectedDay else { return nil }
        return analytics.dailyDistances.first(where: { $0.day == day })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isIPad ? 16 : 12) {
            // Header
            HStack {
                Text("Daily Distance")
                    .font(isIPad ? .title3 : .headline)
                Spacer()
                Text(analytics.monthName + " \(analytics.selectedYear)")
                    .font(isIPad ? .headline : .subheadline)
                    .foregroundColor(.secondary)
            }

            if analytics.dailyDistances.isEmpty {
                Text("No data for this month")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: chartHeight)
            } else {
                let maxDaily = analytics.dailyDistances.map(\.distanceKm).max() ?? 1
                let maxCumulative = analytics.dailyDistances.last?.cumulativeKm ?? 10
                let maxY = max(maxCumulative * 1.15, maxDaily * 1.15, 1)

                Chart {
                    ForEach(analytics.dailyDistances) { data in
                        // Bar marks for daily distance
                        BarMark(
                            x: .value("Day", data.day),
                            y: .value("Distance", data.distanceKm)
                        )
                        .foregroundStyle(
                            data.day == selectedDay
                            ? Color.blue.opacity(0.8)
                            : Color.blue.opacity(0.35)
                        )
                        .cornerRadius(2)
                    }

                    ForEach(analytics.dailyDistances) { data in
                        // Area mark gradient fill under cumulative line
                        AreaMark(
                            x: .value("Day", data.day),
                            y: .value("Cumulative", data.cumulativeKm)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.orange.opacity(0.25), Color.orange.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)

                        // Line mark for cumulative distance
                        LineMark(
                            x: .value("Day", data.day),
                            y: .value("Cumulative", data.cumulativeKm)
                        )
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .interpolationMethod(.catmullRom)
                    }

                    // Point mark on last data point
                    if let last = analytics.dailyDistances.last {
                        PointMark(
                            x: .value("Day", last.day),
                            y: .value("Cumulative", last.cumulativeKm)
                        )
                        .foregroundStyle(.orange)
                        .symbolSize(40)
                    }

                    // Selection indicator
                    if let selectedDay, let data = selectedData {
                        RuleMark(x: .value("Selected", selectedDay))
                            .foregroundStyle(.gray.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 3]))
                            .annotation(position: .top, alignment: .center, spacing: 4) {
                                VStack(spacing: 4) {
                                    Text("Day \(data.day)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    HStack(spacing: 8) {
                                        HStack(spacing: 3) {
                                            Circle()
                                                .fill(Color.blue)
                                                .frame(width: 6, height: 6)
                                            Text(String(format: "%.1f km", data.distanceKm))
                                                .font(.caption)
                                                .fontWeight(.semibold)
                                                .foregroundColor(.blue)
                                        }
                                        HStack(spacing: 3) {
                                            Circle()
                                                .fill(Color.orange)
                                                .frame(width: 6, height: 6)
                                            Text(String(format: "%.1f km", data.cumulativeKm))
                                                .font(.caption)
                                                .fontWeight(.semibold)
                                                .foregroundColor(.orange)
                                        }
                                    }
                                }
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(.systemBackground))
                                        .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 2)
                                )
                            }
                    }
                }
                .chartYScale(domain: 0...maxY)
                .chartXScale(domain: 1...analytics.daysInSelectedMonth)
                .chartXAxis {
                    AxisMarks(values: .stride(by: 5)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                            .foregroundStyle(.gray.opacity(0.3))
                        AxisValueLabel {
                            if let day = value.as(Int.self) {
                                Text("\(day)")
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                            .foregroundStyle(.gray.opacity(0.3))
                        AxisValueLabel {
                            if let km = value.as(Double.self) {
                                Text(String(format: "%.0f", km))
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { _ in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        let x = value.location.x
                                        if let day: Int = proxy.value(atX: x) {
                                            selectedDay = max(1, min(day, analytics.daysInSelectedMonth))
                                        }
                                    }
                                    .onEnded { _ in
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                            withAnimation { selectedDay = nil }
                                        }
                                    }
                            )
                    }
                }
                .frame(height: chartHeight)
                .animation(.easeInOut(duration: 0.3), value: analytics.dailyDistances.count)

                // Legend
                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.blue.opacity(0.5))
                            .frame(width: isIPad ? 14 : 12, height: isIPad ? 14 : 12)
                        Text("Daily")
                            .font(isIPad ? .caption : .caption2)
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: isIPad ? 10 : 8, height: isIPad ? 10 : 8)
                        Text("Cumulative")
                            .font(isIPad ? .caption : .caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text("km")
                        .font(isIPad ? .caption : .caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(isIPad ? 20 : 16)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .shadow(color: AppTheme.shadowColor, radius: AppTheme.shadowRadius, x: 0, y: AppTheme.shadowY)
    }
}
