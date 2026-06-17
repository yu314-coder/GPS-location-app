//
//  WorkoutAnalyticsManager.swift
//  GPS location app
//
//  Created by Claude on 2/26/26.
//

import Foundation
import HealthKit
import Combine

// MARK: - Data Models (duplicated from widget target for cross-target access)

enum AnalyticsActivityFilter: String, CaseIterable {
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

struct AnalyticsDailyDistance: Identifiable {
    let id = UUID()
    let day: Int
    let distance: Double
    let cumulative: Double

    var distanceKm: Double { distance / 1000.0 }
    var cumulativeKm: Double { cumulative / 1000.0 }
}

struct AnalyticsMonthlyDistance: Identifiable {
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

struct AnalyticsYearlyDistance: Identifiable {
    let id = UUID()
    let year: Int
    let distance: Double
    let cumulative: Double

    var distanceKm: Double { distance / 1000.0 }
    var cumulativeKm: Double { cumulative / 1000.0 }
}

struct AnalyticsAllTimeMonthlyDistance: Identifiable {
    let id = UUID()
    let monthStart: Date
    let year: Int
    let month: Int
    let distance: Double
    let cumulative: Double

    var distanceKm: Double { distance / 1000.0 }
    var cumulativeKm: Double { cumulative / 1000.0 }

    var monthLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: monthStart)
    }
}

struct AnalyticsAllTimeDailyDistance: Identifiable {
    let id = UUID()
    let dayStart: Date
    let year: Int
    let month: Int
    let day: Int
    let distance: Double
    let cumulative: Double

    var distanceKm: Double { distance / 1000.0 }
    var cumulativeKm: Double { cumulative / 1000.0 }

    var dayLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: dayStart)
    }
}

// MARK: - WorkoutAnalyticsManager

class WorkoutAnalyticsManager: ObservableObject {
    static let shared = WorkoutAnalyticsManager()
    private let healthStore = HKHealthStore()

    @Published var dailyDistances: [AnalyticsDailyDistance] = []
    @Published var yearlyDistances: [AnalyticsMonthlyDistance] = []
    @Published var lastYearTotal: Double = 0
    @Published var twoYearsAgoTotal: Double = 0
    @Published var lastYearSameMonthTotal: Double = 0
    @Published var isLoading = false
    @Published var isAllTimeSelected = false
    @Published var allTimeYearFilter: Int? = nil
    @Published var selectedMonth: Int
    @Published var selectedYear: Int
    @Published var activityFilter: AnalyticsActivityFilter = .all
    @Published var allTimeYearlyDistances: [AnalyticsYearlyDistance] = []
    @Published var allTimeMonthlyDistances: [AnalyticsAllTimeMonthlyDistance] = []
    @Published var allTimeDailyDistances: [AnalyticsAllTimeDailyDistance] = []
    @Published var allTimeTotal: Double = 0
    @Published var allTimeWorkoutCount: Int = 0

    var monthTotal: Double { dailyDistances.last?.cumulative ?? 0 }
    var monthTotalKm: Double { monthTotal / 1000.0 }
    var yearTotalKm: Double { (yearlyDistances.last?.cumulative ?? 0) / 1000.0 }
    var lastYearTotalKm: Double { lastYearTotal / 1000.0 }
    var lastYearSameMonthTotalKm: Double { lastYearSameMonthTotal / 1000.0 }
    var allTimeTotalKm: Double { allTimeTotal / 1000.0 }
    var allTimeRangeTitle: String {
        if let allTimeYearFilter {
            return String(allTimeYearFilter)
        }
        return "All Time"
    }
    var allTimeBestYearKm: Double { allTimeYearlyDistances.map(\.distanceKm).max() ?? 0 }
    var allTimeAverageYearKm: Double {
        guard !allTimeYearlyDistances.isEmpty else { return 0 }
        return allTimeYearlyDistances.map(\.distanceKm).reduce(0, +) / Double(allTimeYearlyDistances.count)
    }

    /// Compare selected month vs same month last year
    var monthOverMonthChange: Double {
        guard lastYearSameMonthTotal > 0 else { return 0 }
        return ((monthTotal - lastYearSameMonthTotal) / lastYearSameMonthTotal) * 100
    }

    /// Compare whole year vs last year
    var yearOverYearChange: Double {
        let yearTotal = yearlyDistances.last?.cumulative ?? 0
        guard lastYearTotal > 0 else { return 0 }
        return ((yearTotal - lastYearTotal) / lastYearTotal) * 100
    }

    var monthName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        let date = Calendar.current.date(from: DateComponents(month: selectedMonth))!
        return formatter.string(from: date).uppercased()
    }

    var daysInSelectedMonth: Int {
        let components = DateComponents(year: selectedYear, month: selectedMonth)
        guard let date = Calendar.current.date(from: components) else { return 31 }
        return Calendar.current.range(of: .day, in: .month, for: date)?.count ?? 31
    }

    init() {
        let calendar = Calendar.current
        let now = Date()
        self.selectedMonth = calendar.component(.month, from: now)
        self.selectedYear = calendar.component(.year, from: now)
    }

    func fetchData() {
        isLoading = true

        if isAllTimeSelected {
            fetchAllTimeData()
            return
        }

        let calendar = Calendar.current
        let now = Date()
        let currentActualMonth = calendar.component(.month, from: now)
        let currentActualYear = calendar.component(.year, from: now)
        let isCurrentMonth = (selectedMonth == currentActualMonth && selectedYear == currentActualYear)

        guard HKHealthStore.isHealthDataAvailable() else {
            isLoading = false
            return
        }

        let group = DispatchGroup()

        var fetchedDaily: [AnalyticsDailyDistance] = []
        var fetchedYearly: [AnalyticsMonthlyDistance] = []
        var fetchedLastYear: Double = 0
        var fetchedTwoYearsAgo: Double = 0
        var fetchedLastYearSameMonth: Double = 0

        // Daily distances for selected month
        group.enter()
        let monthStart = calendar.date(from: DateComponents(year: selectedYear, month: selectedMonth, day: 1))!
        let monthEnd: Date
        if isCurrentMonth {
            monthEnd = now
        } else {
            let nextMonthStart = calendar.date(from: DateComponents(year: selectedYear, month: selectedMonth + 1, day: 1))!
            monthEnd = nextMonthStart.addingTimeInterval(-1)
        }
        fetchDailyDistances(from: monthStart, to: monthEnd, isCurrentMonth: isCurrentMonth) { data in
            fetchedDaily = data
            group.leave()
        }

        // Yearly monthly distances
        group.enter()
        let yearStart = calendar.date(from: DateComponents(year: selectedYear))!
        let yearEnd = (selectedYear == currentActualYear) ? now : calendar.date(from: DateComponents(year: selectedYear + 1))!.addingTimeInterval(-1)
        fetchMonthlyDistances(from: yearStart, to: yearEnd) { data in
            fetchedYearly = data
            group.leave()
        }

        // Last year total (whole year)
        group.enter()
        let lastYearStart = calendar.date(from: DateComponents(year: selectedYear - 1))!
        let lastYearEnd = calendar.date(byAdding: .second, value: -1, to: yearStart)!
        fetchTotalDistance(from: lastYearStart, to: lastYearEnd) { distance in
            fetchedLastYear = distance
            group.leave()
        }

        // Same month last year (for month-over-month comparison)
        group.enter()
        let sameMonthLastYearStart = calendar.date(from: DateComponents(year: selectedYear - 1, month: selectedMonth, day: 1))!
        let sameMonthLastYearEnd = calendar.date(from: DateComponents(year: selectedYear - 1, month: selectedMonth + 1, day: 1))!.addingTimeInterval(-1)
        fetchTotalDistance(from: sameMonthLastYearStart, to: sameMonthLastYearEnd) { distance in
            fetchedLastYearSameMonth = distance
            group.leave()
        }

        // Two years ago total
        group.enter()
        let twoYearsStart = calendar.date(from: DateComponents(year: selectedYear - 2))!
        let twoYearsEnd = calendar.date(byAdding: .second, value: -1, to: lastYearStart)!
        fetchTotalDistance(from: twoYearsStart, to: twoYearsEnd) { distance in
            fetchedTwoYearsAgo = distance
            group.leave()
        }

        group.notify(queue: .main) { [weak self] in
            self?.dailyDistances = fetchedDaily
            self?.yearlyDistances = fetchedYearly
            self?.lastYearTotal = fetchedLastYear
            self?.twoYearsAgoTotal = fetchedTwoYearsAgo
            self?.lastYearSameMonthTotal = fetchedLastYearSameMonth
            self?.isLoading = false
        }
    }

    // MARK: - HealthKit Queries

    private func fetchAllTimeData() {
        guard HKHealthStore.isHealthDataAvailable() else {
            DispatchQueue.main.async {
                self.allTimeYearlyDistances = []
                self.allTimeMonthlyDistances = []
                self.allTimeDailyDistances = []
                self.allTimeTotal = 0
                self.allTimeWorkoutCount = 0
                self.isLoading = false
            }
            return
        }

        let filter = activityFilter
        let yearFilter = allTimeYearFilter
        let calendar = Calendar.current

        let predicate: NSPredicate?
        if let yearFilter,
           let yearStart = calendar.date(from: DateComponents(year: yearFilter, month: 1, day: 1)),
           let nextYearStart = calendar.date(from: DateComponents(year: yearFilter + 1, month: 1, day: 1)) {
            predicate = HKQuery.predicateForSamples(withStart: yearStart, end: nextYearStart, options: .strictStartDate)
        } else {
            predicate = nil
        }

        let query = HKSampleQuery(
            sampleType: HKObjectType.workoutType(),
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        ) { _, samples, error in
            guard let workouts = samples as? [HKWorkout], error == nil else {
                DispatchQueue.main.async {
                    self.allTimeYearlyDistances = []
                    self.allTimeMonthlyDistances = []
                    self.allTimeDailyDistances = []
                    self.allTimeTotal = 0
                    self.allTimeWorkoutCount = 0
                    self.isLoading = false
                }
                return
            }

            let matchingWorkouts = workouts.filter { workout in
                guard filter.matches(workout) else { return false }
                if let yearFilter {
                    return calendar.component(.year, from: workout.startDate) == yearFilter
                }
                return true
            }
            var yearlyDistances: [Int: Double] = [:]
            var monthlyDistances: [Date: Double] = [:]
            var dailyDistances: [Date: Double] = [:]
            var totalDistance: Double = 0

            for workout in matchingWorkouts {
                guard let distance = workout.totalDistance?.doubleValue(for: .meter()) else { continue }
                let year = calendar.component(.year, from: workout.startDate)
                let month = calendar.component(.month, from: workout.startDate)
                let monthStart = calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? calendar.startOfDay(for: workout.startDate)
                let dayStart = calendar.startOfDay(for: workout.startDate)
                yearlyDistances[year, default: 0] += distance
                monthlyDistances[monthStart, default: 0] += distance
                dailyDistances[dayStart, default: 0] += distance
                totalDistance += distance
            }

            let currentYear = calendar.component(.year, from: Date())
            let currentMonth = calendar.component(.month, from: Date())
            let firstWorkoutYear = matchingWorkouts
                .map { calendar.component(.year, from: $0.startDate) }
                .min()
            let firstWorkoutMonth = matchingWorkouts
                .compactMap { workout -> Date? in
                    let year = calendar.component(.year, from: workout.startDate)
                    let month = calendar.component(.month, from: workout.startDate)
                    return calendar.date(from: DateComponents(year: year, month: month, day: 1))
                }
                .min()
            let sortedYears: [Int]
            if let yearFilter {
                sortedYears = [yearFilter]
            } else if let firstWorkoutYear {
                sortedYears = Array(firstWorkoutYear...currentYear)
            } else {
                sortedYears = []
            }
            var cumulative: Double = 0
            let result = sortedYears.map { year in
                let distance = yearlyDistances[year] ?? 0
                cumulative += distance
                return AnalyticsYearlyDistance(year: year, distance: distance, cumulative: cumulative)
            }

            let sortedMonths: [Date]
            if let yearFilter {
                let lastMonth = yearFilter == currentYear ? currentMonth : 12
                sortedMonths = (1...lastMonth).compactMap { month in
                    calendar.date(from: DateComponents(year: yearFilter, month: month, day: 1))
                }
            } else if let firstWorkoutMonth,
               let currentMonthStart = calendar.date(from: DateComponents(year: currentYear, month: currentMonth, day: 1)) {
                var months: [Date] = []
                var cursor = firstWorkoutMonth
                while cursor <= currentMonthStart {
                    months.append(cursor)
                    guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
                    cursor = next
                }
                sortedMonths = months
            } else {
                sortedMonths = []
            }

            var monthlyCumulative: Double = 0
            let monthlyResult = sortedMonths.map { monthStart in
                let components = calendar.dateComponents([.year, .month], from: monthStart)
                let distance = monthlyDistances[monthStart] ?? 0
                monthlyCumulative += distance
                return AnalyticsAllTimeMonthlyDistance(
                    monthStart: monthStart,
                    year: components.year ?? currentYear,
                    month: components.month ?? 1,
                    distance: distance,
                    cumulative: monthlyCumulative
                )
            }

            let sortedDays: [Date]
            if let yearFilter,
               let firstDayStart = calendar.date(from: DateComponents(year: yearFilter, month: 1, day: 1)) {
                let lastDayStart: Date
                if yearFilter == currentYear {
                    lastDayStart = calendar.startOfDay(for: Date())
                } else {
                    lastDayStart = calendar.date(from: DateComponents(year: yearFilter, month: 12, day: 31)) ?? firstDayStart
                }

                var days: [Date] = []
                var cursor = firstDayStart
                while cursor <= lastDayStart {
                    days.append(cursor)
                    guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                    cursor = next
                }
                sortedDays = days
            } else {
                sortedDays = []
            }

            var dailyCumulative: Double = 0
            let dailyResult = sortedDays.map { dayStart in
                let components = calendar.dateComponents([.year, .month, .day], from: dayStart)
                let distance = dailyDistances[dayStart] ?? 0
                dailyCumulative += distance
                return AnalyticsAllTimeDailyDistance(
                    dayStart: dayStart,
                    year: components.year ?? currentYear,
                    month: components.month ?? 1,
                    day: components.day ?? 1,
                    distance: distance,
                    cumulative: dailyCumulative
                )
            }

            DispatchQueue.main.async {
                self.allTimeYearlyDistances = result
                self.allTimeMonthlyDistances = monthlyResult
                self.allTimeDailyDistances = dailyResult
                self.allTimeTotal = totalDistance
                self.allTimeWorkoutCount = matchingWorkouts.count
                self.isLoading = false
            }
        }

        healthStore.execute(query)
    }

    private func fetchDailyDistances(from startDate: Date, to endDate: Date, isCurrentMonth: Bool, completion: @escaping ([AnalyticsDailyDistance]) -> Void) {
        let calendar = Calendar.current
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let filter = activityFilter

        let query = HKSampleQuery(
            sampleType: HKObjectType.workoutType(),
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        ) { _, samples, error in
            guard let workouts = samples as? [HKWorkout], error == nil else {
                completion([])
                return
            }

            var dailyDistances: [Int: Double] = [:]
            for workout in workouts.filter({ filter.matches($0) }) {
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

            var result: [AnalyticsDailyDistance] = []
            var cumulative: Double = 0
            for day in 1...lastDay {
                let distance = dailyDistances[day] ?? 0
                cumulative += distance
                result.append(AnalyticsDailyDistance(day: day, distance: distance, cumulative: cumulative))
            }

            completion(result)
        }

        healthStore.execute(query)
    }

    private func fetchMonthlyDistances(from startDate: Date, to endDate: Date, completion: @escaping ([AnalyticsMonthlyDistance]) -> Void) {
        let calendar = Calendar.current
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let filter = activityFilter

        let query = HKSampleQuery(
            sampleType: HKObjectType.workoutType(),
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        ) { _, samples, error in
            guard let workouts = samples as? [HKWorkout], error == nil else {
                completion([])
                return
            }

            var monthlyDistances: [Int: Double] = [:]
            for workout in workouts.filter({ filter.matches($0) }) {
                if let distance = workout.totalDistance?.doubleValue(for: .meter()) {
                    let month = calendar.component(.month, from: workout.startDate)
                    monthlyDistances[month, default: 0] += distance
                }
            }

            let currentMonth = calendar.component(.month, from: endDate)
            var result: [AnalyticsMonthlyDistance] = []
            var cumulative: Double = 0
            for month in 1...currentMonth {
                let distance = monthlyDistances[month] ?? 0
                cumulative += distance
                result.append(AnalyticsMonthlyDistance(month: month, distance: distance, cumulative: cumulative))
            }

            completion(result)
        }

        healthStore.execute(query)
    }

    private func fetchTotalDistance(from startDate: Date, to endDate: Date, completion: @escaping (Double) -> Void) {
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let filter = activityFilter

        let query = HKSampleQuery(
            sampleType: HKObjectType.workoutType(),
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: nil
        ) { _, samples, error in
            guard let workouts = samples as? [HKWorkout], error == nil else {
                completion(0)
                return
            }

            let totalDistance = workouts
                .filter { filter.matches($0) }
                .compactMap { $0.totalDistance?.doubleValue(for: .meter()) }
                .reduce(0, +)

            completion(totalDistance)
        }

        healthStore.execute(query)
    }
}
