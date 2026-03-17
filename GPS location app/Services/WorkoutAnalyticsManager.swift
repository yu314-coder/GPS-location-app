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
    @Published var selectedMonth: Int
    @Published var selectedYear: Int
    @Published var activityFilter: AnalyticsActivityFilter = .all

    var monthTotal: Double { dailyDistances.last?.cumulative ?? 0 }
    var monthTotalKm: Double { monthTotal / 1000.0 }
    var yearTotalKm: Double { (yearlyDistances.last?.cumulative ?? 0) / 1000.0 }
    var lastYearTotalKm: Double { lastYearTotal / 1000.0 }
    var lastYearSameMonthTotalKm: Double { lastYearSameMonthTotal / 1000.0 }

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
