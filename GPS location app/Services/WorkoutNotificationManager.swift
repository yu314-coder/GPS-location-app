import Foundation
import UserNotifications
import UIKit

class WorkoutNotificationManager: NSObject {
    static let shared = WorkoutNotificationManager()

    private let notificationIdentifier = "workout_progress"
    private var updateTimer: Timer?
    private var isActive = false

    private override init() {
        super.init()
    }

    // Request notification permission
    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("❌ Notification permission error: \(error.localizedDescription)")
            }
            print(granted ? "✅ Notification permission granted" : "⚠️ Notification permission denied")
            completion(granted)
        }
    }

    // Start showing workout notifications
    func startWorkoutNotifications(workoutSession: WorkoutSession) {
        print("🔔 Starting workout notifications")
        isActive = true

        // Update notification every 10 seconds
        updateTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self, weak workoutSession] _ in
            guard let self = self, let session = workoutSession, self.isActive else { return }
            self.updateWorkoutNotification(session: session)
        }

        // Send initial notification
        updateWorkoutNotification(session: workoutSession)
    }

    // Stop workout notifications
    func stopWorkoutNotifications() {
        print("🔔 Stopping workout notifications")
        isActive = false
        updateTimer?.invalidate()
        updateTimer = nil

        // Remove all notifications
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
    }

    // Update notification with current workout stats
    private func updateWorkoutNotification(session: WorkoutSession) {
        guard isActive else { return }

        let metrics = session.currentMetrics
        let duration = session.activeDuration

        // Format values
        let distance = String(format: "%.2f km", metrics.totalDistance / 1000.0)
        let speed = String(format: "%.1f km/h", metrics.smoothedSpeed * 3.6)
        let avgSpeed = String(format: "%.1f km/h", metrics.averageSpeed * 3.6)
        let durationStr = formatDuration(duration)
        let altitude = String(format: "%.0f m", metrics.currentAltitude)
        let calories = String(format: "%.0f kcal", metrics.caloriesBurned)

        // Create notification content
        let content = UNMutableNotificationContent()
        content.title = "🏃 Workout in Progress"
        content.subtitle = durationStr
        content.body = """
        Distance: \(distance)
        Speed: \(speed) (Avg: \(avgSpeed))
        Altitude: \(altitude)
        Calories: \(calories)
        GPS Points: \(session.flight.locations.count)
        """
        content.sound = nil // Silent update
        content.categoryIdentifier = "WORKOUT_PROGRESS"
        content.threadIdentifier = "workout"

        // Add action buttons
        let pauseAction = UNNotificationAction(
            identifier: "PAUSE_ACTION",
            title: session.isPaused ? "Resume" : "Pause",
            options: []
        )
        let stopAction = UNNotificationAction(
            identifier: "STOP_ACTION",
            title: "Stop",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: "WORKOUT_PROGRESS",
            actions: [pauseAction, stopAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])

        // Schedule notification (replace existing)
        let request = UNNotificationRequest(
            identifier: notificationIdentifier,
            content: content,
            trigger: nil // Immediate delivery
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Failed to show notification: \(error.localizedDescription)")
            }
        }
    }

    // Show completion notification
    func showCompletionNotification(metrics: FlightMetrics, duration: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = "✅ Workout Complete!"
        content.subtitle = "Great job!"

        let distance = String(format: "%.2f km", metrics.totalDistance / 1000.0)
        let avgSpeed = String(format: "%.1f km/h", metrics.averageSpeed * 3.6)
        let durationStr = formatDuration(duration)
        let calories = String(format: "%.0f kcal", metrics.caloriesBurned)

        content.body = """
        Duration: \(durationStr)
        Distance: \(distance)
        Avg Speed: \(avgSpeed)
        Calories: \(calories)
        """
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "workout_complete",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Failed to show completion notification: \(error.localizedDescription)")
            }
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) / 60 % 60
        let seconds = Int(duration) % 60

        if hours > 0 {
            return String(format: "%dh %dm %ds", hours, minutes, seconds)
        } else if minutes > 0 {
            return String(format: "%dm %ds", minutes, seconds)
        } else {
            return String(format: "%ds", seconds)
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension WorkoutNotificationManager: UNUserNotificationCenterDelegate {
    // Handle notification actions
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        switch response.actionIdentifier {
        case "PAUSE_ACTION":
            print("🔔 User tapped Pause from notification")
            // Post notification to pause workout
            NotificationCenter.default.post(name: NSNotification.Name("PauseWorkoutFromNotification"), object: nil)

        case "STOP_ACTION":
            print("🔔 User tapped Stop from notification")
            // Post notification to stop workout
            NotificationCenter.default.post(name: NSNotification.Name("StopWorkoutFromNotification"), object: nil)

        case UNNotificationDefaultActionIdentifier:
            print("🔔 User opened workout notification")
            if isActive || WorkoutSession.shared.isActive {
                NotificationCenter.default.post(name: .openLiveSessionRequested, object: nil)
            }

        default:
            break
        }

        completionHandler()
    }

    // Allow notifications while app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Show notification even when app is in foreground
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .list])
        } else {
            completionHandler([.alert])
        }
    }
}
