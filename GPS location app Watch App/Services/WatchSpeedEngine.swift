import Foundation

/// Which engine sets the watch's speed in Velocity Mode (build 80).
///
/// The engine itself is the iPhone's: LearnedSpeedEstimator.swift, SpeedNetwork.swift and
/// speed_network.json are exact copies, and scripts/check_watch_engine.sh stops a release when
/// they differ. Auto is therefore the iPhone's rule exactly - the bundled network until the store
/// holds NETWORK_UNTIL_OBSERVATIONS ground examples, the store after, and nothing when the one in
/// charge declines - with the iPhone's own relayed speed first while it is fresh.
///
/// Pinning one engine is for testing, so it is a developer option: with developer options off the
/// watch always runs Auto, whatever was pinned before.
enum WatchSpeedEngine: String, CaseIterable {
    case auto, network, store

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .network: return "Neural"
        case .store: return "Algorithm"
        }
    }

    static let defaultsKey = "watchSpeedEngine"
    /// The same key the iPhone uses for its hidden developer options, set here by tapping the
    /// version in the watch's Settings.
    static let developerKey = "developerUnlocked"

    static var developerUnlocked: Bool { UserDefaults.standard.bool(forKey: developerKey) }

    /// What the watch runs now: the pinned engine with developer options on, Auto otherwise.
    static var effective: WatchSpeedEngine {
        guard developerUnlocked else { return .auto }
        return WatchSpeedEngine(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .auto
    }
}
