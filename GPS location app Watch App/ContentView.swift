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

            // HealthKit Simulation Test Tab
            HealthKitSimulationTestView()
                .tag(3)
        }
        .tabViewStyle(.page)
        .sheet(isPresented: $showLiveSession) {
            LiveSessionView()
        }
        .onAppear {
            requestPermissions()
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
            VStack(spacing: 20) {
                Spacer().frame(height: 8)

                // App Icon with gradient
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.3), Color.purple.opacity(0.2)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 70, height: 70)
                        .blur(radius: 15)

                    Image(systemName: "figure.run.circle.fill")
                        .font(.system(size: 55))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .padding(.top, 8)

                Text("Workout Tracker")
                    .font(.system(size: 16, weight: .bold, design: .rounded))

                // Modern Start Button
                Button(action: {
                    showLiveSession = true
                }) {
                    VStack(spacing: 6) {
                        Image(systemName: "play.circle.fill")
                            .font(.title2)
                        Text("Start Tracking")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: [Color.green, Color.green.opacity(0.8)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .foregroundColor(.white)
                    .cornerRadius(20)
                }
                .buttonStyle(.plain)

                // Feature Pills
                VStack(spacing: 8) {
                    WatchFeaturePill(icon: "location.fill", text: "GPS Tracking", color: .blue)
                    WatchFeaturePill(icon: "heart.fill", text: "HealthKit Sync", color: .red)

                    // Connection status
                    if connectivityManager.isReachable {
                        HStack(spacing: 6) {
                            Image(systemName: "iphone.radiowaves.left.and.right")
                                .font(.caption2)
                            Text("iPhone Connected")
                                .font(.caption2)
                        }
                        .foregroundColor(.green)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(Color.green.opacity(0.15))
                        .cornerRadius(12)
                    }
                }

                Spacer().frame(height: 8)
            }
            .padding(.horizontal)
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
