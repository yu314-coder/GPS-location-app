//
//  ContentView.swift
//  GPS location app
//
//  GPS location app
//

import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0
    @State private var showLiveSession = false

    var body: some View {
        TabView(selection: $selectedTab) {
            // Home Tab
            HomeView(showLiveSession: $showLiveSession)
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
                .tag(0)

            // History Tab
            EnhancedFlightHistoryView()
                .tabItem {
                    Label("Flights", systemImage: "airplane")
                }
                .tag(1)

            // Map Tab
            WorkoutMapView()
                .tabItem {
                    Label("Map", systemImage: "map.fill")
                }
                .tag(2)

            // Analysis Tab
            AnalysisView()
                .tabItem {
                    Label("Analysis", systemImage: "chart.xyaxis.line")
                }
                .tag(3)

            // Test Tab - FOR DEBUGGING PERMISSIONS
            PermissionTestView()
                .tabItem {
                    Label("Test", systemImage: "wrench.and.screwdriver")
                }
                .tag(4)

            // Settings Tab
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(5)
        }
        .sheet(isPresented: $showLiveSession) {
            LiveSessionView()
                .interactiveDismissDisabled(true) // Prevent swipe-to-dismiss
                .presentationDetents([.large]) // Full screen for stability
                .presentationDragIndicator(.hidden) // Hide drag indicator since it can't be dismissed
        }
        .onAppear {
            print("✅ ContentView appeared successfully")
        }
        .onOpenURL { url in
            handleDeepLink(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openLiveSessionRequested)) { _ in
            selectedTab = 0
            showLiveSession = true
            print("✅ Opened Live Session from notification request")
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "gpslocationapp" else { return }

        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        if host == "live" || path == "/live" {
            selectedTab = 0
            showLiveSession = true
            print("✅ Opened Live Session from deep link: \(url.absoluteString)")
        }
    }
}

struct HomeView: View {
    @Binding var showLiveSession: Bool
    @State private var isAnimating = false

    var body: some View {
        NavigationView {
            ZStack {
                // Gradient background
                LinearGradient(
                    colors: [
                        Color.blue.opacity(0.1),
                        Color.purple.opacity(0.05),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 40) {
                        Spacer().frame(height: 20)

                        // Hero Section
                        VStack(spacing: 24) {
                            // App Logo/Icon with animation
                            ZStack {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.blue, Color.purple],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 120, height: 120)
                                    .blur(radius: 20)
                                    .opacity(0.6)
                                    .scaleEffect(isAnimating ? 1.1 : 0.9)
                                    .animation(
                                        Animation.easeInOut(duration: 2.0)
                                            .repeatForever(autoreverses: true),
                                        value: isAnimating
                                    )

                                Image(systemName: "airplane.circle.fill")
                                    .font(.system(size: 100))
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [.blue, .purple],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .shadow(color: .blue.opacity(0.3), radius: 10, x: 0, y: 5)
                            }

                            VStack(spacing: 12) {
                                Text("Flight GPS Tracker")
                                    .font(.system(size: 34, weight: .bold, design: .rounded))
                                    .multilineTextAlignment(.center)

                                Text("Track your flights with precision GPS technology")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal)
                            }
                        }

                        // Start Tracking Button with gradient
                        Button(action: {
                            showLiveSession = true
                        }) {
                            HStack(spacing: 12) {
                                Image(systemName: "play.circle.fill")
                                    .font(.title2)
                                Text("Start Flight Tracking")
                                    .font(.headline)
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(
                                LinearGradient(
                                    colors: [Color.blue, Color.blue.opacity(0.8)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .foregroundColor(.white)
                            .cornerRadius(16)
                            .shadow(color: .blue.opacity(0.4), radius: 15, x: 0, y: 8)
                        }
                        .padding(.horizontal)

                        // Feature Cards
                        VStack(spacing: 16) {
                            HStack(spacing: 12) {
                                ModernInfoCard(
                                    icon: "location.fill",
                                    title: "GPS Filtering",
                                    description: "Kalman filtered coordinates",
                                    color: .green
                                )

                                ModernInfoCard(
                                    icon: "heart.text.square.fill",
                                    title: "HealthKit",
                                    description: "Auto-sync to Fitness",
                                    color: .red
                                )
                            }

                            HStack(spacing: 12) {
                                ModernInfoCard(
                                    icon: "waveform.path.ecg",
                                    title: "Real-time",
                                    description: "Live metrics tracking",
                                    color: .orange
                                )

                                ModernInfoCard(
                                    icon: "chart.xyaxis.line",
                                    title: "Analytics",
                                    description: "Detailed statistics",
                                    color: .purple
                                )
                            }
                        }
                        .padding(.horizontal)

                        Spacer().frame(height: 20)
                    }
                }
            }
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                isAnimating = true
            }
        }
    }
}

// Modern Info Card with gradient and glassmorphism
struct ModernInfoCard: View {
    let icon: String
    let title: String
    let description: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 50, height: 50)

                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(color)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: color.opacity(0.1), radius: 8, x: 0, y: 4)
        )
    }
}

struct InfoCard: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.blue)

            Text(title)
                .font(.caption)
                .fontWeight(.semibold)

            Text(description)
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

// MARK: - Permissions Onboarding View

struct PermissionsOnboardingView: View {
    @ObservedObject var locationManager: LocationManager
    @ObservedObject var healthKitManager: HealthKitManager
    @Binding var isPresented: Bool
    @AppStorage("hasRequestedPermissions") private var hasRequestedPermissions = false

    @State private var currentPage = 0
    @State private var locationPermissionGranted = false
    @State private var healthKitPermissionGranted = false

    var body: some View {
        NavigationView {
            VStack(spacing: 30) {
                // Progress indicator
                HStack(spacing: 8) {
                    ForEach(0..<3) { index in
                        Circle()
                            .fill(index <= currentPage ? Color.blue : Color.gray.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                }
                .padding(.top)

                // Content based on current page
                TabView(selection: $currentPage) {
                    // Page 0: Welcome
                    WelcomePermissionPage()
                        .tag(0)

                    // Page 1: Location Permission
                    LocationPermissionPage(
                        locationManager: locationManager,
                        isGranted: $locationPermissionGranted
                    )
                    .tag(1)

                    // Page 2: HealthKit Permission
                    HealthKitPermissionPage(
                        healthKitManager: healthKitManager,
                        isGranted: $healthKitPermissionGranted
                    )
                    .tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                // Navigation buttons
                HStack(spacing: 16) {
                    if currentPage > 0 {
                        Button("Back") {
                            withAnimation {
                                currentPage -= 1
                            }
                        }
                        .foregroundColor(.blue)
                    }

                    Spacer()

                    Button(currentPage == 2 ? "Done" : "Next") {
                        if currentPage == 2 {
                            hasRequestedPermissions = true
                            isPresented = false
                        } else {
                            withAnimation {
                                currentPage += 1
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Skip") {
                        hasRequestedPermissions = true
                        isPresented = false
                    }
                    .foregroundColor(.secondary)
                }
            }
        }
    }
}

struct WelcomePermissionPage: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "airplane.circle.fill")
                .font(.system(size: 100))
                .foregroundColor(.blue)

            Text("Welcome to Flight GPS Tracker")
                .font(.title)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)

            Text("To track your flights accurately, we need a couple of permissions")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 16) {
                PermissionRow(
                    icon: "location.fill",
                    title: "Location Access",
                    description: "Track your flight path with GPS"
                )

                PermissionRow(
                    icon: "heart.fill",
                    title: "HealthKit Access",
                    description: "Save workouts and heart rate data"
                )
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }
}

struct LocationPermissionPage: View {
    @ObservedObject var locationManager: LocationManager
    @Binding var isGranted: Bool
    @State private var showUpgradeButton = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "location.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.blue)

            Text("Location Access")
                .font(.title2)
                .fontWeight(.bold)

            Text(instructionText)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 12) {
                InfoRow(text: "Continuous GPS tracking during flight")
                InfoRow(text: "Background location updates")
                InfoRow(text: "Accurate altitude and speed data")
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
            .padding(.horizontal)

            // Button based on permission state
            if locationManager.authorizationStatus == .notDetermined {
                Button(action: {
                    // Step 1: Request "When In Use" first (iOS 13+ requirement)
                    locationManager.requestAuthorization()
                    // Check status after a delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        isGranted = locationManager.authorizationStatus == .authorizedAlways ||
                                   locationManager.authorizationStatus == .authorizedWhenInUse
                        showUpgradeButton = locationManager.authorizationStatus == .authorizedWhenInUse
                    }
                }) {
                    Text("Grant Location Permission")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .padding(.horizontal)
            } else if locationManager.authorizationStatus == .authorizedWhenInUse {
                VStack(spacing: 16) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.orange)
                        Text("Permission granted: When In Use")
                            .foregroundColor(.secondary)
                    }

                    // Upgrade button
                    Button(action: {
                        // Step 2: Upgrade to "Always"
                        locationManager.requestAlwaysAuthorization()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            showUpgradeButton = locationManager.authorizationStatus != .authorizedAlways
                        }
                    }) {
                        VStack(spacing: 8) {
                            Text("Upgrade to \"Always Allow\"")
                                .fontWeight(.semibold)
                            Text("Recommended for background tracking")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .padding(.horizontal)
                }
            } else {
                HStack {
                    Image(systemName: locationManager.authorizationStatus == .authorizedAlways ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(locationManager.authorizationStatus == .authorizedAlways ? .green : .red)

                    Text(statusText)
                        .foregroundColor(.secondary)
                }
                .padding()
            }
        }
    }

    private var instructionText: String {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            return "First, we'll request \"When In Use\" permission. Then you can upgrade to \"Always Allow\" for background tracking."
        case .authorizedWhenInUse:
            return "Great! Now upgrade to \"Always Allow\" to enable background tracking during flights."
        default:
            return "Location permission is required to track your complete flight path, even when the app is in the background."
        }
    }

    private var statusText: String {
        switch locationManager.authorizationStatus {
        case .authorizedAlways:
            return "Permission granted: Always ✓"
        case .authorizedWhenInUse:
            return "Permission granted: When In Use"
        case .denied:
            return "Permission denied. Please enable in Settings."
        case .restricted:
            return "Location access is restricted"
        default:
            return "Not determined"
        }
    }
}

struct HealthKitPermissionPage: View {
    @ObservedObject var healthKitManager: HealthKitManager
    @Binding var isGranted: Bool

    @State private var isRequesting = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "heart.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.red)

            Text("HealthKit Access")
                .font(.title2)
                .fontWeight(.bold)

            Text("Save your flight data to Apple Health and track heart rate during flights.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 12) {
                InfoRow(text: "Save flights as workouts")
                InfoRow(text: "Track heart rate during flight")
                InfoRow(text: "View in Apple Fitness app")
                InfoRow(text: "Sync with other health data")
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
            .padding(.horizontal)

            if !healthKitManager.isAuthorized && !isRequesting {
                Button(action: {
                    isRequesting = true
                    healthKitManager.requestAuthorization { success, error in
                        isGranted = success
                        isRequesting = false
                        if let error = error {
                            print("HealthKit error: \(error.localizedDescription)")
                        }
                    }
                }) {
                    Text("Grant HealthKit Permission")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .padding(.horizontal)
            } else if isRequesting {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
            } else {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("HealthKit access granted")
                        .foregroundColor(.secondary)
                }
                .padding()
            }
        }
    }
}

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.blue)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }
}

struct InfoRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.caption)

            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()
        }
    }
}

#Preview {
    ContentView()
}
