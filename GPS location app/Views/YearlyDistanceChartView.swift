//
//  YearlyDistanceChartView.swift
//  GPS location app
//
//  Created by Claude on 2/26/26.
//

import SwiftUI
import Charts

struct YearlyDistanceChartView: View {
    @ObservedObject var analytics: WorkoutAnalyticsManager
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selectedMonthInChart: String? = nil

    private var isIPad: Bool { sizeClass == .regular }
    private var chartHeight: CGFloat { isIPad ? 300 : 200 }

    var body: some View {
        VStack(alignment: .leading, spacing: isIPad ? 16 : 12) {
            // Header
            HStack {
                Text("Monthly Distance")
                    .font(isIPad ? .title3 : .headline)
                Spacer()
                if analytics.yearOverYearChange != 0 {
                    HStack(spacing: 3) {
                        Image(systemName: analytics.yearOverYearChange >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.caption)
                        Text(String(format: "%.0f%% YoY", abs(analytics.yearOverYearChange)))
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .foregroundColor(analytics.yearOverYearChange >= 0 ? .green : .orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        (analytics.yearOverYearChange >= 0 ? Color.green : Color.orange)
                            .opacity(0.12)
                    )
                    .cornerRadius(8)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%.0f", analytics.yearTotalKm))
                    .font(.system(isIPad ? .title : .title2, design: .rounded))
                    .fontWeight(.bold)
                Text("km in \(String(analytics.selectedYear))")
                    .font(isIPad ? .body : .subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                if analytics.lastYearTotalKm > 0 {
                    Text(String(format: "Last yr: %.0f km", analytics.lastYearTotalKm))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if analytics.yearlyDistances.isEmpty {
                Text("No data for this year")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: chartHeight)
            } else {
                Chart {
                    ForEach(analytics.yearlyDistances) { data in
                        BarMark(
                            x: .value("Month", data.monthName),
                            y: .value("Distance", data.distanceKm)
                        )
                        .foregroundStyle(
                            data.month == analytics.selectedMonth
                            ? LinearGradient(
                                colors: [Color.blue, Color.blue.opacity(0.7)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            : LinearGradient(
                                colors: [Color.cyan, Color.cyan.opacity(0.5)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .cornerRadius(4)
                        .annotation(position: .top, spacing: 4) {
                            if data.distanceKm > 0 {
                                Text(String(format: "%.0f", data.distanceKm))
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    // Selection rule
                    if let selected = selectedMonthInChart {
                        RuleMark(x: .value("Selected", selected))
                            .foregroundStyle(.gray.opacity(0.3))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 2]))
                    }
                }
                .chartXAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let name = value.as(String.self) {
                                Text(name)
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
                            .onTapGesture { location in
                                if let monthName: String = proxy.value(atX: location.x),
                                   let monthData = analytics.yearlyDistances.first(where: { $0.monthName == monthName }) {
                                    selectedMonthInChart = monthName
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        analytics.selectedMonth = monthData.month
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                        withAnimation { selectedMonthInChart = nil }
                                    }
                                }
                            }
                    }
                }
                .frame(height: chartHeight)
                .animation(.easeInOut(duration: 0.3), value: analytics.yearlyDistances.count)
            }
        }
        .padding(isIPad ? 20 : 16)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(isIPad ? 20 : 16)
    }
}
