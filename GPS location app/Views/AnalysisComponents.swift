//
//  AnalysisComponents.swift
//  GPS location app
//
//  Created by Claude on 2/26/26.
//
//  Rebuilt on the shared design system. There were four chip types here that differed only in
//  tint and corner radius (20, 20, 20, 16) and a stat card with its own padding scale, so the
//  filter row read as three separate control strips stacked on top of each other. They are all
//  AppChip now, and the stats sit in one card instead of floating as eight loose tiles.
//

import SwiftUI

// MARK: - Chips

struct MonthChip: View {
    let month: Int
    let isSelected: Bool
    let action: () -> Void

    private var monthName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        let date = Calendar.current.date(from: DateComponents(month: month))!
        return formatter.string(from: date)
    }

    var body: some View {
        AppChip(title: monthName, isSelected: isSelected, tint: AppTheme.distance, action: action)
    }
}

struct YearChip: View {
    let year: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        AppChip(title: String(year), isSelected: isSelected, tint: .cyan, action: action)
    }
}

struct AllTimeChip: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        AppChip(title: "All Time", icon: "clock.arrow.circlepath",
                isSelected: isSelected, tint: .cyan, action: action)
    }
}

struct AllTimeRangeChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        AppChip(title: title, isSelected: isSelected, tint: AppTheme.distance, action: action)
    }
}

// MARK: - Stat card

struct AnalysisStatCard: View {
    let title: String
    let value: String
    let color: Color
    var icon: String = "chart.bar.fill"
    var isIPad: Bool = false

    var body: some View {
        MetricTile(icon: icon, value: value, label: title, tint: color, compact: !isIPad)
    }
}

// MARK: - Month/Year/Activity Picker Section

struct MonthActivityPickerSection: View {
    @ObservedObject var analytics: WorkoutAnalyticsManager

    private var availableYears: [Int] {
        let currentYear = Calendar.current.component(.year, from: Date())
        return Array((currentYear - 10)...currentYear).reversed()
    }

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                // Year / all-time
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        AllTimeChip(isSelected: analytics.isAllTimeSelected) {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                analytics.isAllTimeSelected = true
                                analytics.allTimeYearFilter = nil
                            }
                        }

                        ForEach(availableYears, id: \.self) { year in
                            YearChip(
                                year: year,
                                isSelected: !analytics.isAllTimeSelected && analytics.selectedYear == year
                            ) {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    analytics.isAllTimeSelected = false
                                    analytics.selectedYear = year
                                }
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }

                Divider()

                if analytics.isAllTimeSelected {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            AllTimeRangeChip(title: "All", isSelected: analytics.allTimeYearFilter == nil) {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    analytics.allTimeYearFilter = nil
                                }
                            }

                            ForEach(availableYears, id: \.self) { year in
                                AllTimeRangeChip(
                                    title: String(year),
                                    isSelected: analytics.allTimeYearFilter == year
                                ) {
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        analytics.allTimeYearFilter = year
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 1)
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(1...12, id: \.self) { month in
                                MonthChip(month: month, isSelected: analytics.selectedMonth == month) {
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        analytics.selectedMonth = month
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }

                Picker("Activity", selection: $analytics.activityFilter) {
                    ForEach(AnalyticsActivityFilter.allCases, id: \.self) { filter in
                        Label(filter.rawValue, systemImage: filter.icon).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }
}

// MARK: - Summary Stats Section

struct SummaryStatsSection: View {
    @ObservedObject var analytics: WorkoutAnalyticsManager
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var isIPad: Bool { sizeClass == .regular }

    /// The headline for whichever range is selected, shown full width above the smaller tiles.
    /// Four equal cards gave the total no more weight than the "vs last year" percentage next to
    /// it, so the number people actually come here for did not read as the answer.
    private var headline: (title: String, value: String, tint: Color) {
        if analytics.isAllTimeSelected {
            return (analytics.allTimeRangeTitle,
                    String(format: "%.0f km", analytics.allTimeTotalKm), AppTheme.distance)
        }
        return (analytics.monthName,
                String(format: "%.1f km", analytics.monthTotalKm), AppTheme.distance)
    }

    private var tiles: [(String, String, String, Color)] {
        if analytics.isAllTimeSelected {
            return [
                ("figure.run", "\(analytics.allTimeWorkoutCount)", "Workouts", AppTheme.count),
                ("trophy.fill", String(format: "%.0f km", analytics.allTimeBestYearKm), "Best Year", .cyan),
                ("chart.bar.fill", String(format: "%.0f km", analytics.allTimeAverageYearKm), "Avg / Year", AppTheme.pace)
            ]
        }
        return [
            ("calendar", String(format: "%.0f km", analytics.yearTotalKm), "\(analytics.selectedYear)", .cyan),
            ("arrow.left.arrow.right",
             analytics.lastYearTotalKm > 0 ? String(format: "%+.0f%%", analytics.yearOverYearChange) : "—",
             "vs \(analytics.selectedYear - 1)",
             analytics.yearOverYearChange >= 0 ? AppTheme.count : AppTheme.pace)
        ]
    }

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(headline.title.uppercased())
                            .font(.caption2).fontWeight(.semibold).tracking(0.5)
                            .foregroundStyle(.secondary)
                        Text(headline.value)
                            .font(.system(size: isIPad ? 42 : 36, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(headline.tint)
                            .lineLimit(1).minimumScaleFactor(0.5)
                    }
                    Spacer(minLength: 8)
                    if !analytics.isAllTimeSelected {
                        TrendBadge(change: analytics.monthOverMonthChange,
                                   hasBaseline: analytics.lastYearSameMonthTotalKm > 0)
                    }
                }

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10),
                                   count: min(tiles.count, isIPad ? 3 : 2)),
                    spacing: 10
                ) {
                    ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                        MetricTile(icon: tile.0, value: tile.1, label: tile.2,
                                   tint: tile.3, compact: true)
                    }
                }
            }
        }
    }
}
