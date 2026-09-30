import Foundation

/// Which engines the watch runs and records in Velocity Mode (build 82: a normal setting).
///
/// The engine itself is the iPhone's: LearnedSpeedEstimator.swift, SpeedNetwork.swift and
/// speed_network.json are exact copies, and scripts/check_watch_engine.sh stops a release when
/// they differ.
///
///   Both            both engines run and both are recorded; the speed follows the iPhone's rule -
///                   the bundled network until the store holds NETWORK_UNTIL_OBSERVATIONS ground
///                   examples, the store after, nothing when the one in charge declines - with the
///                   iPhone's own relayed speed first while it is fresh.
///   Neural only     only the network runs and is recorded; the Algorithm's lookup is not run.
///   Algorithm only  only the store answers and is recorded.
/// With one engine, the iPhone's relayed speed covers the seconds that engine cannot answer. The
/// fingerprint is recorded every second whichever is chosen, so the engine not run can be
/// replayed from the log later. The store keeps learning from GPS in a vehicle in every setting.
///
/// Stored under a new key: an engine pinned for testing under the old developer option must not
/// become the choice of everyone who updates, so the setting starts at Both.
enum WatchSpeedEngine: String, CaseIterable {
    case auto, network, store

    var title: String {
        switch self {
        case .auto: return "Both"
        case .network: return "Neural only"
        case .store: return "Algorithm only"
        }
    }

    var runsNetwork: Bool { self != .store }
    var runsStore: Bool { self != .network }

    static let defaultsKey = "watchSpeedEngineChoice"
    /// The same key the iPhone uses for its hidden developer options, set here by tapping the
    /// version in the watch's Settings.
    static let developerKey = "developerUnlocked"

    static var developerUnlocked: Bool { UserDefaults.standard.bool(forKey: developerKey) }

    /// What the watch runs now: the choice in Settings, Both until one is made.
    static var effective: WatchSpeedEngine {
        WatchSpeedEngine(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .auto
    }
}
