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

struct AllTimeDistanceChartView: View {
    @ObservedObject var analytics: WorkoutAnalyticsManager
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selectedMonth: Date? = nil

    private var isIPad: Bool { sizeClass == .regular }
    private var chartHeight: CGFloat { isIPad ? 360 : 240 }

    private var selectedData: AnalyticsAllTimeMonthlyDistance? {
        guard let selectedMonth else { return nil }
        return analytics.allTimeMonthlyDistances.first {
            Calendar.current.isDate($0.monthStart, equalTo: selectedMonth, toGranularity: .month)
        }
    }

    private var firstMonth: Date {
        analytics.allTimeMonthlyDistances.first?.monthStart ?? Date()
    }

    private var currentMonth: Date {
        analytics.allTimeMonthlyDistances.last?.monthStart ?? Date()
    }

    private var visibleBarData: [AnalyticsAllTimeMonthlyDistance] {
        let nonZero = analytics.allTimeMonthlyDistances.filter { $0.distance > 0 }
        guard nonZero.count > 90 else { return analytics.allTimeMonthlyDistances }

        let strideSize = max(1, analytics.allTimeMonthlyDistances.count / 90)
        var sampled = analytics.allTimeMonthlyDistances.enumerated().compactMap { index, data in
            data.distance > 0 || index % strideSize == 0 ? data : nil
        }

        if let last = analytics.allTimeMonthlyDistances.last,
           sampled.last?.monthStart != last.monthStart {
            sampled.append(last)
        }
        return sampled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isIPad ? 16 : 12) {
            HStack {
                Text("\(analytics.allTimeRangeTitle) Distance")
                    .font(isIPad ? .title3 : .headline)
                Spacer()
                Text(String(format: "%.0f km", analytics.allTimeTotalKm))
                    .font(isIPad ? .headline : .subheadline)
                    .foregroundColor(.secondary)
            }

            if analytics.allTimeMonthlyDistances.isEmpty {
                Text("No data for \(analytics.allTimeRangeTitle)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: chartHeight)
            } else {
                let maxMonthly = analytics.allTimeMonthlyDistances.map(\.distanceKm).max() ?? 1
                let maxCumulative = analytics.allTimeMonthlyDistances.last?.cumulativeKm ?? 1
                let maxY = max(maxMonthly * 1.15, maxCumulative * 1.15, 1)

                Chart {
                    ForEach(visibleBarData) { data in
                        BarMark(
                            x: .value("Month", data.monthStart, unit: .month),
                            y: .value("Distance", data.distanceKm)
                        )
                        .foregroundStyle(
                            selectedMonth.map { Calendar.current.isDate(data.monthStart, equalTo: $0, toGranularity: .month) } == true
                            ? Color.blue.opacity(0.85)
                            : Color.blue.opacity(0.4)
                        )
                        .cornerRadius(3)
                    }

                    ForEach(analytics.allTimeMonthlyDistances) { data in
                        LineMark(
                            x: .value("Month", data.monthStart, unit: .month),
                            y: .value("Cumulative", data.cumulativeKm)
                        )
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .interpolationMethod(.catmullRom)
                    }

                    if let selectedMonth, let data = selectedData {
                        RuleMark(x: .value("Selected", selectedMonth))
                            .foregroundStyle(.gray.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 3]))
                            .annotation(position: .top, alignment: .center, spacing: 4) {
                                VStack(spacing: 4) {
                                    Text(data.monthLabel)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text(String(format: "%.0f km / %.0f km", data.distanceKm, data.cumulativeKm))
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.primary)
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
                .chartXScale(domain: firstMonth...currentMonth)
                .chartYScale(domain: 0...maxY)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: analytics.allTimeYearFilter == nil ? min(max(analytics.allTimeYearlyDistances.count, 2), 8) : 6)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                            .foregroundStyle(.gray.opacity(0.3))
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(date, format: analytics.allTimeYearFilter == nil ? .dateTime.year() : .dateTime.month(.abbreviated))
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
                                        if let date: Date = proxy.value(atX: value.location.x) {
                                            selectedMonth = nearestMonth(to: date)
                                        }
                                    }
                                    .onEnded { _ in
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                            withAnimation { selectedMonth = nil }
                                        }
                                    }
                            )
                    }
                }
                .frame(height: chartHeight)

                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.blue.opacity(0.5))
                            .frame(width: isIPad ? 14 : 12, height: isIPad ? 14 : 12)
                        Text("Monthly")
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
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(isIPad ? 20 : 16)
    }

    private func nearestMonth(to date: Date) -> Date? {
        analytics.allTimeMonthlyDistances.min {
            abs($0.monthStart.timeIntervalSince(date)) < abs($1.monthStart.timeIntervalSince(date))
        }?.monthStart
    }
}
