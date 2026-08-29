//
//  ContentView.swift
//  GPS location app
//
//  GPS location app
//

import SwiftUI

/// FIVE TABS, NOT SIX.
///
/// A sixth tab does not fit: iOS collapses anything past five into a "More" list, so Settings —
/// which people actually use — was buried one level down behind a generic label, while a
/// diagnostics screen held a place on the bar. The test screen has moved behind the version
/// number with the rest of the developer tools, where it belongs, and Settings is now directly
/// reachable.
private enum AppTab: Int, CaseIterable, Identifiable {
    case home
    case flights
    case map
    case analysis
    case settings

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .flights: return "Workouts"
        case .map: return "Map"
        case .analysis: return "Analysis"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .flights: return "figure.run"
        case .map: return "map.fill"
        case .analysis: return "chart.xyaxis.line"
        case .settings: return "gear"
        }
    }

    static var appStoreTabs: [AppTab] {
        return allCases
    }
}

struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedTab: AppTab = {
        #if DEBUG
        // Screenshot hook: `simctl launch --setenv START_TAB=map` opens straight to a tab, so
        // each one can be captured without a tap. Debug builds only.
        if let raw = ProcessInfo.processInfo.environment["START_TAB"],
           let tab = AppTab.allCases.first(where: { $0.title.lowercased() == raw.lowercased() }) {
            return tab
        }
        #endif
        return .home
    }()
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
            // Prompt for Motion & Fitness at launch. Without it CMPedometer and
            // CMMotionActivityManager silently return nothing, which disables walking distance
            // and the stationary/automotive detection the dead reckoning relies on.
            WorkoutSession.shared.ensureMotionPermission()
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
        #if DEBUG
        // Screenshot hook, debug builds only: open a specific screen directly so it can be
        // captured without driving the UI. See the START_TAB hook above.
        if ProcessInfo.processInfo.environment["START_SCREEN"] == "method" {
            return AnyView(NavigationStack { VelocityMethodView() })
        }
        #endif
        return AnyView(tabRootView)
    }

    private var tabRootView: some View {
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

/// The first screen, rebuilt around the user's own data.
///
/// It used to be a product page: a pulsing icon, the tagline "Track your workouts with precision
/// GPS technology", and four cards describing features — GPS Filtering, HealthKit, Real-time,
/// Analytics. All four were static text. Nothing on the tab changed between a first launch and a
/// thousand kilometres in, which made the app's primary screen the only one that could tell you
/// nothing about yourself.
///
/// Now it opens with what you have done this month, what you did last, and whether the app is
/// actually able to record — the three things worth knowing before pressing Start.
struct HomeView: View {
    @Binding var showLiveSession: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @StateObject private var analytics = WorkoutAnalyticsManager.shared
    @ObservedObject private var flightStore = FlightDataStore.shared
    @ObservedObject private var locationManager = LocationManager.shared
    @ObservedObject private var healthKitManager = HealthKitManager.shared

    @State private var detailFlight: Flight?
    @State private var isAnimating = false

    private var isIPad: Bool { horizontalSizeClass == .regular }

    /// Newest first, and only finished workouts — an in-progress one belongs on the live screen.
    private var recentFlights: [Flight] {
        flightStore.savedFlights
            .filter { !$0.isActive }
            .sorted { $0.startDate > $1.startDate }
            .prefix(isIPad ? 6 : 4)
            .map { $0 }
    }

    var body: some View {
        Group {
            if isIPad {
                content
            } else {
                NavigationStack {
                    content
                        .navigationTitle("Home")
                        .navigationBarTitleDisplayMode(.large)
                        .navigationDestination(item: $detailFlight) { WorkoutDetailView(flight: $0) }
                }
            }
        }
        .onAppear {
            analytics.fetchData()
            isAnimating = true
        }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: AppTheme.sectionSpacing) {
                hero

                PrimaryActionButton(title: "Start Workout", icon: "play.fill") {
                    showLiveSession = true
                }

                monthSummary

                if !recentFlights.isEmpty {
                    recentSection
                } else {
                    EmptyStateCard(
                        icon: "figure.run",
                        title: "No workouts yet",
                        message: "Start one and it will appear here with its route, distance and pace."
                    )
                }

                readiness
            }
            .frame(maxWidth: isIPad ? 900 : .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: Hero

    /// The breathing gradient mark. It is the app's face and the one thing on the old Home worth
    /// keeping, so it survives the rebuild — smaller, because it now shares the screen with the
    /// month's numbers instead of being the whole screen.
    private var hero: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.blue, .purple],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: isIPad ? 110 : 88, height: isIPad ? 110 : 88)
                    .blur(radius: 18)
                    .opacity(0.55)
                    .scaleEffect(isAnimating ? 1.1 : 0.9)
                    .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true),
                               value: isAnimating)

                Image(systemName: "figure.run.circle.fill")
                    .font(.system(size: isIPad ? 88 : 72))
                    .foregroundStyle(LinearGradient(colors: [.blue, .purple],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(color: .blue.opacity(0.30), radius: 8, x: 0, y: 4)
            }

            Text("GPS Workout Tracker")
                .font(.system(size: isIPad ? 26 : 22, weight: .bold, design: .rounded))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    // MARK: This month

    private var monthSummary: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: analytics.monthName, subtitle: "So far this month") {
                    TrendBadge(change: analytics.monthOverMonthChange,
                               hasBaseline: analytics.lastYearSameMonthTotalKm > 0)
                }

                // Two tiles on iPhone, three across on iPad. The year total is the one that gets
                // dropped when narrow: it is also the headline of the Analysis tab, so losing it
                // here costs nothing.
                let columns = Array(repeating: GridItem(.flexible(), spacing: 10),
                                    count: isIPad ? 3 : 2)
                LazyVGrid(columns: columns, spacing: 10) {
                    MetricTile(icon: "point.topleft.down.curvedto.point.bottomright.up",
                               value: String(format: "%.1f km", analytics.monthTotalKm),
                               label: "Distance", tint: AppTheme.distance, compact: true)
                    MetricTile(icon: "figure.run",
                               value: "\(recentFlights.count == 0 ? analytics.allTimeWorkoutCount : flightStore.savedFlights.count)",
                               label: "Workouts", tint: AppTheme.count, compact: true)
                    if isIPad {
                        MetricTile(icon: "calendar",
                                   value: String(format: "%.0f km", analytics.yearTotalKm),
                                   label: "\(analytics.selectedYear)",
                                   tint: AppTheme.duration, compact: true)
                    }
                }

                if analytics.isLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reading from Health…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Recent")
            AppCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(recentFlights.enumerated()), id: \.element.id) { index, flight in
                        Button { detailFlight = flight } label: {
                            RecentWorkoutRow(flight: flight)
                        }
                        .buttonStyle(.plain)

                        if index < recentFlights.count - 1 {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
            }
        }
    }

    // MARK: Readiness

    /// Whether the app can actually record right now. Both permissions are silent failures: with
    /// location denied a workout runs and records nothing, and that is only discoverable after
    /// the fact. Worth one line on the first screen.
    private var readiness: some View {
        let locationOK = locationManager.authorizationStatus == .authorizedAlways
            || locationManager.authorizationStatus == .authorizedWhenInUse
        let healthLabel = healthKitManager.writeAuthorizationLabel

        return AppCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Ready to record")
                HStack(spacing: 10) {
                    ReadinessPill(icon: "location.fill", title: "Location",
                                  ok: locationOK,
                                  detail: locationManager.authorizationStatus == .authorizedAlways
                                      ? "Always" : (locationOK ? "In use" : "Off"))
                    ReadinessPill(icon: "heart.fill", title: "Health",
                                  ok: healthLabel == "Authorized",
                                  detail: healthLabel)
                }
            }
        }
    }
}

/// One finished workout: what it was, how far, how long, and when.
private struct RecentWorkoutRow: View {
    let flight: Flight

    private var distanceText: String {
        String(format: "%.2f km", flight.totalDistance / 1000)
    }

    private var durationText: String {
        let total = Int(flight.duration)
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "figure.run")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.distance)
                .frame(width: 32, height: 32)
                .background(Circle().fill(AppTheme.distance.opacity(0.12)))

            VStack(alignment: .leading, spacing: 2) {
                Text(distanceText)
                    .font(.subheadline).fontWeight(.semibold).monospacedDigit()
                Text(flight.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(durationText)
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, AppTheme.cardPadding)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

private struct ReadinessPill: View {
    let icon: String
    let title: String
    let ok: Bool
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(ok ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).fontWeight(.medium)
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous)
                .fill((ok ? Color.green : Color.orange).opacity(0.10))
        )
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
