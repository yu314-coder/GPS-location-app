//
//  WorkoutShortcuts.swift
//  GPS location app
//
//  Created by Claude on 2/28/26.
//

import AppIntents
import HealthKit
import SwiftUI

// MARK: - Workout Type Enum for AppIntents

enum WorkoutTypeOption: String, CaseIterable, AppEnum {
    case walking = "Walking"
    case running = "Running"
    case cycling = "Cycling"
    case hiking = "Hiking"
    case flight = "Flight"
    case general = "General"

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Workout Type")

    static var caseDisplayRepresentations: [WorkoutTypeOption: DisplayRepresentation] {
        [
            .walking: DisplayRepresentation(title: "Walking", image: .init(systemName: "figure.walk")),
            .running: DisplayRepresentation(title: "Running", image: .init(systemName: "figure.run")),
            .cycling: DisplayRepresentation(title: "Cycling", image: .init(systemName: "bicycle")),
            .hiking: DisplayRepresentation(title: "Hiking", image: .init(systemName: "mountain.2.fill")),
            .flight: DisplayRepresentation(title: "Flight", image: .init(systemName: "airplane")),
            .general: DisplayRepresentation(title: "General", image: .init(systemName: "figure.mixed.cardio"))
        ]
    }

    var hkWorkoutType: HKWorkoutActivityType {
        switch self {
        case .walking: return .walking
        case .running: return .running
        case .cycling: return .cycling
        case .hiking: return .hiking
        case .flight: return .other
        case .general: return .traditionalStrengthTraining
        }
    }

    var iconName: String {
        switch self {
        case .walking: return "figure.walk"
        case .running: return "figure.run"
        case .cycling: return "bicycle"
        case .hiking: return "mountain.2.fill"
        case .flight: return "airplane"
        case .general: return "figure.mixed.cardio"
        }
    }
}

// MARK: - Start Workout Intent

struct StartWorkoutIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Workout"
    static var description: IntentDescription = "Start a GPS workout session and open the live tracking view."
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Workout Type", default: .walking)
    var workoutType: WorkoutTypeOption

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let session = WorkoutSession.shared

        // Don't start if already active
        guard !session.isActive else {
            return .result(dialog: "A workout is already in progress. Please stop it first.")
        }

        // Set workout type and start
        session.setWorkoutType(workoutType.hkWorkoutType)
        session.startWorkout()

        // Open the live session view
        NotificationCenter.default.post(name: .openLiveSessionRequested, object: nil)

        return .result(dialog: "\(workoutType.rawValue) workout started! Tracking your GPS location now.")
    }
}

// MARK: - Stop Workout Intent

struct StopWorkoutIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Workout"
    static var description: IntentDescription = "Stop the current GPS workout and save it."
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let session = WorkoutSession.shared

        guard session.isActive else {
            return .result(dialog: "No workout is currently active.")
        }

        let distance = session.currentMetrics.totalDistance
        let duration = session.activeDuration
        let distanceKm = String(format: "%.2f", distance / 1000.0)
        let durationStr = duration.formattedDuration

        await withCheckedContinuation { continuation in
            session.stopWorkout { _ in
                continuation.resume()
            }
        }

        return .result(dialog: "Workout stopped and saved! Distance: \(distanceKm) km, Duration: \(durationStr)")
    }
}

// MARK: - Pause Workout Intent

struct PauseWorkoutIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause Workout"
    static var description: IntentDescription = "Pause the current GPS workout session."

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let session = WorkoutSession.shared

        guard session.isActive else {
            return .result(dialog: "No workout is currently active.")
        }

        guard !session.isPaused else {
            return .result(dialog: "The workout is already paused.")
        }

        session.pauseWorkout()

        return .result(dialog: "Workout paused. GPS tracking is on hold.")
    }
}

// MARK: - Resume Workout Intent

struct ResumeWorkoutIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume Workout"
    static var description: IntentDescription = "Resume a paused GPS workout session."

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let session = WorkoutSession.shared

        guard session.isActive else {
            return .result(dialog: "No workout is currently active.")
        }

        guard session.isPaused else {
            return .result(dialog: "The workout is not paused.")
        }

        session.resumeWorkout()

        return .result(dialog: "Workout resumed! GPS tracking is active again.")
    }
}

// MARK: - Get Workout Status Intent

struct GetWorkoutStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Workout Status"
    static var description: IntentDescription = "Get the current workout status and metrics."

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let session = WorkoutSession.shared

        guard session.isActive else {
            return .result(dialog: "No workout is currently active.")
        }

        let metrics = session.currentMetrics
        let distance = String(format: "%.2f", metrics.totalDistance / 1000.0)
        let speed = String(format: "%.1f", metrics.tenSecondAverageSpeed * 3.6)
        let duration = session.activeDuration.formattedDuration
        let altitude = String(format: "%.0f", metrics.currentAltitude)
        let status = session.isPaused ? "Paused" : "Active"

        return .result(dialog: "Status: \(status)\nDistance: \(distance) km\nSpeed: \(speed) km/h\nAltitude: \(altitude) m\nDuration: \(duration)")
    }
}

// MARK: - App Shortcuts Provider

struct GPSWorkoutShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartWorkoutIntent(),
            phrases: [
                "Start a \(\.$workoutType) workout in \(.applicationName)",
                "Start tracking \(\.$workoutType) in \(.applicationName)",
                "Begin \(\.$workoutType) workout with \(.applicationName)",
                "Track my \(\.$workoutType) in \(.applicationName)",
                "Start \(.applicationName) workout"
            ],
            shortTitle: "Start Workout",
            systemImageName: "play.circle.fill"
        )
        AppShortcut(
            intent: StopWorkoutIntent(),
            phrases: [
                "Stop workout in \(.applicationName)",
                "Stop tracking in \(.applicationName)",
                "End workout in \(.applicationName)",
                "Finish workout in \(.applicationName)"
            ],
            shortTitle: "Stop Workout",
            systemImageName: "stop.circle.fill"
        )
        AppShortcut(
            intent: PauseWorkoutIntent(),
            phrases: [
                "Pause workout in \(.applicationName)",
                "Pause tracking in \(.applicationName)"
            ],
            shortTitle: "Pause Workout",
            systemImageName: "pause.circle.fill"
        )
        AppShortcut(
            intent: ResumeWorkoutIntent(),
            phrases: [
                "Resume workout in \(.applicationName)",
                "Resume tracking in \(.applicationName)",
                "Continue workout in \(.applicationName)"
            ],
            shortTitle: "Resume Workout",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: GetWorkoutStatusIntent(),
            phrases: [
                "Get workout status in \(.applicationName)",
                "How is my workout in \(.applicationName)",
                "Show workout metrics from \(.applicationName)"
            ],
            shortTitle: "Workout Status",
            systemImageName: "chart.bar.fill"
        )
    }
}
