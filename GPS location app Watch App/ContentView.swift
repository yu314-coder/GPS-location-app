//
//  ContentView.swift
//  GPS location app Watch App
//
//  GPS location app
//

import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0
    @State private var showLiveSession = false
    @StateObject private var locationManager = LocationManager()
    @StateObject private var healthKitManager = HealthKitManager()
    @AppStorage(WatchSpeedEngine.developerKey) private var developerUnlocked = false

    var body: some View {
        TabView(selection: $selectedTab) {
            // Home Tab
            WatchHomeView(showLiveSession: $showLiveSession)
                .tag(0)

            // History Tab
            FlightHistoryView()
                .tag(1)

            // Settings Tab
            SettingsView()
                .tag(2)

            // HealthKit simulation test: a developer tool, so only with the developer options on.
            if developerUnlocked {
                HealthKitSimulationTestView()
                    .tag(3)
            }
        }
        .tabViewStyle(.page)
        .sheet(isPresented: $showLiveSession) {
            LiveSessionView()
        }
        .onAppear {
            requestPermissions()
            // A workout the watch never stopped (the app ended mid-workout) is finished and sent
            // to the iPhone now, not only when the next workout begins.
            WorkoutSession.finalizeUnfinishedFlightsAtLaunch()
            // DEBUG: `-replayFlight` drives a synthesized flight through the real dead-reckoning
            // pipeline and opens the live view, so Force Velocity can be seen on the watch
            // simulator (which has no Core Motion). Inert without the argument.
            if ProcessInfo.processInfo.arguments.contains("-replayFlight") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    showLiveSession = true   // the live view's own session runs the replay
                }
            }
        }
    }

    private func requestPermissions() {
        // Request location permission
        locationManager.requestAuthorization()
        print("📍 Requested location permission")

        // Request HealthKit permission - wrap in error handling
        healthKitManager.requestAuthorization { success, error in
            if let error = error {
                print("❌ HealthKit authorization failed: \(error.localizedDescription)")
            } else if success {
                print("✅ HealthKit authorization successful")
            } else {
                print("⚠️ HealthKit authorization was not granted")
            }
        }
    }
}

struct WatchHomeView: View {
    @Binding var showLiveSession: Bool
    @StateObject private var connectivityManager = WatchConnectivityManager.shared

    var body: some View {
        // DISABLED: Watch no longer mirrors iPhone workouts
        // Both devices run workouts independently now
        normalHomeView
    }

    private var normalHomeView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "location.north.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Velocity")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                        Text("Routes with or without GPS")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    showLiveSession = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill").font(.system(size: 18, weight: .bold))
                        Text("New workout").font(.system(size: 17, weight: .bold, design: .rounded))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.green, in: Capsule())
                    .foregroundStyle(.black)
                }
                .buttonStyle(.plain)

                // The iPhone leads the speed in Auto while it is reachable.
                HStack(spacing: 8) {
                    Image(systemName: connectivityManager.isReachable ? "iphone.radiowaves.left.and.right" : "iphone.slash")
                        .foregroundStyle(connectivityManager.isReachable ? .blue : .secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(connectivityManager.isReachable ? "iPhone connected" : "iPhone not reachable")
                            .font(.system(size: 13, weight: .semibold))
                        Text(connectivityManager.isReachable ? "Its speed leads in Auto" : "The watch uses its own engines")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))

                SpeedEngineStatusCard()

                Text("Swipe for history and settings")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - Watch Feature Pill
struct WatchFeaturePill: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(color)
                .frame(width: 20)

            Text(text)
                .font(.caption2)
                .foregroundColor(.primary)

            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(color.opacity(0.15))
        )
    }

    // REMOVED: iPhone workout mirror view
    // Watch and iPhone now run completely independent workouts
}

#Preview {
    ContentView()
}
