//
//  ContentView.swift
//  GPS location app
//
//  GPS location app
//

import SwiftUI

private enum AppTab: Int, CaseIterable, Identifiable {
    case home
    case flights
    case map
    case analysis
    case test
    case settings

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .flights: return "Workouts"
        case .map: return "Map"
        case .analysis: return "Analysis"
        case .test: return "Test"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .flights: return "figure.run"
        case .map: return "map.fill"
        case .analysis: return "chart.xyaxis.line"
        case .test: return "wrench.and.screwdriver"
        case .settings: return "gear"
        }
    }

    static var appStoreTabs: [AppTab] {
        return allCases
    }
}

struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedTab: AppTab = .home
    @State private var showLiveSession = false

    private var isIPadLayout: Bool {
        horizontalSizeClass == .regular
    }

    var body: some View {
        Group {
            if isIPadLayout {
                iPadRootView
            } else {
                iPhoneRootView
            }
        }
        .sheet(isPresented: $showLiveSession) {
            LiveSessionView()
                .interactiveDismissDisabled(true) // Prevent swipe-to-dismiss
                .presentationDetents([.large]) // Full screen for stability
                .presentationDragIndicator(.hidden) // Hide drag indicator since it can't be dismissed
        }
        .onAppear {
            print("✅ ContentView appeared successfully")
            // DEBUG: `-replayFlight` launch arg drives a synthesized flight through the real
            // dead-reckoning pipeline and opens the live map, so Force Velocity can be seen on
            // the simulator (which has no Core Motion). Inert without the argument.
            if ProcessInfo.processInfo.arguments.contains("-replayFlight") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    WorkoutSession.shared.debugReplaySyntheticFlight()
                    showLiveSession = true
                }
            }
        }
        .onOpenURL { url in
            handleDeepLink(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openLiveSessionRequested)) { _ in
            selectedTab = .home
            showLiveSession = true
            print("✅ Opened Live Session from notification request")
        }
    }

    private var iPhoneRootView: some View {
        TabView(selection: $selectedTab) {
            // Home Tab
            HomeView(showLiveSession: $showLiveSession)
                .tabItem {
                    Label(AppTab.home.title, systemImage: AppTab.home.icon)
                }
                .tag(AppTab.home)

            // History Tab
            EnhancedFlightHistoryView()
                .tabItem {
                    Label(AppTab.flights.title, systemImage: AppTab.flights.icon)
                }
                .tag(AppTab.flights)

            // Map Tab
            WorkoutMapView()
                .tabItem {
                    Label(AppTab.map.title, systemImage: AppTab.map.icon)
                }
                .tag(AppTab.map)

            // Analysis Tab
            AnalysisView()
                .tabItem {
                    Label(AppTab.analysis.title, systemImage: AppTab.analysis.icon)
                }
                .tag(AppTab.analysis)

            // Test Tab
            PermissionTestView()
                .tabItem {
                    Label(AppTab.test.title, systemImage: AppTab.test.icon)
                }
                .tag(AppTab.test)

            // Settings Tab
            SettingsView()
                .tabItem {
                    Label(AppTab.settings.title, systemImage: AppTab.settings.icon)
                }
                .tag(AppTab.settings)
        }
    }

    private var iPadRootView: some View {
        NavigationSplitView {
            List {
                Section("GPS-location-app") {
                    ForEach(AppTab.appStoreTabs) { tab in
                        Button {
                            selectedTab = tab
                        } label: {
                            Label(tab.title, systemImage: tab.icon)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            selectedTab == tab ? Color.accentColor.opacity(0.14) : Color.clear
                        )
                        .foregroundColor(selectedTab == tab ? .accentColor : .primary)
                    }
                }
            }
            .navigationTitle("GPS Tracker")
        } detail: {
            selectedTabContent
        }
    }

    @ViewBuilder
    private var selectedTabContent: some View {
        switch selectedTab {
        case .home:
            NavigationStack {
                HomeView(showLiveSession: $showLiveSession)
                    .navigationTitle(AppTab.home.title)
            }
        case .flights:
            EnhancedFlightHistoryView()
        case .map:
            WorkoutMapView()
        case .analysis:
            AnalysisView()
        case .test:
            PermissionTestView()
        case .settings:
            SettingsView()
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "gpslocationapp" else { return }

        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        if host == "live" || path == "/live" {
            selectedTab = .home
            showLiveSession = true
            print("✅ Opened Live Session from deep link: \(url.absoluteString)")
        }
    }
}

struct HomeView: View {
    @Binding var showLiveSession: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isAnimating = false

    private var isIPadLayout: Bool {
        horizontalSizeClass == .regular
    }

    var body: some View {
        Group {
            if isIPadLayout {
                homeContent
            } else {
                NavigationStack {
                    homeContent
                        .navigationTitle("Home")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .onAppear {
            isAnimating = true
        }
    }

    private var homeContent: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.blue.opacity(0.10),
                    Color.purple.opacity(0.05),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: isIPadLayout ? 32 : 40) {
                    if isIPadLayout {
                        iPadHeroLayout
                    } else {
                        phoneHeroLayout
                        startTrackingButton
                    }

                    featureGrid
                }
                .frame(maxWidth: isIPadLayout ? 980 : .infinity)
                .padding(.horizontal, isIPadLayout ? 32 : 0)
                .padding(.vertical, isIPadLayout ? 40 : 20)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var phoneHeroLayout: some View {
        VStack(spacing: 24) {
            heroIcon
            heroText
        }
    }

    private var iPadHeroLayout: some View {
        HStack(alignment: .center, spacing: 36) {
            heroIcon
                .frame(width: 220)

            VStack(alignment: .leading, spacing: 22) {
                heroText
                    .multilineTextAlignment(.leading)

                startTrackingButton
                    .frame(maxWidth: 420)
            }

            Spacer(minLength: 0)
        }
        .padding(28)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: Color.black.opacity(0.06), radius: 18, x: 0, y: 8)
    }

    private var heroIcon: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.blue, Color.purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: isIPadLayout ? 150 : 120, height: isIPadLayout ? 150 : 120)
                .blur(radius: 20)
                .opacity(0.6)
                .scaleEffect(isAnimating ? 1.1 : 0.9)
                .animation(
                    Animation.easeInOut(duration: 2.0)
                        .repeatForever(autoreverses: true),
                    value: isAnimating
                )

            Image(systemName: "figure.run.circle.fill")
                .font(.system(size: isIPadLayout ? 120 : 100))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: .blue.opacity(0.3), radius: 10, x: 0, y: 5)
        }
    }

    private var heroText: some View {
        VStack(alignment: isIPadLayout ? .leading : .center, spacing: 12) {
            Text("GPS Workout Tracker")
                .font(.system(size: isIPadLayout ? 42 : 34, weight: .bold, design: .rounded))
                .multilineTextAlignment(isIPadLayout ? .leading : .center)

            Text("Track your workouts with precision GPS technology")
                .font(isIPadLayout ? .title3 : .subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(isIPadLayout ? .leading : .center)
                .padding(.horizontal, isIPadLayout ? 0 : 16)
        }
    }

    private var startTrackingButton: some View {
        Button(action: {
            showLiveSession = true
        }) {
            HStack(spacing: 12) {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                Text("Start Workout Tracking")
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
        .padding(.horizontal, isIPadLayout ? 0 : 16)
    }

    private var featureGrid: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 16),
                count: isIPadLayout ? 4 : 2
            ),
            spacing: 16
        ) {
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
        .padding(.horizontal, isIPadLayout ? 0 : 16)
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
            Image(systemName: "figure.run.circle.fill")
                .font(.system(size: 100))
                .foregroundColor(.blue)

            Text("Welcome to GPS Workout Tracker")
                .font(.title)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)

            Text("To track your workouts accurately, we need a couple of permissions")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 16) {
                PermissionRow(
                    icon: "location.fill",
                    title: "Location Access",
                    description: "Track your workout route with GPS"
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
                InfoRow(text: "Continuous GPS tracking during workouts")
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
            return "Great! Now upgrade to \"Always Allow\" to enable background tracking during workouts."
        default:
            return "Location permission is required to track your complete workout route, even when the app is in the background."
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

            Text("Save your workout data to Apple Health and track heart rate during workouts.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 12) {
                InfoRow(text: "Save workouts to Apple Health")
                InfoRow(text: "Track heart rate during workouts")
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
