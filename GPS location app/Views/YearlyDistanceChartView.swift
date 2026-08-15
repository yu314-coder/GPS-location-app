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
        .background(
            RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .shadow(color: AppTheme.shadowColor, radius: AppTheme.shadowRadius, x: 0, y: AppTheme.shadowY)
    }
}

struct AllTimeDistanceChartView: View {
    @ObservedObject var analytics: WorkoutAnalyticsManager
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selectedMonth: Date? = nil
    @State private var selectedYearChartMode: SelectedYearChartMode = .daily
    @State private var fullAllTimeChartMode: FullAllTimeChartMode = .monthly

    private var isIPad: Bool { sizeClass == .regular }
    private var chartHeight: CGFloat { isIPad ? 360 : 240 }
    private var isYearFiltered: Bool { analytics.allTimeYearFilter != nil }

    private var selectedData: AnalyticsAllTimeMonthlyDistance? {
        guard let selectedMonth else { return nil }
        return analytics.allTimeMonthlyDistances.first {
            Calendar.current.isDate($0.monthStart, equalTo: selectedMonth, toGranularity: .month)
        }
    }

    private var selectedDailyData: AnalyticsAllTimeDailyDistance? {
        guard let selectedMonth else { return nil }
        return analytics.allTimeDailyDistances.first {
            Calendar.current.isDate($0.dayStart, equalTo: selectedMonth, toGranularity: .day)
        }
    }

    private var firstMonth: Date {
        analytics.allTimeMonthlyDistances.first?.monthStart ?? Date()
    }

    private var currentMonth: Date {
        analytics.allTimeMonthlyDistances.last?.monthStart ?? Date()
    }

    private var firstDay: Date {
        analytics.allTimeDailyDistances.first?.dayStart ?? Date()
    }

    private var currentDay: Date {
        analytics.allTimeDailyDistances.last?.dayStart ?? Date()
    }

    private var nonZeroDays: [AnalyticsAllTimeDailyDistance] {
        analytics.allTimeDailyDistances.filter { $0.distance > 0 }
    }

    private var bestDay: AnalyticsAllTimeDailyDistance? {
        nonZeroDays.max { $0.distanceKm < $1.distanceKm }
    }

    private var averageActiveDayKm: Double {
        guard !nonZeroDays.isEmpty else { return 0 }
        return nonZeroDays.map(\.distanceKm).reduce(0, +) / Double(nonZeroDays.count)
    }

    private var nonZeroMonths: [AnalyticsAllTimeMonthlyDistance] {
        analytics.allTimeMonthlyDistances.filter { $0.distance > 0 }
    }

    private var bestMonth: AnalyticsAllTimeMonthlyDistance? {
        nonZeroMonths.max { $0.distanceKm < $1.distanceKm }
    }

    private var averageActiveMonthKm: Double {
        guard !nonZeroMonths.isEmpty else { return 0 }
        return nonZeroMonths.map(\.distanceKm).reduce(0, +) / Double(nonZeroMonths.count)
    }

    private enum SelectedYearChartMode: String, CaseIterable, Identifiable {
        case daily = "Daily"
        case cumulative = "Cumulative"

        var id: String { rawValue }

        var legendTitle: String {
            switch self {
            case .daily: return "Daily distance"
            case .cumulative: return "Cumulative distance"
            }
        }

        var color: Color {
            switch self {
            case .daily: return .blue
            case .cumulative: return .orange
            }
        }
    }

    private enum FullAllTimeChartMode: String, CaseIterable, Identifiable {
        case monthly = "Monthly"
        case cumulative = "Cumulative"

        var id: String { rawValue }

        var legendTitle: String {
            switch self {
            case .monthly: return "Monthly distance"
            case .cumulative: return "Cumulative distance"
            }
        }

        var color: Color {
            switch self {
            case .monthly: return .blue
            case .cumulative: return .orange
            }
        }
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

            if isYearFiltered {
                HStack(spacing: 10) {
                    selectedYearStat("Best Day", value: bestDay.map { String(format: "%.1f km", $0.distanceKm) } ?? "0 km")
                    selectedYearStat("Avg Active", value: String(format: "%.1f km", averageActiveDayKm))
                    selectedYearStat("Days", value: "\(nonZeroDays.count)")
                }

                Picker("Chart Mode", selection: $selectedYearChartMode) {
                    ForEach(SelectedYearChartMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if let selectedDailyData {
                    selectedDayPanel(for: selectedDailyData)
                }
            } else {
                HStack(spacing: 10) {
                    selectedYearStat("Best Month", value: bestMonth.map { String(format: "%.0f km", $0.distanceKm) } ?? "0 km")
                    selectedYearStat("Avg Active", value: String(format: "%.0f km", averageActiveMonthKm))
                    selectedYearStat("Months", value: "\(nonZeroMonths.count)")
                }

                Picker("Chart Mode", selection: $fullAllTimeChartMode) {
                    ForEach(FullAllTimeChartMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if let selectedData {
                    selectedMonthPanel(for: selectedData)
                }
            }

            if (isYearFiltered && analytics.allTimeDailyDistances.isEmpty) ||
                (!isYearFiltered && analytics.allTimeMonthlyDistances.isEmpty) {
                Text("No data for \(analytics.allTimeRangeTitle)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: chartHeight)
            } else if isYearFiltered {
                let maxSelectedValue = analytics.allTimeDailyDistances.map { selectedYearValueKm(for: $0) }.max() ?? 0
                let maxY = max(maxSelectedValue * 1.25, 1)
                let chartColor = selectedYearChartMode.color

                Chart {
                    ForEach(analytics.allTimeDailyDistances) { data in
                        AreaMark(
                            x: .value("Day", data.dayStart, unit: .day),
                            y: .value(selectedYearChartMode.rawValue, selectedYearValueKm(for: data))
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [chartColor.opacity(0.28), chartColor.opacity(0.03)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        LineMark(
                            x: .value("Day", data.dayStart, unit: .day),
                            y: .value(selectedYearChartMode.rawValue, selectedYearValueKm(for: data))
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(chartColor)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                        if data.distance > 0 ||
                            selectedMonth.map({ Calendar.current.isDate(data.dayStart, equalTo: $0, toGranularity: .day) }) == true {
                            PointMark(
                                x: .value("Day", data.dayStart, unit: .day),
                                y: .value(selectedYearChartMode.rawValue, selectedYearValueKm(for: data))
                            )
                            .foregroundStyle(
                                selectedMonth.map { Calendar.current.isDate(data.dayStart, equalTo: $0, toGranularity: .day) } == true
                                ? Color.orange
                                : chartColor
                            )
                            .symbolSize(
                                selectedMonth.map { Calendar.current.isDate(data.dayStart, equalTo: $0, toGranularity: .day) } == true
                                ? 90
                                : 18
                            )
                        }
                    }

                    if let selectedMonth, selectedDailyData != nil {
                        RuleMark(x: .value("Selected", selectedMonth))
                            .foregroundStyle(Color(.label).opacity(0.24))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    }
                }
                .chartXScale(domain: firstDay...currentDay)
                .chartYScale(domain: 0...maxY)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month, count: 1)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color(.separator).opacity(0.16))
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(date, format: .dateTime.month(.abbreviated))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6))
                            .foregroundStyle(Color(.separator).opacity(0.22))
                        AxisTick(stroke: StrokeStyle(lineWidth: 0.6))
                            .foregroundStyle(Color(.separator).opacity(0.45))
                        AxisValueLabel {
                            if let km = value.as(Double.self) {
                                Text(String(format: "%.0f", km))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .chartPlotStyle { plotArea in
                    plotArea
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(.separator).opacity(0.18), lineWidth: 1)
                        )
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
                                            selectedMonth = nearestDay(to: date)
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

                HStack(spacing: 8) {
                    Circle()
                        .fill(selectedYearChartMode.color)
                        .frame(width: isIPad ? 10 : 8, height: isIPad ? 10 : 8)
                    Text(selectedYearChartMode.legendTitle)
                        .font(isIPad ? .caption : .caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("km")
                        .font(isIPad ? .caption : .caption2)
                        .foregroundColor(.secondary)
                }
            } else {
                let maxSelectedValue = analytics.allTimeMonthlyDistances.map { fullAllTimeValueKm(for: $0) }.max() ?? 1
                let maxY = max(maxSelectedValue * 1.15, 1)
                let chartColor = fullAllTimeChartMode.color

                Chart {
                    ForEach(analytics.allTimeMonthlyDistances) { data in
                        AreaMark(
                            x: .value("Month", data.monthStart, unit: .month),
                            y: .value(fullAllTimeChartMode.rawValue, fullAllTimeValueKm(for: data))
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [chartColor.opacity(0.26), chartColor.opacity(0.03)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        LineMark(
                            x: .value("Month", data.monthStart, unit: .month),
                            y: .value(fullAllTimeChartMode.rawValue, fullAllTimeValueKm(for: data))
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(chartColor)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                        if data.distance > 0 ||
                            selectedMonth.map({ Calendar.current.isDate(data.monthStart, equalTo: $0, toGranularity: .month) }) == true {
                            PointMark(
                                x: .value("Month", data.monthStart, unit: .month),
                                y: .value(fullAllTimeChartMode.rawValue, fullAllTimeValueKm(for: data))
                            )
                            .foregroundStyle(
                                selectedMonth.map { Calendar.current.isDate(data.monthStart, equalTo: $0, toGranularity: .month) } == true
                                ? Color.orange
                                : chartColor
                            )
                            .symbolSize(
                                selectedMonth.map { Calendar.current.isDate(data.monthStart, equalTo: $0, toGranularity: .month) } == true
                                ? 90
                                : 18
                            )
                        }
                    }

                    if let selectedMonth, selectedData != nil {
                        RuleMark(x: .value("Selected", selectedMonth))
                            .foregroundStyle(Color(.label).opacity(0.24))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    }
                }
                .chartXScale(domain: firstMonth...currentMonth)
                .chartYScale(domain: 0...maxY)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: analytics.allTimeYearFilter == nil ? min(max(analytics.allTimeYearlyDistances.count, 2), 8) : 6)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color(.separator).opacity(0.16))
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(date, format: .dateTime.year())
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6))
                            .foregroundStyle(Color(.separator).opacity(0.22))
                        AxisTick(stroke: StrokeStyle(lineWidth: 0.6))
                            .foregroundStyle(Color(.separator).opacity(0.45))
                        AxisValueLabel {
                            if let km = value.as(Double.self) {
                                Text(String(format: "%.0f", km))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .chartPlotStyle { plotArea in
                    plotArea
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(.separator).opacity(0.18), lineWidth: 1)
                        )
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

                HStack(spacing: 8) {
                    Circle()
                        .fill(fullAllTimeChartMode.color)
                        .frame(width: isIPad ? 10 : 8, height: isIPad ? 10 : 8)
                    Text(fullAllTimeChartMode.legendTitle)
                        .font(isIPad ? .caption : .caption2)
                        .foregroundColor(.secondary)
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

    private func nearestMonth(to date: Date) -> Date? {
        analytics.allTimeMonthlyDistances.min {
            abs($0.monthStart.timeIntervalSince(date)) < abs($1.monthStart.timeIntervalSince(date))
        }?.monthStart
    }

    private func nearestDay(to date: Date) -> Date? {
        analytics.allTimeDailyDistances.min {
            abs($0.dayStart.timeIntervalSince(date)) < abs($1.dayStart.timeIntervalSince(date))
        }?.dayStart
    }

    private func selectedYearValueKm(for data: AnalyticsAllTimeDailyDistance) -> Double {
        switch selectedYearChartMode {
        case .daily:
            return data.distanceKm
        case .cumulative:
            return data.cumulativeKm
        }
    }

    private func fullAllTimeValueKm(for data: AnalyticsAllTimeMonthlyDistance) -> Double {
        switch fullAllTimeChartMode {
        case .monthly:
            return data.distanceKm
        case .cumulative:
            return data.cumulativeKm
        }
    }

    private func selectedDayPanel(for data: AnalyticsAllTimeDailyDistance) -> some View {
        let primaryValue = String(format: "%.1f km", selectedYearValueKm(for: data))
        let secondaryValue: String
        switch selectedYearChartMode {
        case .daily:
            secondaryValue = String(format: "%.1f km total", data.cumulativeKm)
        case .cumulative:
            secondaryValue = String(format: "%.1f km on day", data.distanceKm)
        }

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(data.dayLabel)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                Text(secondaryValue)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            Text(primaryValue)
                .font(isIPad ? .headline : .subheadline)
                .fontWeight(.bold)
                .foregroundColor(selectedYearChartMode.color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(selectedYearChartMode.color.opacity(0.24), lineWidth: 1)
        )
    }

    private func selectedMonthPanel(for data: AnalyticsAllTimeMonthlyDistance) -> some View {
        let primaryValue = String(format: "%.0f km", fullAllTimeValueKm(for: data))
        let secondaryValue: String
        switch fullAllTimeChartMode {
        case .monthly:
            secondaryValue = String(format: "%.0f km total", data.cumulativeKm)
        case .cumulative:
            secondaryValue = String(format: "%.0f km in month", data.distanceKm)
        }

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(data.monthLabel)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                Text(secondaryValue)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            Text(primaryValue)
                .font(isIPad ? .headline : .subheadline)
                .fontWeight(.bold)
                .foregroundColor(fullAllTimeChartMode.color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(fullAllTimeChartMode.color.opacity(0.24), lineWidth: 1)
        )
    }

    private func selectedYearStat(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(isIPad ? .subheadline : .caption)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(.separator).opacity(0.18), lineWidth: 1)
        )
    }
}
