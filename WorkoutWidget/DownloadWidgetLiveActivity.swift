//
//  DownloadWidgetLiveActivity.swift
//  WorkoutWidget
//

#if canImport(ActivityKit) && !os(watchOS)
import ActivityKit
import WidgetKit
import SwiftUI

// MARK: - Attributes (mirror of main app)

struct DownloadActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var progress: Int
        var total: Int
        var message: String
        var isComplete: Bool
    }

    var title: String
    var startTime: Date
}

// MARK: - Live Activity Widget

struct DownloadWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            // Lock screen / banner UI
            DownloadLockScreenView(context: context)
                .activityBackgroundTint(Color(.systemBackground))
                .activitySystemActionForegroundColor(.green)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: context.state.isComplete ? "checkmark.circle.fill" : "square.and.arrow.down.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.attributes.title)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                            Text(context.state.isComplete ? "Complete" : "Downloading")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.total > 0 {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(context.state.progress)/\(context.state.total)")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .monospacedDigit()
                            Text("\(percent(context.state))%")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        if context.state.total > 0 {
                            ProgressView(value: Double(context.state.progress), total: Double(max(context.state.total, 1)))
                                .progressViewStyle(.linear)
                                .tint(.green)
                        }
                        Text(context.state.message)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: context.state.isComplete ? "checkmark.circle.fill" : "square.and.arrow.down.fill")
                    .foregroundColor(.green)
            } compactTrailing: {
                if context.state.total > 0 {
                    Text("\(percent(context.state))%")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .monospacedDigit()
                        .foregroundColor(.green)
                } else {
                    Text("…")
                        .font(.caption2)
                }
            } minimal: {
                ZStack {
                    Circle()
                        .stroke(Color.green.opacity(0.25), lineWidth: 2)
                    if context.state.total > 0 {
                        Circle()
                            .trim(from: 0, to: CGFloat(context.state.progress) / CGFloat(max(context.state.total, 1)))
                            .stroke(Color.green, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    Image(systemName: "arrow.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.green)
                }
                .frame(width: 18, height: 18)
            }
            .keylineTint(.green)
        }
    }

    private func percent(_ state: DownloadActivityAttributes.ContentState) -> Int {
        guard state.total > 0 else { return 0 }
        return Int(Double(state.progress) / Double(state.total) * 100)
    }
}

// MARK: - Lock Screen View

struct DownloadLockScreenView: View {
    let context: ActivityViewContext<DownloadActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: context.state.isComplete ? "checkmark.circle.fill" : "square.and.arrow.down.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(context.state.message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if context.state.total > 0 {
                    Text("\(percent)%")
                        .font(.title3)
                        .fontWeight(.bold)
                        .monospacedDigit()
                        .foregroundColor(.green)
                }
            }

            if context.state.total > 0 {
                ProgressView(value: Double(context.state.progress), total: Double(max(context.state.total, 1)))
                    .progressViewStyle(.linear)
                    .tint(.green)

                Text("\(context.state.progress) of \(context.state.total)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var percent: Int {
        guard context.state.total > 0 else { return 0 }
        return Int(Double(context.state.progress) / Double(context.state.total) * 100)
    }
}

#Preview("Download", as: .content, using: DownloadActivityAttributes(title: "Downloading Workouts", startTime: Date())) {
    DownloadWidgetLiveActivity()
} contentStates: {
    DownloadActivityAttributes.ContentState(progress: 24, total: 100, message: "Downloading routes from HealthKit", isComplete: false)
    DownloadActivityAttributes.ContentState(progress: 100, total: 100, message: "Done: 95 downloaded, 5 skipped", isComplete: true)
}
#endif
