//
//  WorkoutWidget.swift
//  WorkoutWidget
//
//  GPS location app
//

#if !os(watchOS)
import WidgetKit
import SwiftUI
import HealthKit
import Charts
import AppIntents

// MARK: - HealthKit Manager for Widget

class WidgetHealthKitManager {
    static let shared = WidgetHealthKitManager()
    private let healthStore = HKHealthStore()

    func fetchWorkoutStats(activityFilter: ActivityFilter, month: Int? = nil, year: Int? = nil, completion: @escaping (WorkoutStats) -> Void) {
        let calendar = Calendar.current
        let now = Date()
        let targetYear = year ?? calendar.component(.year, from: now)
        let targetMonth = month ?? calendar.component(.month, from: now)
        let currentActualMonth = calendar.component(.month, from: now)
        let currentActualYear = calendar.component(.year, from: now)
        let isCurrentMonth = (targetMonth == currentActualMonth && targetYear == currentActualYear)

        // Check if HealthKit is available
        guard HKHealthStore.isHealthDataAvailable() else {
            print("Widget: HealthKit not available on this device")
            completion(WorkoutStats())
            return
        }

        // Check authorization status
        let workoutType = HKObjectType.workoutType()
        let authStatus = healthStore.authorizationStatus(for: workoutType)

        guard authStatus == .sharingAuthorized else {
            print("Widget: HealthKit not authorized. Please open the main app.")
            completion(WorkoutStats())
            return
        }

        // Fetch stats in parallel
        let group = DispatchGroup()

        var monthlyData: [DailyDistance] = []
        var yearlyData: [MonthlyDistance] = []
        var lastYearTotal: Double = 0
        var twoYearsAgoTotal: Double = 0
        var lastYearSameMonthTotal: Double = 0

        // Selected month daily data
        group.enter()
        let monthStart = calendar.date(from: DateComponents(year: targetYear, month: targetMonth, day: 1))!
        let monthEnd: Date
        if isCurrentMonth {
            monthEnd = now
        } else {
            let nextMonthStart = calendar.date(from: DateComponents(year: targetYear, month: targetMonth + 1, day: 1))!
            monthEnd = nextMonthStart.addingTimeInterval(-1)
        }
        self.fetchDailyDistances(from: monthStart, to: monthEnd, isCurrentMonth: isCurrentMonth, activityFilter: activityFilter) { data in
            monthlyData = data
            group.leave()
        }

        // Current year monthly data
        group.enter()
        let yearStart = calendar.date(from: DateComponents(year: targetYear))!
        let yearEnd = (targetYear == currentActualYear) ? now : calendar.date(from: DateComponents(year: targetYear + 1))!.addingTimeInterval(-1)
        self.fetchMonthlyDistances(from: yearStart, to: yearEnd, activityFilter: activityFilter) { data in
            yearlyData = data
            group.leave()
        }

        // Last year total (whole year)
        group.enter()
        let lastYearStart = calendar.date(from: DateComponents(year: targetYear - 1))!
        let lastYearEnd = calendar.date(byAdding: .second, value: -1, to: yearStart)!
        self.fetchTotalDistance(from: lastYearStart, to: lastYearEnd, activityFilter: activityFilter) { distance in
            lastYearTotal = distance
            group.leave()
        }

        // Same month last year (for month-over-month comparison)
        group.enter()
        let sameMonthLastYearStart = calendar.date(from: DateComponents(year: targetYear - 1, month: targetMonth, day: 1))!
        let sameMonthLastYearEnd = calendar.date(from: DateComponents(year: targetYear - 1, month: targetMonth + 1, day: 1))!.addingTimeInterval(-1)
        self.fetchTotalDistance(from: sameMonthLastYearStart, to: sameMonthLastYearEnd, activityFilter: activityFilter) { distance in
            lastYearSameMonthTotal = distance
            group.leave()
        }

        // Two years ago total
        group.enter()
        let twoYearsStart = calendar.date(from: DateComponents(year: targetYear - 2))!
        let twoYearsEnd = calendar.date(byAdding: .second, value: -1, to: lastYearStart)!
        self.fetchTotalDistance(from: twoYearsStart, to: twoYearsEnd, activityFilter: activityFilter) { distance in
            twoYearsAgoTotal = distance
            group.leave()
        }

        group.notify(queue: .main) {
            let stats = WorkoutStats(
                monthName: self.getMonthName(for: targetMonth),
                currentYear: targetYear,
                selectedMonth: targetMonth,
                dailyDistances: monthlyData,
                yearlyDistances: yearlyData,
                lastYearTotal: lastYearTotal,
                twoYearsAgoTotal: twoYearsAgoTotal,
                lastYearSameMonthTotal: lastYearSameMonthTotal,
                activityFilter: activityFilter,
                lastUpdated: now
            )
            completion(stats)
        }
    }

    private func fetchDailyDistances(from startDate: Date, to endDate: Date, isCurrentMonth: Bool = true, activityFilter: ActivityFilter, completion: @escaping ([DailyDistance]) -> Void) {
        let calendar = Calendar.current
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)

        let query = HKSampleQuery(
            sampleType: HKObjectType.workoutType(),
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        ) { query, samples, error in
            guard let workouts = samples as? [HKWorkout], error == nil else {
                completion([])
                return
            }

            var dailyDistances: [Int: Double] = [:]

            for workout in workouts.filter({ activityFilter.matches($0) }) {
                if let distance = workout.totalDistance?.doubleValue(for: .meter()) {
                    let day = calendar.component(.day, from: workout.startDate)
                    dailyDistances[day, default: 0] += distance
                }
            }

            let daysInMonth = calendar.range(of: .day, in: .month, for: startDate)?.count ?? 31
            let lastDay: Int
            if isCurrentMonth {
                lastDay = min(calendar.component(.day, from: endDate), daysInMonth)
            } else {
                lastDay = daysInMonth
            }

            var result: [DailyDistance] = []
            var cumulative: Double = 0

            for day in 1...lastDay {
                let distance = dailyDistances[day] ?? 0
                cumulative += distance
                result.append(DailyDistance(day: day, distance: distance, cumulative: cumulative))
            }

            completion(result)
        }

        healthStore.execute(query)
    }

    private func fetchMonthlyDistances(from startDate: Date, to endDate: Date, activityFilter: ActivityFilter, completion: @escaping ([MonthlyDistance]) -> Void) {
        let calendar = Calendar.current
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)

        let query = HKSampleQuery(
            sampleType: HKObjectType.workoutType(),
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        ) { query, samples, error in
            guard let workouts = samples as? [HKWorkout], error == nil else {
                completion([])
                return
            }

            var monthlyDistances: [Int: Double] = [:]

            for workout in workouts.filter({ activityFilter.matches($0) }) {
                if let distance = workout.totalDistance?.doubleValue(for: .meter()) {
                    let month = calendar.component(.month, from: workout.startDate)
                    monthlyDistances[month, default: 0] += distance
                }
            }

            let currentMonth = calendar.component(.month, from: endDate)
            var result: [MonthlyDistance] = []
            var cumulative: Double = 0

            for month in 1...currentMonth {
                let distance = monthlyDistances[month] ?? 0
                cumulative += distance
                result.append(MonthlyDistance(month: month, distance: distance, cumulative: cumulative))
            }

            completion(result)
        }

        healthStore.execute(query)
    }

    private func fetchTotalDistance(from startDate: Date, to endDate: Date, activityFilter: ActivityFilter, completion: @escaping (Double) -> Void) {
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)

        let query = HKSampleQuery(
            sampleType: HKObjectType.workoutType(),
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: nil
        ) { query, samples, error in
            guard let workouts = samples as? [HKWorkout], error == nil else {
                completion(0)
                return
            }

            let totalDistance = workouts
                .filter { activityFilter.matches($0) }
                .compactMap { $0.totalDistance?.doubleValue(for: .meter()) }
                .reduce(0, +)

            completion(totalDistance)
        }

        healthStore.execute(query)
    }

    private func getMonthName(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        return formatter.string(from: date).uppercased()
    }

    private func getMonthName(for month: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        let date = Calendar.current.date(from: DateComponents(month: month))!
        return formatter.string(from: date).uppercased()
    }
}

// MARK: - Data Models

enum ActivityFilter: String, CaseIterable {
    case all = "All Activities"
    case running = "Running"
    case walking = "Walking"
    case hiking = "Hiking"

    func matches(_ workout: HKWorkout) -> Bool {
        switch self {
        case .all:
            return workout.workoutActivityType == .running ||
                   workout.workoutActivityType == .walking ||
                   workout.workoutActivityType == .hiking
        case .running:
            return workout.workoutActivityType == .running
        case .walking:
            return workout.workoutActivityType == .walking
        case .hiking:
            return workout.workoutActivityType == .hiking
        }
    }

    var icon: String {
        switch self {
        case .all: return "figure.run"
        case .running: return "figure.run"
        case .walking: return "figure.walk"
        case .hiking: return "figure.hiking"
        }
    }
}

struct DailyDistance: Identifiable {
    let id = UUID()
    let day: Int
    let distance: Double
    let cumulative: Double

    var distanceKm: Double { distance / 1000.0 }
    var cumulativeKm: Double { cumulative / 1000.0 }
}

struct MonthlyDistance: Identifiable {
    let id = UUID()
    let month: Int
    let distance: Double
    let cumulative: Double

    var distanceKm: Double { distance / 1000.0 }
    var cumulativeKm: Double { cumulative / 1000.0 }

    var monthName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        let date = Calendar.current.date(from: DateComponents(month: month))!
        return formatter.string(from: date).uppercased()
    }
}

struct WorkoutStats {
    var monthName: String = ""
    var currentYear: Int = 0
    var selectedMonth: Int = 0
    var dailyDistances: [DailyDistance] = []
    var yearlyDistances: [MonthlyDistance] = []
    var lastYearTotal: Double = 0
    var twoYearsAgoTotal: Double = 0
    var lastYearSameMonthTotal: Double = 0
    var activityFilter: ActivityFilter = .all
    var lastUpdated: Date = Date()

    var monthTotal: Double { dailyDistances.last?.cumulative ?? 0 }
    var monthTotalKm: Double { monthTotal / 1000.0 }

    var yearTotal: Double { yearlyDistances.last?.cumulative ?? 0 }
    var yearTotalKm: Double { yearTotal / 1000.0 }

    var lastYearTotalKm: Double { lastYearTotal / 1000.0 }
    var twoYearsAgoTotalKm: Double { twoYearsAgoTotal / 1000.0 }
    var lastYearSameMonthTotalKm: Double { lastYearSameMonthTotal / 1000.0 }

    /// Compare selected month vs same month last year
    var monthOverMonthChange: Double {
        guard lastYearSameMonthTotal > 0 else { return 0 }
        return ((monthTotal - lastYearSameMonthTotal) / lastYearSameMonthTotal) * 100
    }

    /// Compare whole year vs whole last year
    var yearOverYearChange: Double {
        guard lastYearTotal > 0 else { return 0 }
        return ((yearTotal - lastYearTotal) / lastYearTotal) * 100
    }

    var hasData: Bool {
        !dailyDistances.isEmpty || !yearlyDistances.isEmpty
    }

    var daysInMonth: Int {
        guard selectedMonth > 0 else {
            return Calendar.current.range(of: .day, in: .month, for: Date())?.count ?? 31
        }
        let components = DateComponents(year: currentYear, month: selectedMonth)
        guard let date = Calendar.current.date(from: components) else { return 31 }
        return Calendar.current.range(of: .day, in: .month, for: date)?.count ?? 31
    }
}

struct WorkoutEntry: TimelineEntry {
    let date: Date
    let stats: WorkoutStats
}

// MARK: - Timeline Provider

struct WorkoutProvider: AppIntentTimelineProvider {
    typealias Entry = WorkoutEntry
    typealias Intent = WorkoutWidgetConfigurationIntent

    func placeholder(in context: Context) -> WorkoutEntry {
        WorkoutEntry(date: Date(), stats: WorkoutStats())
    }

    func snapshot(for configuration: WorkoutWidgetConfigurationIntent, in context: Context) async -> WorkoutEntry {
        await withCheckedContinuation { continuation in
            let (month, year) = resolveMonthYear(from: configuration)
            WidgetHealthKitManager.shared.fetchWorkoutStats(activityFilter: .all, month: month, year: year) { stats in
                continuation.resume(returning: WorkoutEntry(date: Date(), stats: stats))
            }
        }
    }

    func timeline(for configuration: WorkoutWidgetConfigurationIntent, in context: Context) async -> Timeline<WorkoutEntry> {
        await withCheckedContinuation { continuation in
            let (month, year) = resolveMonthYear(from: configuration)
            WidgetHealthKitManager.shared.fetchWorkoutStats(activityFilter: .all, month: month, year: year) { stats in
                let currentDate = Date()
                let entry = WorkoutEntry(date: currentDate, stats: stats)
                let nextUpdate = Calendar.current.date(byAdding: .hour, value: 1, to: currentDate)!
                let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
                continuation.resume(returning: timeline)
            }
        }
    }

    private func resolveMonthYear(from configuration: WorkoutWidgetConfigurationIntent) -> (Int, Int) {
        let calendar = Calendar.current
        let now = Date()
        let currentYear = calendar.component(.year, from: now)
        let currentMonth = calendar.component(.month, from: now)

        if let selectedMonth = configuration.selectedMonth {
            return (selectedMonth.rawValue, currentYear)
        }
        return (currentMonth, currentYear)
    }
}

// MARK: - Widget Views

struct WorkoutWidgetSmallView: View {
    let stats: WorkoutStats

    var body: some View {
        if !stats.hasData {
            // No data
            VStack(spacing: 6) {
                Image(systemName: "heart.text.square.fill")
                    .font(.title)
                    .foregroundColor(.cyan)
                Text("Open App")
                    .font(.caption)
                    .foregroundColor(.white)
                Text("Grant HealthKit")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: stats.activityFilter.icon)
                        .font(.caption)
                        .foregroundColor(.cyan)
                    Spacer()
                    Text(stats.monthName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.cyan)
                }

                Text("\(stats.monthTotalKm, specifier: "%.1f")KM")
                    .font(.system(.title3, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                Spacer()

                if !stats.dailyDistances.isEmpty {
                    Chart(stats.dailyDistances) { data in
                        LineMark(
                            x: .value("Day", data.day),
                            y: .value("Distance", data.cumulativeKm)
                        )
                        .foregroundStyle(.cyan)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .frame(height: 30)
                }

                if stats.lastYearTotalKm > 0 {
                    Text("Last yr: \(stats.lastYearTotalKm, specifier: "%.0f")km")
                        .font(.system(size: 8))
                        .foregroundColor(.gray)
                }
            }
            .padding(12)
        }
    }
}

struct WorkoutWidgetMediumView: View {
    let stats: WorkoutStats
    @State private var showYearly = false

    var body: some View {
        if !stats.hasData {
            VStack(spacing: 8) {
                Image(systemName: "heart.text.square.fill")
                    .font(.largeTitle)
                    .foregroundColor(.cyan)
                Text("HealthKit Access Required")
                    .font(.subheadline)
                    .foregroundColor(.white)
                Text("Open the app and grant permissions")
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
            }
            .padding()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                // Header
                HStack(alignment: .top) {
                    Image(systemName: stats.activityFilter.icon)
                        .font(.title3)
                        .foregroundColor(.cyan)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(stats.monthName)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.cyan)
                        Text("\(stats.currentYear)")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                }

                // Distance
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(stats.monthTotalKm, specifier: "%.1f")")
                        .font(.system(.title, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    Text("KM")
                        .font(.caption)
                        .foregroundColor(.cyan)

                    Spacer()

                    if stats.lastYearSameMonthTotalKm > 0 {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("vs \(stats.monthName) \(stats.currentYear - 1)")
                                .font(.system(size: 7))
                                .foregroundColor(.gray)
                            HStack(spacing: 2) {
                                Image(systemName: stats.monthOverMonthChange >= 0 ? "arrow.up" : "arrow.down")
                                    .font(.system(size: 8))
                                Text("\(abs(stats.monthOverMonthChange), specifier: "%.0f")%")
                                    .font(.system(size: 9))
                                    .fontWeight(.semibold)
                            }
                            .foregroundColor(stats.monthOverMonthChange >= 0 ? .green : .orange)
                        }
                    }
                }

                // Chart
                if !stats.dailyDistances.isEmpty {
                    let maxValue = max(stats.dailyDistances.last?.cumulativeKm ?? 10, 10.0)

                    HStack(spacing: 4) {
                        // Y-axis
                        VStack(spacing: 0) {
                            Text("\(Int(maxValue))")
                                .font(.system(size: 7))
                                .foregroundColor(.gray)
                            Spacer()
                            Text("0")
                                .font(.system(size: 7))
                                .foregroundColor(.gray)
                        }
                        .frame(width: 18, height: 60)

                        // Chart
                        Chart(stats.dailyDistances) { data in
                            BarMark(
                                x: .value("Day", data.day),
                                y: .value("Distance", data.distanceKm)
                            )
                            .foregroundStyle(Color.gray.opacity(0.3))

                            LineMark(
                                x: .value("Day", data.day),
                                y: .value("Cumulative", data.cumulativeKm)
                            )
                            .foregroundStyle(.cyan)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))

                            if data.day == stats.dailyDistances.last?.day {
                                PointMark(
                                    x: .value("Day", data.day),
                                    y: .value("Cumulative", data.cumulativeKm)
                                )
                                .foregroundStyle(.white)
                                .symbolSize(30)
                            }
                        }
                        .chartXScale(domain: 1...stats.daysInMonth)
                        .chartYScale(domain: 0...maxValue)
                        .chartXAxis {
                            AxisMarks(values: [1, 10, 20, 30]) { value in
                                AxisValueLabel {
                                    if let day = value.as(Int.self) {
                                        Text("\(day)")
                                            .font(.system(size: 7))
                                            .foregroundColor(.gray)
                                    }
                                }
                            }
                        }
                        .chartYAxis(.hidden)
                        .frame(height: 60)
                    }
                }

                // Yearly summary
                if !stats.yearlyDistances.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.system(size: 8))
                            .foregroundColor(.gray)
                        Text("Year: \(stats.yearTotalKm, specifier: "%.0f")km")
                            .font(.system(size: 9))
                            .foregroundColor(.gray)
                        if stats.lastYearTotalKm > 0 {
                            Text("(Last: \(stats.lastYearTotalKm, specifier: "%.0f")km)")
                                .font(.system(size: 8))
                                .foregroundColor(.gray.opacity(0.7))
                        }
                    }
                }
            }
            .padding(10)
        }
    }
}

struct WorkoutWidgetLargeView: View {
    let stats: WorkoutStats

    var body: some View {
        if !stats.hasData {
            VStack(spacing: 12) {
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.cyan)
                Text("HealthKit Access Required")
                    .font(.headline)
                    .foregroundColor(.white)
                Text("Open the GPS location app and grant HealthKit permissions to view your workout statistics.")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
            }
            .padding()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                // Header
                HStack {
                    Image(systemName: stats.activityFilter.icon)
                        .font(.title2)
                        .foregroundColor(.cyan)
                    Text(stats.activityFilter.rawValue)
                        .font(.headline)
                        .foregroundColor(.white)
                    Spacer()
                    Text("\(stats.currentYear)")
                        .font(.title3)
                        .foregroundColor(.cyan)
                }

                Divider()

                // Monthly section
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(stats.monthName) \(String(stats.currentYear))")
                        .font(.caption)
                        .foregroundColor(.gray)

                    Text("\(stats.monthTotalKm, specifier: "%.1f") KM")
                        .font(.system(.title, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundColor(.white)

                    if !stats.dailyDistances.isEmpty {
                        Chart(stats.dailyDistances) { data in
                            BarMark(
                                x: .value("Day", data.day),
                                y: .value("Distance", data.distanceKm)
                            )
                            .foregroundStyle(Color.gray.opacity(0.3))

                            LineMark(
                                x: .value("Day", data.day),
                                y: .value("Cumulative", data.cumulativeKm)
                            )
                            .foregroundStyle(.cyan)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        }
                        .chartXAxis {
                            AxisMarks(values: .stride(by: 5))
                        }
                        .frame(height: 80)
                    }
                }

                Divider()

                // Yearly section
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("THIS YEAR")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Spacer()
                        if stats.lastYearTotalKm > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: stats.yearOverYearChange >= 0 ? "arrow.up" : "arrow.down")
                                Text("\(abs(stats.yearOverYearChange), specifier: "%.0f")%")
                            }
                            .font(.caption2)
                            .foregroundColor(stats.yearOverYearChange >= 0 ? .green : .orange)
                        }
                    }

                    Text("\(stats.yearTotalKm, specifier: "%.0f") KM")
                        .font(.system(.title2, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundColor(.white)

                    if !stats.yearlyDistances.isEmpty {
                        Chart(stats.yearlyDistances) { data in
                            BarMark(
                                x: .value("Month", data.monthName),
                                y: .value("Distance", data.distanceKm)
                            )
                            .foregroundStyle(.cyan.opacity(0.7))
                        }
                        .chartXAxis {
                            AxisMarks(values: .automatic(desiredCount: 6))
                        }
                        .frame(height: 80)
                    }

                    if stats.lastYearTotalKm > 0 {
                        Text("Last year: \(stats.lastYearTotalKm, specifier: "%.0f") km")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                }
            }
            .padding()
        }
    }
}

struct WorkoutWidgetRectangularView: View {
    let stats: WorkoutStats

    var body: some View {
        if !stats.hasData {
            VStack(spacing: 2) {
                HStack {
                    Image(systemName: "heart.text.square.fill")
                        .foregroundColor(.cyan)
                        .font(.caption2)
                    Text("Open App")
                        .font(.caption2)
                        .foregroundColor(.white)
                }
                Text("Grant HealthKit")
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
            }
            .padding(6)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Image(systemName: stats.activityFilter.icon)
                        .foregroundColor(.cyan)
                        .font(.caption2)
                    Text("\(stats.monthTotalKm, specifier: "%.1f")KM")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    Spacer()
                    Text(stats.monthName)
                        .font(.caption2)
                        .foregroundColor(.cyan)
                }

                if !stats.dailyDistances.isEmpty {
                    Chart(stats.dailyDistances) { data in
                        LineMark(
                            x: .value("Day", data.day),
                            y: .value("Distance", data.cumulativeKm)
                        )
                        .foregroundStyle(.cyan)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .frame(height: 24)
                }
            }
            .padding(6)
        }
    }
}

// MARK: - Main Widget View

struct WorkoutWidgetEntryView: View {
    @Environment(\.widgetFamily) var widgetFamily
    var entry: WorkoutProvider.Entry

    var body: some View {
        switch widgetFamily {
        case .systemSmall:
            WorkoutWidgetSmallView(stats: entry.stats)
        case .systemMedium:
            WorkoutWidgetMediumView(stats: entry.stats)
        case .systemLarge:
            WorkoutWidgetLargeView(stats: entry.stats)
        case .accessoryRectangular:
            WorkoutWidgetRectangularView(stats: entry.stats)
        default:
            WorkoutWidgetMediumView(stats: entry.stats)
        }
    }
}

// MARK: - Widget Configuration

struct WorkoutWidget: Widget {
    let kind: String = "WorkoutWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: WorkoutWidgetConfigurationIntent.self, provider: WorkoutProvider()) { entry in
            if #available(iOS 17.0, *) {
                WorkoutWidgetEntryView(entry: entry)
                    .containerBackground(Color.black, for: .widget)
            } else {
                WorkoutWidgetEntryView(entry: entry)
                    .padding()
                    .background(Color.black)
            }
        }
        .configurationDisplayName("Workout Stats")
        .description("View your monthly and yearly distance with charts. Choose a month to display.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

// MARK: - Previews

private func createPreviewStats() -> WorkoutStats {
    var dailyData: [DailyDistance] = []
    var cumulative: Double = 0

    let distances = [12.3, 0, 15.7, 8.2, 0, 22.1, 18.5, 0, 10.3, 25.8,
                     14.2, 0, 19.6, 11.8, 0, 0, 28.3, 16.7, 12.9, 21.4,
                     0, 18.2, 14.5, 0, 20.1, 13.8, 0, 17.3, 22.6, 15.9]

    for (index, distance) in distances.enumerated() {
        cumulative += distance * 1000
        dailyData.append(DailyDistance(
            day: index + 1,
            distance: distance * 1000,
            cumulative: cumulative
        ))
    }

    var yearlyData: [MonthlyDistance] = []
    var yearlyCumulative: Double = 0
    let monthlyDistances = [85.2, 92.1, 105.3, 98.7, 110.2, 115.8, 108.4, 95.6, 102.3, 118.5, 95.2, 88.9]

    for (index, distance) in monthlyDistances.enumerated() {
        yearlyCumulative += distance * 1000
        yearlyData.append(MonthlyDistance(
            month: index + 1,
            distance: distance * 1000,
            cumulative: yearlyCumulative
        ))
    }

    return WorkoutStats(
        monthName: "JAN",
        currentYear: 2026,
        dailyDistances: dailyData,
        yearlyDistances: yearlyData,
        lastYearTotal: 1_180_500,
        twoYearsAgoTotal: 1_050_200,
        activityFilter: .all,
        lastUpdated: Date()
    )
}

#Preview(as: .systemSmall) {
    WorkoutWidget()
} timeline: {
    WorkoutEntry(date: .now, stats: createPreviewStats())
}

#Preview(as: .systemMedium) {
    WorkoutWidget()
} timeline: {
    WorkoutEntry(date: .now, stats: createPreviewStats())
}

#Preview(as: .systemLarge) {
    WorkoutWidget()
} timeline: {
    WorkoutEntry(date: .now, stats: createPreviewStats())
}

#Preview(as: .accessoryRectangular) {
    WorkoutWidget()
} timeline: {
    WorkoutEntry(date: .now, stats: createPreviewStats())
}

#endif
