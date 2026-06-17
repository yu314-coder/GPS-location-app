import ActivityKit
import Foundation
import UIKit

// MARK: - Attributes (shared with widget extension)

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

// MARK: - Manager

@available(iOS 16.1, *)
final class DownloadLiveActivityManager {
    static let shared = DownloadLiveActivityManager()

    private var currentActivity: Activity<DownloadActivityAttributes>?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    private init() {}

    // MARK: - Background Task

    func beginBackgroundTask(name: String) {
        endBackgroundTask()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.endBackgroundTask()
        }
    }

    func endBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    // MARK: - Live Activity

    static var isSupported: Bool {
        if #available(iOS 16.1, *) {
            return ActivityAuthorizationInfo().areActivitiesEnabled
        }
        return false
    }

    func start(title: String, total: Int, message: String = "Starting...") {
        guard Self.isSupported else { return }

        if currentActivity != nil {
            update(progress: 0, total: total, message: message)
            return
        }

        let attributes = DownloadActivityAttributes(title: title, startTime: Date())
        let initialState = DownloadActivityAttributes.ContentState(
            progress: 0,
            total: total,
            message: message,
            isComplete: false
        )

        do {
            currentActivity = try Activity<DownloadActivityAttributes>.request(
                attributes: attributes,
                content: ActivityContent(state: initialState, staleDate: nil),
                pushType: nil
            )
            print("🟢 Download Live Activity started: \(currentActivity?.id ?? "unknown")")
        } catch {
            print("❌ Failed to start Download Live Activity: \(error.localizedDescription)")
        }
    }

    func update(progress: Int, total: Int, message: String) {
        guard let activity = currentActivity else { return }

        let state = DownloadActivityAttributes.ContentState(
            progress: progress,
            total: total,
            message: message,
            isComplete: false
        )

        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    func end(finalMessage: String) {
        guard let activity = currentActivity else { return }

        let state = DownloadActivityAttributes.ContentState(
            progress: 0,
            total: 0,
            message: finalMessage,
            isComplete: true
        )

        Task {
            await activity.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .after(Date().addingTimeInterval(4))
            )
            currentActivity = nil
            endBackgroundTask()
            print("🟢 Download Live Activity ended")
        }
    }
}
