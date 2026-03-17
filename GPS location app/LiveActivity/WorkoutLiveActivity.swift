import ActivityKit
import Foundation
import SwiftUI

// MARK: - Activity Attributes

struct WorkoutActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var duration: TimeInterval
        var distance: Double // in meters
        var speed: Double // in m/s
        var calories: Double
        var altitude: Double
        var heartRate: Double?
        var isPaused: Bool
    }

    var workoutType: String
    var startTime: Date
}

// MARK: - Live Activity Manager

@available(iOS 16.1, *)
class WorkoutLiveActivityManager {
    static let shared = WorkoutLiveActivityManager()

    private var currentActivity: Activity<WorkoutActivityAttributes>?

    private init() {}

    private func ensureCurrentActivity() -> Activity<WorkoutActivityAttributes>? {
        if let currentActivity {
            return currentActivity
        }
        if let existing = Activity<WorkoutActivityAttributes>.activities.first {
            currentActivity = existing
            print("🔄 Reattached to existing Live Activity: \(existing.id)")
            return existing
        }
        return nil
    }

    // Start Live Activity
    func startLiveActivity(workoutType: String) {
        if let existing = ensureCurrentActivity() {
            print("ℹ️ Reusing existing Live Activity: \(existing.id)")
            return
        }

        let attributes = WorkoutActivityAttributes(
            workoutType: workoutType,
            startTime: Date()
        )

        let initialState = WorkoutActivityAttributes.ContentState(
            duration: 0,
            distance: 0,
            speed: 0,
            calories: 0,
            altitude: 0,
            heartRate: nil,
            isPaused: false
        )

        do {
            currentActivity = try Activity<WorkoutActivityAttributes>.request(
                attributes: attributes,
                content: ActivityContent(state: initialState, staleDate: nil),
                pushType: nil
            )
            print("🔴 Live Activity started: \(currentActivity?.id ?? "unknown")")
        } catch {
            print("❌ Failed to start Live Activity: \(error.localizedDescription)")
        }
    }

    // Update Live Activity
    func updateLiveActivity(
        duration: TimeInterval,
        distance: Double,
        speed: Double,
        calories: Double,
        altitude: Double,
        heartRate: Double?,
        isPaused: Bool
    ) {
        guard let activity = ensureCurrentActivity() else {
            print("⚠️ No active Live Activity to update")
            return
        }

        let updatedState = WorkoutActivityAttributes.ContentState(
            duration: duration,
            distance: distance,
            speed: speed,
            calories: calories,
            altitude: altitude,
            heartRate: heartRate,
            isPaused: isPaused
        )

        Task {
            await activity.update(ActivityContent(state: updatedState, staleDate: nil))
        }
    }

    // End Live Activity
    func endLiveActivity(
        finalDuration: TimeInterval,
        finalDistance: Double,
        finalCalories: Double
    ) {
        guard let activity = ensureCurrentActivity() else { return }

        let finalState = WorkoutActivityAttributes.ContentState(
            duration: finalDuration,
            distance: finalDistance,
            speed: 0,
            calories: finalCalories,
            altitude: 0,
            heartRate: nil,
            isPaused: false
        )

        Task {
            await activity.end(
                ActivityContent(state: finalState, staleDate: nil),
                dismissalPolicy: .default
            )
            // Clear activity reference after ending for memory safety
            currentActivity = nil
            print("🔴 Live Activity ended")
        }
    }

    // Check if Live Activity is available
    static var isSupported: Bool {
        if #available(iOS 16.1, *) {
            return ActivityAuthorizationInfo().areActivitiesEnabled
        }
        return false
    }
}

// MARK: - Live Activity Views
// IMPORTANT: To show custom UI in Dynamic Island (instead of notification center):
// You MUST create a Widget Extension in Xcode. Follow these steps:

/*
 SETUP INSTRUCTIONS FOR DYNAMIC ISLAND:

 1. In Xcode, File → New → Target
 2. Select "Widget Extension"
 3. Name it "WorkoutWidget"
 4. Deselect "Include Configuration Intent"
 5. Click Finish

 6. In the new WorkoutWidget folder, replace the generated code with this:

 ```swift
 import ActivityKit
 import WidgetKit
 import SwiftUI

 struct WorkoutLiveActivity: Widget {
     var body: some WidgetConfiguration {
         ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
             // Lock screen view
             WorkoutLockScreenView(context: context)
         } dynamicIsland: { context in
             DynamicIsland {
                 // Expanded view
                 DynamicIslandExpandedRegion(.leading) {
                     HStack {
                         Image(systemName: "figure.walk")
                         Text(context.state.isPaused ? "Paused" : "Active")
                             .font(.caption)
                     }
                 }
                 DynamicIslandExpandedRegion(.trailing) {
                     Text(formatDuration(context.state.duration))
                         .font(.title3)
                         .fontWeight(.bold)
                 }
                 DynamicIslandExpandedRegion(.bottom) {
                     VStack(spacing: 8) {
                         HStack {
                             MetricView(
                                 icon: "arrow.triangle.swap",
                                 value: String(format: "%.2f", context.state.distance / 1000),
                                 unit: "km"
                             )
                             MetricView(
                                 icon: "speedometer",
                                 value: String(format: "%.1f", context.state.speed * 3.6),
                                 unit: "km/h"
                             )
                             MetricView(
                                 icon: "flame.fill",
                                 value: String(format: "%.0f", context.state.calories),
                                 unit: "kcal"
                             )
                         }
                     }
                     .padding(.horizontal)
                 }
             } compactLeading: {
                 // Compact leading (left side of Dynamic Island)
                 Image(systemName: "figure.walk")
                     .foregroundColor(.green)
             } compactTrailing: {
                 // Compact trailing (right side of Dynamic Island)
                 Text(formatDuration(context.state.duration))
                     .font(.caption2)
                     .fontWeight(.bold)
             } minimal: {
                 // Minimal view (when multiple Live Activities)
                 Image(systemName: "figure.walk")
             }
         }
     }

     private func formatDuration(_ duration: TimeInterval) -> String {
         let minutes = Int(duration) / 60
         let seconds = Int(duration) % 60
         return String(format: "%02d:%02d", minutes, seconds)
     }
 }

 struct MetricView: View {
     let icon: String
     let value: String
     let unit: String

     var body: some View {
         VStack(spacing: 2) {
             HStack(spacing: 2) {
                 Image(systemName: icon)
                     .font(.caption2)
                 Text(value)
                     .font(.caption)
                     .fontWeight(.bold)
             }
             Text(unit)
                 .font(.caption2)
                 .foregroundColor(.secondary)
         }
     }
 }

 struct WorkoutLockScreenView: View {
     let context: ActivityViewContext<WorkoutActivityAttributes>

     var body: some View {
         VStack(spacing: 12) {
             HStack {
                 Image(systemName: "figure.walk")
                 Text(context.attributes.workoutType)
                     .font(.headline)
                 Spacer()
                 Text(context.state.isPaused ? "PAUSED" : "LIVE")
                     .font(.caption)
                     .padding(.horizontal, 8)
                     .padding(.vertical, 4)
                     .background(context.state.isPaused ? Color.orange : Color.green)
                     .cornerRadius(8)
             }

             HStack {
                 VStack(alignment: .leading) {
                     Text("Distance")
                         .font(.caption)
                         .foregroundColor(.secondary)
                     Text(String(format: "%.2f km", context.state.distance / 1000))
                         .font(.title3)
                         .fontWeight(.bold)
                 }
                 Spacer()
                 VStack(alignment: .trailing) {
                     Text("Duration")
                         .font(.caption)
                         .foregroundColor(.secondary)
                     Text(formatDuration(context.state.duration))
                         .font(.title3)
                         .fontWeight(.bold)
                 }
             }

             HStack {
                 MetricPill(icon: "speedometer", value: String(format: "%.1f km/h", context.state.speed * 3.6))
                 MetricPill(icon: "flame.fill", value: String(format: "%.0f kcal", context.state.calories))
                 MetricPill(icon: "mountain.2", value: String(format: "%.0f m", context.state.altitude))
             }
         }
         .padding()
     }

     private func formatDuration(_ duration: TimeInterval) -> String {
         let hours = Int(duration) / 3600
         let minutes = Int(duration) / 60 % 60
         let seconds = Int(duration) % 60

         if hours > 0 {
             return String(format: "%d:%02d:%02d", hours, minutes, seconds)
         } else {
             return String(format: "%02d:%02d", minutes, seconds)
         }
     }
 }

 struct MetricPill: View {
     let icon: String
     let value: String

     var body: some View {
         HStack(spacing: 4) {
             Image(systemName: icon)
                 .font(.caption2)
             Text(value)
                 .font(.caption)
         }
         .padding(.horizontal, 8)
         .padding(.vertical, 4)
         .background(Color(.systemGray5))
         .cornerRadius(8)
     }
 }

*/
