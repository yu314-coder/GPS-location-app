//
//  AnalysisComponents.swift
//  GPS location app
//
//  Created by Claude on 2/26/26.
//

import SwiftUI

// MARK: - Month Chip

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
        Button(action: action) {
            Text(monthName)
                .font(.subheadline)
                .fontWeight(isSelected ? .bold : .medium)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isSelected ? Color.blue : Color(.secondarySystemGroupedBackground))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(20)
        }
    }
}

// MARK: - Stat Card

struct AnalysisStatCard: View {
    let title: String
    let value: String
    let color: Color
    var isIPad: Bool = false

    var body: some View {
        VStack(spacing: isIPad ? 10 : 8) {
            Text(title)
                .font(isIPad ? .subheadline : .caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(isIPad ? .title2 : .title3)
                .fontWeight(.bold)
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, isIPad ? 18 : 14)
        .padding(.horizontal, isIPad ? 12 : 8)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(isIPad ? 16 : 12)
    }
}

// MARK: - Year Chip

struct YearChip: View {
    let year: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(String(year))
                .font(.subheadline)
                .fontWeight(isSelected ? .bold : .medium)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isSelected ? Color.cyan : Color(.secondarySystemGroupedBackground))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(20)
        }
    }
}

// MARK: - All Time Chip

struct AllTimeChip: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                Text("All Time")
            }
            .font(.subheadline)
            .fontWeight(isSelected ? .bold : .medium)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isSelected ? Color.cyan : Color(.secondarySystemGroupedBackground))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(20)
        }
    }
}

// MARK: - All Time Range Chip

struct AllTimeRangeChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .fontWeight(isSelected ? .bold : .medium)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(isSelected ? Color.blue : Color(.tertiarySystemGroupedBackground))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(16)
        }
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
        VStack(spacing: 12) {
            // Year picker
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    AllTimeChip(isSelected: analytics.isAllTimeSelected) {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            analytics.isAllTimeSelected = true
                            analytics.allTimeYearFilter = nil
                        }
                    }

                    ForEach(availableYears, id: \.self) { year in
                        YearChip(
                            year: year,
                            isSelected: !analytics.isAllTimeSelected && analytics.selectedYear == year
                        ) {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                analytics.isAllTimeSelected = false
                                analytics.selectedYear = year
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }

            if analytics.isAllTimeSelected {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        AllTimeRangeChip(
                            title: "All",
                            isSelected: analytics.allTimeYearFilter == nil
                        ) {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                analytics.allTimeYearFilter = nil
                            }
                        }

                        ForEach(availableYears, id: \.self) { year in
                            AllTimeRangeChip(
                                title: String(year),
                                isSelected: analytics.allTimeYearFilter == year
                            ) {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    analytics.allTimeYearFilter = year
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } else {
                // Month picker - horizontal scroll
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(1...12, id: \.self) { month in
                            MonthChip(
                                month: month,
                                isSelected: analytics.selectedMonth == month
                            ) {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    analytics.selectedMonth = month
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }

            // Activity filter
            Picker("Activity", selection: $analytics.activityFilter) {
                ForEach(AnalyticsActivityFilter.allCases, id: \.self) { filter in
                    Label(filter.rawValue, systemImage: filter.icon).tag(filter)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

// MARK: - Summary Stats Section

struct SummaryStatsSection: View {
    @ObservedObject var analytics: WorkoutAnalyticsManager
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var isIPad: Bool { sizeClass == .regular }

    private var monthCard: some View {
        AnalysisStatCard(
            title: analytics.monthName,
            value: String(format: "%.1f km", analytics.monthTotalKm),
            color: .blue,
            isIPad: isIPad
        )
    }

    private var monthCompareCard: some View {
        AnalysisStatCard(
            title: "vs \(analytics.monthName) \(analytics.selectedYear - 1)",
            value: analytics.lastYearSameMonthTotalKm > 0
                ? String(format: "%+.0f%%", analytics.monthOverMonthChange)
                : "—",
            color: analytics.monthOverMonthChange >= 0 ? .green : .orange,
            isIPad: isIPad
        )
    }

    private var yearCard: some View {
        AnalysisStatCard(
            title: "\(analytics.selectedYear) Total",
            value: String(format: "%.0f km", analytics.yearTotalKm),
            color: .cyan,
            isIPad: isIPad
        )
    }

    private var yearCompareCard: some View {
        AnalysisStatCard(
            title: "vs \(analytics.selectedYear - 1)",
            value: analytics.lastYearTotalKm > 0
                ? String(format: "%+.0f%%", analytics.yearOverYearChange)
                : "—",
            color: analytics.yearOverYearChange >= 0 ? .green : .orange,
            isIPad: isIPad
        )
    }

    private var allTimeCard: some View {
        AnalysisStatCard(
            title: analytics.allTimeRangeTitle,
            value: String(format: "%.0f km", analytics.allTimeTotalKm),
            color: .blue,
            isIPad: isIPad
        )
    }

    private var allTimeWorkoutCard: some View {
        AnalysisStatCard(
            title: "Workouts",
            value: "\(analytics.allTimeWorkoutCount)",
            color: .green,
            isIPad: isIPad
        )
    }

    private var allTimeBestYearCard: some View {
        AnalysisStatCard(
            title: "Best Year",
            value: String(format: "%.0f km", analytics.allTimeBestYearKm),
            color: .cyan,
            isIPad: isIPad
        )
    }

    private var allTimeAverageCard: some View {
        AnalysisStatCard(
            title: "Avg / Year",
            value: String(format: "%.0f km", analytics.allTimeAverageYearKm),
            color: .orange,
            isIPad: isIPad
        )
    }

    var body: some View {
        if analytics.isAllTimeSelected {
            if isIPad {
                HStack(spacing: 12) {
                    allTimeCard
                    allTimeWorkoutCard
                    allTimeBestYearCard
                    allTimeAverageCard
                }
            } else {
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        allTimeCard
                        allTimeWorkoutCard
                    }
                    HStack(spacing: 12) {
                        allTimeBestYearCard
                        allTimeAverageCard
                    }
                }
            }
        } else if isIPad {
            // iPad: all 4 cards in a single row
            HStack(spacing: 12) {
                monthCard
                monthCompareCard
                yearCard
                yearCompareCard
            }
        } else {
            // iPhone: 2x2 grid
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    monthCard
                    monthCompareCard
                }
                HStack(spacing: 12) {
                    yearCard
                    yearCompareCard
                }
            }
        }
    }
}
