import Foundation

/// Thermal-aware pacing for bulk downloads (HealthKit route fetches + JSON saves).
/// Running many concurrent fetches cooks the phone; iOS then kills the app for
/// overheating. These helpers shrink concurrency and insert cooldown pauses as
/// the device heats up so downloads stay alive instead of crashing.
enum ThermalDownloadPacing {

    /// Concurrent route fetches allowed for the current thermal state.
    /// Conservative baseline — prevents the phone from heating up in the first
    /// place rather than only reacting once it's already hot.
    static var concurrency: Int {
        switch ProcessInfo.processInfo.thermalState {
        case .critical: return 1
        case .serious: return 1
        case .fair: return 2
        default: return 3
        }
    }

    /// Cooldown to insert between batches (nanoseconds). Larger when hot so the
    /// SoC can shed heat between bursts of work.
    static var batchCooldownNanos: UInt64 {
        switch ProcessInfo.processInfo.thermalState {
        case .critical: return 3_000_000_000   // 3s
        case .serious: return 1_500_000_000    // 1.5s
        case .fair: return 500_000_000         // 0.5s
        default: return 150_000_000            // 0.15s — always some breathing room
        }
    }

    /// True when the device is too hot to keep downloading and the loop should
    /// pause and wait for it to cool.
    static var shouldPauseForHeat: Bool {
        ProcessInfo.processInfo.thermalState == .critical
    }

    /// Awaitable cooldown between batches; no-op when nominal.
    static func cooldown() async {
        let nanos = batchCooldownNanos
        if nanos > 0 {
            try? await Task.sleep(nanoseconds: nanos)
        }
    }

    /// When critical, wait (checking periodically) until the device cools below
    /// critical or the task is cancelled.
    static func waitWhileCritical() async {
        while shouldPauseForHeat && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000_000) // re-check every 3s
        }
    }
}
