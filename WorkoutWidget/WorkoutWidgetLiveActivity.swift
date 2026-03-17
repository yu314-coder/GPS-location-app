//
//  WorkoutWidgetLiveActivity.swift
//  WorkoutWidget
//
//  GPS location app
//

#if canImport(ActivityKit) && !os(watchOS)
import ActivityKit
import WidgetKit
import SwiftUI

// MARK: - Activity Attributes (shared with main app)

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

// MARK: - Live Activity Widget

struct WorkoutWidgetLiveActivity: Widget {
    private let liveActivityDeepLink = URL(string: "gpslocationapp://live")!

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            // Lock screen/banner UI
            WorkoutLockScreenView(context: context)
                .widgetURL(liveActivityDeepLink)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI - shown when user long-presses the Dynamic Island
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        // App icon
                        Image(systemName: "location.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.green)
                            .symbolRenderingMode(.hierarchical)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.attributes.workoutType)
                                .font(.caption)
                                .fontWeight(.semibold)
                            Text(context.state.isPaused ? "Paused" : "Active")
                                .font(.caption2)
                                .foregroundColor(context.state.isPaused ? .orange : .green)
                        }
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.isPaused {
                        Text(formatDuration(context.state.duration))
                            .font(.title3)
                            .fontWeight(.bold)
                            .monospacedDigit()
                    } else {
                        Text(timerAnchorDate(for: context.state.duration), style: .timer)
                            .font(.title3)
                            .fontWeight(.bold)
                            .monospacedDigit()
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        HStack(spacing: 12) {
                            MetricView(
                                icon: "arrow.left.arrow.right",
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

                        if let heartRate = context.state.heartRate, heartRate > 0 {
                            HStack(spacing: 12) {
                                MetricView(
                                    icon: "heart.fill",
                                    value: String(format: "%.0f", heartRate),
                                    unit: "bpm"
                                )

                                MetricView(
                                    icon: "mountain.2",
                                    value: String(format: "%.0f", context.state.altitude),
                                    unit: "m"
                                )
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            } compactLeading: {
                // App icon in Dynamic Island (compact leading)
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.22))
                    Image(systemName: "location.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.green)
                }
                .frame(width: 20, height: 20)
            } compactTrailing: {
                // Timer in Dynamic Island (compact trailing)
                if context.state.isPaused {
                    Text(formatDuration(context.state.duration))
                        .font(.caption2)
                        .fontWeight(.bold)
                        .monospacedDigit()
                        .foregroundColor(.orange)
                } else {
                    Text(timerAnchorDate(for: context.state.duration), style: .timer)
                        .font(.caption2)
                        .fontWeight(.bold)
                        .monospacedDigit()
                        .foregroundColor(.primary)
                }
            } minimal: {
                // App icon when multiple Live Activities are active
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.22))
                    Image(systemName: "location.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.green)
                }
                .frame(width: 18, height: 18)
            }
            .widgetURL(liveActivityDeepLink)
            .keylineTint(.green)
        }
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

    private func timerAnchorDate(for elapsedDuration: TimeInterval) -> Date {
        Date().addingTimeInterval(-max(0, elapsedDuration))
    }
}

// MARK: - Metric View

struct MetricView: View {
    let icon: String
    let value: String
    let unit: String

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.caption)
                    .fontWeight(.bold)
                    .monospacedDigit()
            }
            Text(unit)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Lock Screen View

struct WorkoutLockScreenView: View {
    let context: ActivityViewContext<WorkoutActivityAttributes>

    var body: some View {
        // Simple timer-style view like native Timer/Workout apps
        HStack(spacing: 12) {
            // App icon
            Image(systemName: "location.circle.fill")
                .font(.system(size: 24))
                .foregroundColor(.green)
                .symbolRenderingMode(.hierarchical)

            VStack(alignment: .leading, spacing: 2) {
                // Workout type
                Text(context.attributes.workoutType)
                    .font(.subheadline)
                    .fontWeight(.semibold)

                // Timer - Large and prominent
                HStack(spacing: 4) {
                    if context.state.isPaused {
                        Text(formatDuration(context.state.duration))
                            .font(.system(size: 32, weight: .medium, design: .rounded))
                            .monospacedDigit()
                    } else {
                        Text(timerAnchorDate(for: context.state.duration), style: .timer)
                            .font(.system(size: 32, weight: .medium, design: .rounded))
                            .monospacedDigit()
                    }

                    if context.state.isPaused {
                        Image(systemName: "pause.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.orange)
                    }
                }
            }

            Spacer()

            // Quick stats
            VStack(alignment: .trailing, spacing: 4) {
                Text(String(format: "%.2f km", context.state.distance / 1000))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .monospacedDigit()

                Text(String(format: "%.1f km/h", context.state.speed * 3.6))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .activityBackgroundTint(Color(.systemBackground))
        .activitySystemActionForegroundColor(.green)
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

    private func timerAnchorDate(for elapsedDuration: TimeInterval) -> Date {
        Date().addingTimeInterval(-max(0, elapsedDuration))
    }
}

// MARK: - Previews

#Preview("Notification", as: .content, using: WorkoutActivityAttributes(workoutType: "Paragliding", startTime: Date())) {
    WorkoutWidgetLiveActivity()
} contentStates: {
    WorkoutActivityAttributes.ContentState(
        duration: 125,
        distance: 1500,
        speed: 8.33,
        calories: 45,
        altitude: 850,
        heartRate: 142,
        isPaused: false
    )

    WorkoutActivityAttributes.ContentState(
        duration: 300,
        distance: 3200,
        speed: 0,
        calories: 95,
        altitude: 1200,
        heartRate: 138,
        isPaused: true
    )
}
#endif
