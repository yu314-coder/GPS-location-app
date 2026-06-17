import SwiftUI
import HealthKit
import Charts

enum SortOption: String, CaseIterable {
    case dateNewest = "Date (Newest)"
    case dateOldest = "Date (Oldest)"
    case distanceLongest = "Distance (Longest)"
    case distanceShortest = "Distance (Shortest)"
    case durationLongest = "Duration (Longest)"
    case durationShortest = "Duration (Shortest)"
}

struct EnhancedFlightHistoryView: View {
    @StateObject private var flightDataStore = FlightDataStore.shared
    @State private var workouts: [WorkoutSummary] = []
    @State private var selectedFlight: Flight?
    @State private var isLoading = false
    @State private var isLoadingWorkoutDetails = false
    @State private var selectedActivityType: WorkoutActivityType = .all
    @State private var sortOption: SortOption = .dateNewest
    @State private var showingSortMenu = false
    @ObservedObject private var healthKitManager = HealthKitManager.shared

    // Cache for workout details to prevent reloading
    @State private var workoutDetailsCache: [UUID: Flight] = [:]
    @State private var hasLoadedInitialData = false

    // Resync state
    @State private var isResyncing = false
    @State private var showResyncAlert = false
    @State private var resyncMessage = ""
    @State private var isResyncingAll = false
    @State private var resyncAllProgress = 0
    @State private var resyncAllTotal = 0
    @State private var resyncAllSucceeded = 0
    @State private var resyncAllFailed = 0
    @State private var resyncAllSkipped = 0
    @State private var showResyncAllAlert = false
    @State private var showResyncAllConfirm = false
    @State private var resyncAllMessage = ""
    @State private var showResyncDayConfirm = false
    @State private var resyncDayMessage = ""

    // Recalculate state
    @State private var isRecalculating = false
    @State private var recalculatingFlightID: UUID?
    @State private var showRecalculateAlert = false
    @State private var recalculateMessage = ""

    // Paging for HealthKit workouts to avoid memory spikes
    private let workoutPageSize = 100
    private let maxCacheSize = 1 // Only cache 1 workout at a time

    @State private var manualLoadEnabled = false // Don't auto-load workouts
    @State private var hasMoreWorkouts = false
    @State private var isLoadingMoreWorkouts = false
    @State private var lastWorkoutDate: Date?
    @State private var autoResyncedWorkouts: Set<UUID> = []
    @State private var loadedWorkoutIDs: Set<UUID> = []
    @State private var cachedWorkouts: [WorkoutSummary] = []
    @State private var jumpDate = Date()

    // Download all from HealthKit
    @State private var isDownloadingAll = false
    @State private var downloadAllProgress = 0
    @State private var downloadAllTotal = 0
    @State private var downloadAllMessage: String?
    @State private var showDownloadAllAlert = false
    @State private var downloadAllTask: Task<Void, Never>?

    // Search
    @State private var searchText = ""

    private var linkedWorkoutIDs: Set<UUID> {
        let workoutIDs = Set(workouts.map { $0.id })
        var linked: Set<UUID> = []
        for flight in flightDataStore.savedFlights {
            if let workoutUUID = flight.workoutUUID {
                linked.insert(workoutUUID)
            } else if workoutIDs.contains(flight.id) {
                linked.insert(flight.id)
            }
        }
        return linked
    }

    private var visibleWorkouts: [WorkoutSummary] {
        workouts.filter { !linkedWorkoutIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            contentView
        }
    }

    @ViewBuilder
    private var contentView: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            if isLoading {
                ProgressView("Loading workouts...")
            } else if flightDataStore.savedFlights.isEmpty && workouts.isEmpty && !manualLoadEnabled {
                emptyStateView
            } else {
                loadedStateView
            }
        }
        .navigationTitle("Activity History")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search by date, type, or distance")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(action: {
                        print("🔄 Manual refresh requested")
                        loadFlights(includeHealthKit: manualLoadEnabled)
                    }) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }

                    Button(action: downloadAllFromHealthKit) {
                        Label("Download All from HealthKit", systemImage: "square.and.arrow.down")
                    }
                    .disabled(isDownloadingAll)

                    Button(role: .destructive, action: clearAllCache) {
                        Label("Clear Cache & Reload", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.blue)
                }
            }
        }
        .alert("Resync to HealthKit", isPresented: $showResyncAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(resyncMessage)
        }
        .alert("Resync All Workouts", isPresented: $showResyncAllConfirm) {
            Button("Resync All", role: .destructive) {
                resyncAllWorkouts()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will overwrite overlapping workouts in HealthKit/Fitness using the app’s saved data.")
        }
        .alert("Resync All Complete", isPresented: $showResyncAllAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(resyncAllMessage)
        }
        .alert("Resync Day", isPresented: $showResyncDayConfirm) {
            Button("Resync Day", role: .destructive) {
                resyncWorkouts(on: jumpDate)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Resync workouts on \(jumpDate, format: .dateTime.year().month().day()).")
        }
        .alert("Recalculate Distance", isPresented: $showRecalculateAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(recalculateMessage)
        }
        .alert("Download Workouts", isPresented: $showDownloadAllAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(downloadAllMessage ?? "")
        }
        .navigationDestination(item: $selectedFlight) { flight in
            WorkoutDetailView(flight: flight)
                .onDisappear {
                    // Clear selection when returning to list
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        selectedFlight = nil
                    }
                }
        }
        .onAppear {
            // CRITICAL: decode JSON OFF the main thread so opening the tab never
            // freezes. Show the loading state while it works.
            if !hasLoadedInitialData {
                hasLoadedInitialData = true
                isLoading = true
                DispatchQueue.global(qos: .userInitiated).async {
                    flightDataStore.loadFlights()                       // decode off main
                    let cached = WorkoutCacheStore.shared.loadWorkouts() // decode off main
                    DispatchQueue.main.async {
                        if !cached.isEmpty {
                            cachedWorkouts = cached
                            let initialCount = min(workoutPageSize, cachedWorkouts.count)
                            workouts = Array(cachedWorkouts.prefix(initialCount))
                            loadedWorkoutIDs = Set(workouts.map { $0.id })
                            lastWorkoutDate = cachedWorkouts.last?.startDate
                            manualLoadEnabled = true
                            hasMoreWorkouts = cachedWorkouts.count > workouts.count
                            autoResyncIfNeeded()
                            print("✅ Loaded \(cachedWorkouts.count) workouts from cache (showing \(workouts.count))")
                        }
                        isLoading = false
                        print("✅ Loaded local flights (off main thread)")
                    }
                }
            }
        }
        .refreshable {
            // Allow pull-to-refresh to manually reload
            print("🔄 Pull-to-refresh triggered")
            await MainActor.run {
                loadFlights(includeHealthKit: manualLoadEnabled)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            // Clear cache on memory warning to free up memory
            print("⚠️ CRITICAL: Memory warning received!")
            print("   Clearing all caches to prevent crash...")
            workoutDetailsCache.removeAll()
            // Also clear workouts array if too large
            if workouts.count > workoutPageSize {
                workouts = Array(workouts.prefix(workoutPageSize))
                loadedWorkoutIDs = Set(workouts.map { $0.id })
                WorkoutCacheStore.shared.saveWorkouts(cachedWorkouts)
                hasMoreWorkouts = cachedWorkouts.count > workouts.count
                print("   Reduced workouts to \(workoutPageSize)")
            }
        }
        .onDisappear {
            // Clear cache when leaving the view
            print("👋 Flights tab disappeared - clearing cache")
            workoutDetailsCache.removeAll()
        }
    }


    private var emptyStateView: some View {
        // Show empty state with option to load workouts
        VStack(spacing: 20) {
            Image(systemName: "figure.walk")
                .font(.system(size: 60))
                .foregroundColor(.blue)

            Text("No Activities Yet")
                .font(.title2)
                .fontWeight(.bold)

            Text("Start tracking or load from HealthKit")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Button(action: { loadHealthKitWorkouts(reset: true) }) {
                HStack {
                    Image(systemName: "heart.text.square")
                    Text("Load HealthKit Workouts")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .padding(.horizontal, 40)
        }
        .padding()
    }

    @ViewBuilder
    private var loadedStateView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                workoutListView(proxy: proxy)
            }
            .refreshable {
                print("🔄 Pull-to-refresh triggered")
                await refreshFlights(includeHealthKit: manualLoadEnabled)
            }
        }

        if isLoadingWorkoutDetails {
            LoadingOverlay(message: "Loading workout details...")
        }

        if isRecalculating {
            LoadingOverlay(message: "Recalculating distance from GPS...\n\nCheck console for detailed progress")
        }
    }


    @ViewBuilder
    private func workoutListView(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 20) {
            // Show button to load workouts if not loaded yet
            if !manualLoadEnabled && workouts.isEmpty {
                Button(action: { loadHealthKitWorkouts(reset: true) }) {
                    HStack {
                        Image(systemName: "heart.text.square")
                        Text("Load Recent HealthKit Workouts")
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .foregroundColor(.blue)
                    .cornerRadius(12)
                }
                .padding(.horizontal)
            }

            // Download all workouts with routes from HealthKit
            if isDownloadingAll {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Image(systemName: "square.and.arrow.down")
                            .foregroundColor(.green)
                        Text(downloadAllTotal > 0 ? "Downloading \(downloadAllProgress)/\(downloadAllTotal)" : (downloadAllMessage ?? "Preparing..."))
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        if downloadAllTotal > 0 {
                            Text("\(Int((Double(downloadAllProgress) / Double(max(downloadAllTotal, 1))) * 100))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        Button(action: cancelDownloadAll) {
                            Image(systemName: "stop.circle.fill")
                                .font(.title3)
                                .foregroundColor(.red)
                        }
                    }

                    if downloadAllTotal > 0 {
                        ProgressView(value: Double(downloadAllProgress), total: Double(downloadAllTotal))
                            .progressViewStyle(.linear)
                            .tint(.green)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                }
                .padding()
                .background(Color.green.opacity(0.08))
                .cornerRadius(12)
                .padding(.horizontal)
            } else {
                Button(action: downloadAllFromHealthKit) {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                        Text("Download All Routes from HealthKit")
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .foregroundColor(.green)
                    .cornerRadius(12)
                }
                .padding(.horizontal)
            }

            // Enhanced Statistics Section
            EnhancedStatsSection(
                flights: flightDataStore.savedFlights,
                healthKitWorkouts: statsWorkouts
            )
            .equatable()

            // Activity Type Filter
            ActivityTypeFilter(selectedType: $selectedActivityType)

            // Sort Options
            HStack {
                Text("Sort by:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Button(action: { showingSortMenu = true }) {
                    HStack(spacing: 4) {
                        Text(sortOption.rawValue)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.1))
                    .foregroundColor(.blue)
                    .cornerRadius(8)
                }
                .confirmationDialog("Sort Workouts", isPresented: $showingSortMenu, titleVisibility: .visible) {
                    ForEach(SortOption.allCases, id: \.self) { option in
                        Button(option.rawValue) {
                            sortOption = option
                        }
                    }
                }

                Spacer()
            }
            .padding(.horizontal)

            // Jump to Date + Quick Jump
            HStack(spacing: 12) {
                DatePicker(
                    "Jump to date",
                    selection: $jumpDate,
                    displayedComponents: .date
                )
                .labelsHidden()
                .datePickerStyle(.compact)

                Button("Go") {
                    if let targetID = nearestActivityID(to: jumpDate) {
                        if targetID.hasPrefix("w_") {
                            let idString = String(targetID.dropFirst(2))
                            if let uuid = UUID(uuidString: idString) {
                                ensureWorkoutVisible(workoutID: uuid)
                            }
                        }
                        withAnimation(.easeInOut) {
                            proxy.scrollTo(targetID, anchor: .top)
                        }
                    }
                }
                .buttonStyle(.bordered)

                Menu("Jump") {
                    ForEach(monthIndex, id: \.id) { entry in
                        Button(entry.label) {
                            if entry.id.hasPrefix("w_") {
                                let idString = String(entry.id.dropFirst(2))
                                if let uuid = UUID(uuidString: idString) {
                                    ensureWorkoutVisible(workoutID: uuid)
                                }
                            }
                            withAnimation(.easeInOut) {
                                proxy.scrollTo(entry.id, anchor: .top)
                            }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)

            // Resync all to HealthKit
            HStack(spacing: 12) {
                Button(action: { showResyncAllConfirm = true }) {
                    HStack(spacing: 8) {
                        if isResyncingAll {
                            ProgressView()
                        }
                        Text(isResyncingAll ? "Resyncing \(resyncAllProgress)/\(max(resyncAllTotal, 1))" : "Resync All to HealthKit")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.orange.opacity(0.12))
                    .foregroundColor(.orange)
                    .cornerRadius(12)
                }
                .disabled(isResyncingAll || flightDataStore.savedFlights.isEmpty)

                if isResyncingAll {
                    Text("✅ \(resyncAllSucceeded)  ❌ \(resyncAllFailed)  ⚠️ \(resyncAllSkipped)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)

            HStack(spacing: 12) {
                Button(action: { showResyncDayConfirm = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar")
                        Text("Resync Day (\(jumpDate, format: .dateTime.year().month().day()))")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.green.opacity(0.12))
                    .foregroundColor(.green)
                    .cornerRadius(12)
                }
                .disabled(isResyncingAll || flightDataStore.savedFlights.isEmpty)
            }
            .padding(.horizontal)

            // Grouped Workouts
            GroupedWorkoutsSection(
                flights: filteredFlights,
                workouts: filteredWorkouts,
                sortOption: sortOption,
                onWorkoutTap: loadWorkoutDetails,
                onWorkoutRecalculate: { workout in
                    recalculateAndResyncWorkout(workout)
                },
                onFlightTap: { flight in
                    selectedFlight = flight
                },
                onFlightResync: { flight in
                    resyncFlight(flight)
                },
                onFlightRecalculate: { flight in
                    recalculateFlight(flight)
                }
            )
            .equatable()

            // No results from search
            if !searchText.trimmingCharacters(in: .whitespaces).isEmpty
                && filteredFlights.isEmpty && filteredWorkouts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title)
                        .foregroundColor(.secondary)
                    Text("No activities match \"\(searchText)\"")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            }

            // Subtle loaded-count footer
            if !visibleWorkouts.isEmpty {
                Text("\(visibleWorkouts.count) workouts loaded")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
            }

            if manualLoadEnabled && hasMoreWorkouts {
                VStack(spacing: 8) {
                    Button(action: { loadMoreWorkouts() }) {
                        HStack(spacing: 8) {
                            if isLoadingMoreWorkouts {
                                ProgressView()
                            }
                            Text(isLoadingMoreWorkouts ? "Loading..." : "Load 100 More")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue.opacity(0.1))
                        .foregroundColor(.blue)
                        .cornerRadius(12)
                    }
                    .disabled(isLoadingMoreWorkouts)
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
        }
        .padding(.vertical)
    }

    // MARK: - Filtered & Sorted Data

    private var filteredFlights: [Flight] {
        var result = flightDataStore.savedFlights
        if selectedActivityType != .all {
            result = result.filter { flight in
                guard let workoutTypeRaw = flight.workoutType,
                      let workoutType = HKWorkoutActivityType(rawValue: workoutTypeRaw) else { return false }
                return selectedActivityType.matches(workoutType)
            }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return result }
        return result.filter { flight in
            let typeName = flight.workoutType
                .flatMap { HKWorkoutActivityType(rawValue: $0) }
                .map { activityDisplayName($0) } ?? "workout"
            let distanceKm = String(format: "%.1f", (flight.metrics?.totalDistance ?? 0) / 1000)
            return matchesSearch(query: query, date: flight.startDate, typeName: typeName, distanceKm: distanceKm)
        }
    }

    private var filteredWorkouts: [WorkoutSummary] {
        var result = visibleWorkouts
        if selectedActivityType != .all {
            result = result.filter { workout in
                guard let type = workout.activityType else { return false }
                return selectedActivityType.matches(type)
            }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return result }
        return result.filter { workout in
            let typeName = workout.activityType.map { activityDisplayName($0) } ?? "workout"
            let distanceKm = String(format: "%.1f", workout.totalDistance / 1000)
            return matchesSearch(query: query, date: workout.startDate, typeName: typeName, distanceKm: distanceKm)
        }
    }

    private func activityDisplayName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "Running"
        case .walking: return "Walking"
        case .cycling: return "Cycling"
        case .hiking: return "Hiking"
        default: return "Workout"
        }
    }

    private func matchesSearch(query: String, date: Date, typeName: String, distanceKm: String) -> Bool {
        if typeName.lowercased().contains(query) { return true }
        if distanceKm.contains(query) { return true }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE MMMM d yyyy"
        if formatter.string(from: date).lowercased().contains(query) { return true }
        formatter.dateFormat = "M/d/yyyy"
        if formatter.string(from: date).lowercased().contains(query) { return true }
        return false
    }

    private var statsWorkouts: [WorkoutSummary] {
        let source = manualLoadEnabled ? cachedWorkouts : visibleWorkouts
        guard selectedActivityType != .all else { return source }
        return source.filter { workout in
            guard let type = workout.activityType else { return false }
            return selectedActivityType.matches(type)
        }
    }

    private var sortedFlights: [Flight] {
        let flights = filteredFlights
        switch sortOption {
        case .dateNewest:
            return flights.sorted { $0.startDate > $1.startDate }
        case .dateOldest:
            return flights.sorted { $0.startDate < $1.startDate }
        case .distanceLongest:
            return flights.sorted { ($0.metrics?.totalDistance ?? 0) > ($1.metrics?.totalDistance ?? 0) }
        case .distanceShortest:
            return flights.sorted { ($0.metrics?.totalDistance ?? 0) < ($1.metrics?.totalDistance ?? 0) }
        case .durationLongest:
            return flights.sorted { ($0.metrics?.duration ?? 0) > ($1.metrics?.duration ?? 0) }
        case .durationShortest:
            return flights.sorted { ($0.metrics?.duration ?? 0) < ($1.metrics?.duration ?? 0) }
        }
    }

    private var sortedWorkouts: [WorkoutSummary] {
        let workouts = filteredWorkouts
        switch sortOption {
        case .dateNewest:
            return workouts.sorted { $0.startDate > $1.startDate }
        case .dateOldest:
            return workouts.sorted { $0.startDate < $1.startDate }
        case .distanceLongest:
            return workouts.sorted { $0.totalDistance > $1.totalDistance }
        case .distanceShortest:
            return workouts.sorted { $0.totalDistance < $1.totalDistance }
        case .durationLongest:
            return workouts.sorted { $0.duration > $1.duration }
        case .durationShortest:
            return workouts.sorted { $0.duration < $1.duration }
        }
    }

    private func workoutActivityID(_ workout: WorkoutSummary) -> String {
        "w_\(workout.id.uuidString)"
    }

    private func flightActivityID(_ flight: Flight) -> String {
        "f_\(flight.id.uuidString)"
    }

    private var allActivitiesForJump: [(date: Date, id: String)] {
        var combined: [(date: Date, id: String)] = []
        for workout in cachedWorkouts {
            combined.append((date: workout.startDate, id: workoutActivityID(workout)))
        }
        for flight in sortedFlights {
            combined.append((date: flight.startDate, id: flightActivityID(flight)))
        }
        return combined.sorted { $0.date > $1.date }
    }

    private var monthIndex: [(label: String, id: String)] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy MMM"

        var seen: Set<String> = []
        var entries: [(label: String, id: String)] = []

        for activity in allActivitiesForJump {
            let label = formatter.string(from: activity.date)
            if seen.contains(label) { continue }
            seen.insert(label)
            entries.append((label: label, id: activity.id))
        }

        return entries
    }

    private func nearestActivityID(to date: Date) -> String? {
        guard !allActivitiesForJump.isEmpty else { return nil }
        if let sameDay = allActivitiesForJump.first(where: { Calendar.current.isDate($0.date, inSameDayAs: date) }) {
            return sameDay.id
        }
        var best: (date: Date, id: String)? = nil
        var bestDiff = TimeInterval.greatestFiniteMagnitude
        for activity in allActivitiesForJump {
            let diff = abs(activity.date.timeIntervalSince(date))
            if diff < bestDiff {
                bestDiff = diff
                best = activity
            }
        }
        return best?.id
    }

    private func ensureWorkoutVisible(workoutID: UUID) {
        guard let index = cachedWorkouts.firstIndex(where: { $0.id == workoutID }) else { return }

        if index < workouts.count { return }
        let end = min(index + 1, cachedWorkouts.count)
        guard end > 0 else { return }
        workouts = Array(cachedWorkouts.prefix(end))
        loadedWorkoutIDs = Set(workouts.map { $0.id })
        hasMoreWorkouts = cachedWorkouts.count > workouts.count
    }

    // MARK: - Cache Management

    private func clearAllCache() {
        print("🧹 CLEARING ALL CACHE AND RELOADING")

        // Clear workout details cache
        workoutDetailsCache.removeAll()
        print("   ✅ Cleared workout details cache")

        // Clear loaded workouts
        workouts.removeAll()
        print("   ✅ Cleared workouts list")
        WorkoutCacheStore.shared.clear()

        // Clear loaded flights
        flightDataStore.savedFlights.removeAll()
        print("   ✅ Cleared flights list")

        // Reset flags
        manualLoadEnabled = false
        hasLoadedInitialData = false
        hasMoreWorkouts = false
        isLoadingMoreWorkouts = false
        lastWorkoutDate = nil
        autoResyncedWorkouts.removeAll()
        loadedWorkoutIDs.removeAll()
        cachedWorkouts.removeAll()
        print("   ✅ Reset load flags")

        // Force reload everything
        print("   🔄 Reloading all data...")
        loadFlights(includeHealthKit: false)
    }

    // Clean up local flights whose HealthKit workouts have been deleted
    private func cleanupOrphanedFlights(completion: @escaping () -> Void) {
        guard healthKitManager.isAuthorized else {
            completion()
            return
        }

        // Only check flights that have an associated HealthKit workout UUID
        let localFlightsWithHealthKitIDs = flightDataStore.savedFlights.filter { $0.workoutUUID != nil }

        guard !localFlightsWithHealthKitIDs.isEmpty else {
            print("🧹 No local flights to check for cleanup")
            completion()
            return
        }

        print("🧹 Checking \(localFlightsWithHealthKitIDs.count) local flights for orphaned HealthKit workouts...")

        // Collect all HealthKit UUIDs to check
        let uuidsToCheck = localFlightsWithHealthKitIDs.compactMap { $0.workoutUUID }

        // Check which workouts still exist in HealthKit
        healthKitManager.checkWorkoutsExist(uuids: uuidsToCheck) { existenceMap in
            var orphanedCount = 0

            // Remove flights whose HealthKit workouts no longer exist
            for (uuid, exists) in existenceMap {
                if !exists {
                    // This flight's HealthKit workout was deleted, remove the local copy
                    if let flight = self.flightDataStore.savedFlights.first(where: { $0.workoutUUID == uuid }) {
                        print("   🗑️ Removing orphaned flight: \(uuid)")
                        print("      Date: \(flight.startDate)")
                        print("      Distance: \(String(format: "%.2f", (flight.metrics?.totalDistance ?? 0) / 1000))km")
                        self.flightDataStore.deleteFlight(flight)
                        orphanedCount += 1
                    }
                }
            }

            if orphanedCount > 0 {
                print("✅ Cleaned up \(orphanedCount) orphaned flights")
            } else {
                print("✅ No orphaned flights found")
            }

            completion()
        }
    }

    // MARK: - Data Loading

    private func refreshFlights(includeHealthKit: Bool) async {
        print("🔄 Pull-to-refresh: Refreshing flights...")
        await MainActor.run {
            loadFlights(includeHealthKit: includeHealthKit)
        }
        // Wait a bit for the data to load
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        print("✅ Pull-to-refresh complete")
    }

    private func loadFlights(includeHealthKit: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.loadFlights(includeHealthKit: includeHealthKit)
            }
            return
        }
        print("🔄 Loading flights - isLoading: \(isLoading) (includeHealthKit: \(includeHealthKit))")
        isLoading = true

        // Reload local flights from disk
        print("📂 Reloading local flights from storage...")
        flightDataStore.loadFlights()
        print("   ✅ Loaded \(flightDataStore.savedFlights.count) local flights")

        guard includeHealthKit else {
            DispatchQueue.main.async {
                self.isLoading = false
                if !self.manualLoadEnabled {
                    self.workouts = []
                }
            }
            return
        }

        if healthKitManager.isAuthorized {
            // First, clean up any orphaned local flights
            cleanupOrphanedFlights {
                if !self.cachedWorkouts.isEmpty {
                    self.syncWorkoutsFromHealthKit {
                        self.isLoading = false
                    }
                    self.manualLoadEnabled = true
                    self.rebuildLoadedWorkouts()
                    self.hasMoreWorkouts = self.cachedWorkouts.count > self.workouts.count
                    return
                }

                print("🏥 HealthKit authorized - fetching workouts (page size: \(self.workoutPageSize))...")
                self.healthKitManager.fetchWorkouts(limit: self.workoutPageSize, beforeDate: nil) { fetchedWorkouts, error in
                    DispatchQueue.main.async {
                        self.isLoading = false
                        if let fetchedWorkouts = fetchedWorkouts {
                            let newCount = self.mergeWorkouts(fetchedWorkouts)
                            self.manualLoadEnabled = true
                            self.rebuildLoadedWorkouts()
                            self.hasMoreWorkouts = self.cachedWorkouts.count > self.workouts.count
                            print("📊 ✅ Loaded \(self.workouts.count) HealthKit workouts (page size: \(self.workoutPageSize))")
                            print("   Total activities: \(self.flightDataStore.savedFlights.count + self.workouts.count)")
                            if newCount > 0 {
                                self.autoResyncIfNeeded()
                            }
                        } else if let error = error {
                            print("❌ Failed to load workouts: \(error.localizedDescription)")
                        }
                    }
                }
            }
        } else {
            print("🏥 HealthKit not authorized - requesting permission...")
            healthKitManager.requestAuthorization { success, error in
                if success {
                    print("   ✅ HealthKit permission granted - retrying load...")
                    self.loadFlights(includeHealthKit: includeHealthKit)
                } else {
                    DispatchQueue.main.async {
                        self.isLoading = false
                        print("   ❌ HealthKit permission denied")
                    }
                }
            }
        }
    }

    private func loadHealthKitWorkouts(reset: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.loadHealthKitWorkouts(reset: reset)
            }
            return
        }
        print("🏥 User requested to load HealthKit workouts")
        if reset {
            isLoading = true
        } else {
            isLoadingMoreWorkouts = true
        }

        if healthKitManager.isAuthorized {
            let beforeDate = reset ? nil : lastWorkoutDate?.addingTimeInterval(-1)
            if reset {
                workouts = []
                loadedWorkoutIDs.removeAll()
                lastWorkoutDate = cachedWorkouts.last?.startDate
                if !cachedWorkouts.isEmpty {
                    rebuildLoadedWorkouts(forcePageSize: true)
                    manualLoadEnabled = true
                    isLoading = false
                    syncWorkoutsFromHealthKit()
                    return
                }
            }
            healthKitManager.fetchWorkouts(limit: workoutPageSize, beforeDate: beforeDate) { fetchedWorkouts, error in
                DispatchQueue.main.async {
                    if reset {
                        self.isLoading = false
                    } else {
                        self.isLoadingMoreWorkouts = false
                    }
                    if let fetchedWorkouts = fetchedWorkouts {
                        let newCount = self.mergeWorkouts(fetchedWorkouts)
                        self.manualLoadEnabled = true
                        if reset {
                            self.rebuildLoadedWorkouts(forcePageSize: true)
                        } else {
                            _ = self.appendNextPageFromCache()
                        }
                        self.hasMoreWorkouts = self.cachedWorkouts.count > self.workouts.count
                        print("📊 Loaded \(self.workouts.count) HealthKit workouts (page size: \(self.workoutPageSize))")
                        if newCount > 0 {
                            self.autoResyncIfNeeded()
                        }
                    } else if let error = error {
                        print("❌ Failed to load workouts: \(error.localizedDescription)")
                    }
                }
            }
        } else {
            // Request permission first
            healthKitManager.requestAuthorization { success, error in
                DispatchQueue.main.async {
                    if success {
                        self.loadHealthKitWorkouts(reset: reset) // Try again after permission
                    } else {
                        self.isLoading = false
                        self.isLoadingMoreWorkouts = false
                        print("❌ HealthKit permission denied")
                    }
                }
            }
        }
    }

    private func loadWorkoutDetails(_ workout: WorkoutSummary) {
        if let localDetails = flightDataStore.loadFlightDetails(id: workout.id) {
            print("📦 Using locally cached workout details for \(workout.id)")
            selectedFlight = localDetails
            return
        }

        // Check cache first
        if let cachedFlight = workoutDetailsCache[workout.id] {
            print("📦 Using cached workout details for \(workout.id)")
            selectedFlight = cachedFlight
            return
        }

        // CRITICAL: Clear cache before loading new workout to prevent memory spike
        if workoutDetailsCache.count >= maxCacheSize {
            print("🧹 Pre-clearing cache before loading new workout")
            workoutDetailsCache.removeAll()
        }

        isLoadingWorkoutDetails = true
        healthKitManager.fetchWorkout(uuid: workout.id) { fetchedWorkout, error in
            guard let fetchedWorkout = fetchedWorkout else {
                DispatchQueue.main.async {
                    self.isLoadingWorkoutDetails = false
                    print("❌ Workout not found in HealthKit: \(error?.localizedDescription ?? "Unknown error")")
                }
                return
            }

            self.healthKitManager.fetchRoute(for: fetchedWorkout) { locations, _ in
                DispatchQueue.main.async {
                    self.isLoadingWorkoutDetails = false

                    // Build flight with full details (including speed history for graphs)
                    let flight = self.convertWorkoutToFlight(fetchedWorkout, locations: locations ?? [], includeSpeedHistory: true)
                    var updatedFlight = flight
                    updatedFlight.workoutUUID = fetchedWorkout.uuid
                    FlightDataStore.shared.saveFlight(updatedFlight)

                    // Cache the result
                    self.workoutDetailsCache[workout.id] = flight
                    print("💾 Cached workout details for \(workout.id) (cache size: \(self.workoutDetailsCache.count)/\(self.maxCacheSize))")

                    self.selectedFlight = flight
                }
            }
        }
    }

    private func resyncFlight(_ flight: Flight, showAlert: Bool = true) {
        print("🔄 User requested resync for flight: \(flight.id)")

        // Ensure HealthKit is authorized
        guard healthKitManager.isAuthorized else {
            if showAlert {
                resyncMessage = "Please authorize HealthKit access to resync workouts."
                showResyncAlert = true
            }
            return
        }

        // Load full flight details if needed (with all location data)
        let fullFlight: Flight
        if flight.locations.isEmpty {
            // Load from disk
            print("📂 Loading full flight details from disk...")
            if let details = flightDataStore.loadFlightDetails(id: flight.id) {
                fullFlight = details
            } else {
                resyncMessage = "Could not load flight details."
                showResyncAlert = true
                return
            }
        } else {
            fullFlight = flight
        }

        guard !fullFlight.locations.isEmpty, let metrics = fullFlight.metrics else {
            if showAlert {
                resyncMessage = "This workout has no location data to resync."
                showResyncAlert = true
            }
            return
        }

        isResyncing = true
        print("📊 Resyncing:")
        print("   Stored Distance: \(String(format: "%.2f", metrics.totalDistance/1000))km")
        print("   Locations: \(fullFlight.locations.count)")
        print("   📍 Will recalculate distance from GPS points if corruption detected")

        // Resync to HealthKit
        let previousWorkoutID = fullFlight.workoutUUID ?? fullFlight.id
        healthKitManager.resyncFlightToHealthKit(
            flight: fullFlight,
            locations: fullFlight.locations,
            metrics: metrics
        ) { success, error, workout in
            DispatchQueue.main.async {
                self.isResyncing = false

                if let workout = workout {
                    FlightDataStore.shared.updateWorkoutUUID(for: fullFlight.id, workoutUUID: workout.uuid)
                    self.applyResyncedWorkout(workout, oldWorkoutID: previousWorkoutID)
                }

                if success {
                    let signature = self.flightDataStore.resyncSignature(for: fullFlight)
                    FlightDataStore.shared.markResynced(flightID: fullFlight.id, signature: signature)
                    if showAlert {
                        self.resyncMessage = "Workout successfully resynced to HealthKit!\n\nDistance: \(String(format: "%.2f", metrics.totalDistance/1000))km\n\nThe Workouts tab will refresh automatically to show the updated distance."
                    }

                    // Automatically refresh the flights list to show updated distance
                    print("🔄 Auto-refreshing flights list after successful resync...")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.loadFlights(includeHealthKit: self.manualLoadEnabled)
                    }
                } else {
                    if showAlert {
                        self.resyncMessage = "Failed to resync: \(error?.localizedDescription ?? "Unknown error")"
                    }
                }

                if showAlert {
                    self.showResyncAlert = true
                }
            }
        }
    }

    private func resyncAllWorkouts() {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.resyncAllWorkouts()
            }
            return
        }

        guard healthKitManager.isAuthorized else {
            resyncAllMessage = "Please authorize HealthKit access to resync workouts."
            showResyncAllAlert = true
            return
        }

        let flights = flightDataStore.savedFlights
        guard !flights.isEmpty else {
            resyncAllMessage = "No saved workouts to resync."
            showResyncAllAlert = true
            return
        }

        resyncAllTotal = flights.count
        resyncAllProgress = 0
        resyncAllSucceeded = 0
        resyncAllFailed = 0
        resyncAllSkipped = 0
        isResyncingAll = true

        resyncNextWorkout(index: 0, flights: flights)
    }

    private func resyncWorkouts(on date: Date) {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.resyncWorkouts(on: date)
            }
            return
        }

        guard healthKitManager.isAuthorized else {
            resyncDayMessage = "Please authorize HealthKit access to resync workouts."
            showResyncAllAlert = true
            return
        }

        let calendar = Calendar.current
        let flights = flightDataStore.savedFlights.filter { calendar.isDate($0.startDate, inSameDayAs: date) }
        guard !flights.isEmpty else {
            resyncDayMessage = "No workouts found on \(date.formatted(date: .abbreviated, time: .omitted))."
            showResyncAllAlert = true
            return
        }
        resyncDayMessage = "Resyncing day: \(date.formatted(date: .abbreviated, time: .omitted))"

        resyncAllTotal = flights.count
        resyncAllProgress = 0
        resyncAllSucceeded = 0
        resyncAllFailed = 0
        resyncAllSkipped = 0
        isResyncingAll = true

        resyncNextWorkout(index: 0, flights: flights)
    }

    private func resyncNextWorkout(index: Int, flights: [Flight]) {
        if index >= flights.count {
            isResyncingAll = false
            let summary = "Resync complete.\n✅ \(resyncAllSucceeded)  ❌ \(resyncAllFailed)  ⚠️ \(resyncAllSkipped)"
            if !resyncDayMessage.isEmpty {
                resyncAllMessage = "\(resyncDayMessage)\n\n\(summary)"
                resyncDayMessage = ""
            } else {
                resyncAllMessage = summary
            }
            showResyncAllAlert = true
            return
        }

        let summary = flights[index]
        DispatchQueue.global(qos: .userInitiated).async {
            let fullFlight: Flight
            if summary.locations.isEmpty {
                fullFlight = self.flightDataStore.loadFlightDetails(id: summary.id) ?? summary
            } else {
                fullFlight = summary
            }

            guard !fullFlight.locations.isEmpty, let metrics = fullFlight.metrics else {
                DispatchQueue.main.async {
                    self.resyncAllSkipped += 1
                    self.resyncAllProgress += 1
                    self.resyncNextWorkout(index: index + 1, flights: flights)
                }
                return
            }

            let signature = self.flightDataStore.resyncSignature(for: fullFlight)
            if let lastSignature = fullFlight.lastResyncSignature, lastSignature == signature {
                DispatchQueue.main.async {
                    self.resyncAllSkipped += 1
                    self.resyncAllProgress += 1
                    self.resyncNextWorkout(index: index + 1, flights: flights)
                }
                return
            }

            let previousWorkoutID = fullFlight.workoutUUID ?? fullFlight.id
            self.healthKitManager.resyncFlightToHealthKit(
                flight: fullFlight,
                locations: fullFlight.locations,
                metrics: metrics
            ) { success, _, workout in
                DispatchQueue.main.async {
                    if let workout = workout {
                        FlightDataStore.shared.updateWorkoutUUID(for: fullFlight.id, workoutUUID: workout.uuid)
                        self.applyResyncedWorkout(workout, oldWorkoutID: previousWorkoutID)
                    }

                    if success {
                        FlightDataStore.shared.markResynced(flightID: fullFlight.id, signature: signature)
                        self.resyncAllSucceeded += 1
                    } else {
                        self.resyncAllFailed += 1
                    }
                    self.resyncAllProgress += 1
                    self.resyncNextWorkout(index: index + 1, flights: flights)
                }
            }
        }
    }

    private func loadMoreWorkouts() {
        guard manualLoadEnabled, hasMoreWorkouts, !isLoadingMoreWorkouts else { return }
        isLoadingMoreWorkouts = true
        if appendNextPageFromCache() {
            isLoadingMoreWorkouts = false
            return
        }
        loadHealthKitWorkouts(reset: false)
    }

    // MARK: - Download All from HealthKit

    private func downloadAllFromHealthKit() {
        guard !isDownloadingAll else { return }

        guard healthKitManager.isAuthorized else {
            healthKitManager.requestAuthorization { success, _ in
                if success {
                    self.downloadAllFromHealthKit()
                } else {
                    DispatchQueue.main.async {
                        self.downloadAllMessage = "Please authorize HealthKit access."
                        self.showDownloadAllAlert = true
                    }
                }
            }
            return
        }

        isDownloadingAll = true
        downloadAllProgress = 0
        downloadAllTotal = 0
        downloadAllMessage = "Finding workouts..."

        if #available(iOS 16.1, *) {
            DownloadLiveActivityManager.shared.beginBackgroundTask(name: "WorkoutsDownload")
            DownloadLiveActivityManager.shared.start(title: "Downloading Workouts", total: 0, message: "Finding workouts...")
        }

        downloadAllTask = Task {
            do {
                // Fetch all workouts in pages
                let pageSize = 200
                var allWorkouts: [HKWorkout] = []
                var beforeDate: Date? = nil

                while true {
                    let page: [HKWorkout] = try await withCheckedThrowingContinuation { continuation in
                        healthKitManager.fetchWorkouts(limit: pageSize, beforeDate: beforeDate) { result, error in
                            if let result {
                                continuation.resume(returning: result)
                            } else {
                                continuation.resume(throwing: error ?? NSError(domain: "HealthKit", code: -1))
                            }
                        }
                    }
                    allWorkouts.append(contentsOf: page)
                    if page.count < pageSize { break }
                    beforeDate = page.last?.startDate.addingTimeInterval(-1)
                }

                // Filter to candidates that have routes and aren't already saved
                let existingIDs = await MainActor.run {
                    Set(flightDataStore.savedFlights.map(\.id))
                        .union(Set(flightDataStore.savedFlights.compactMap(\.workoutUUID)))
                }

                let candidates = allWorkouts.filter { workout in
                    guard !existingIDs.contains(workout.uuid) else { return false }
                    switch workout.workoutActivityType {
                    case .running, .walking, .hiking, .cycling, .other: return true
                    default: return false
                    }
                }

                await MainActor.run {
                    downloadAllTotal = candidates.count
                    downloadAllProgress = 0
                    if #available(iOS 16.1, *) {
                        DownloadLiveActivityManager.shared.update(progress: 0, total: candidates.count, message: candidates.isEmpty ? "No new workouts" : "Downloading routes...")
                    }
                }

                guard !candidates.isEmpty else {
                    await MainActor.run {
                        isDownloadingAll = false
                        downloadAllMessage = "No new workouts to download."
                        if #available(iOS 16.1, *) {
                            DownloadLiveActivityManager.shared.end(finalMessage: "No new workouts")
                        }
                        showDownloadAllAlert = true
                    }
                    return
                }

                // Thermal-aware batching: concurrency shrinks and cooldowns grow
                // as the device heats up so the download can't overheat-crash.
                var imported = 0
                var skipped = 0
                var index = 0

                while index < candidates.count {
                    if Task.isCancelled { break }
                    await ThermalDownloadPacing.waitWhileCritical()
                    if Task.isCancelled { break }

                    let batchSize = ThermalDownloadPacing.concurrency
                    let batchEnd = min(index + batchSize, candidates.count)
                    let batch = Array(candidates[index..<batchEnd])

                    let results = await withTaskGroup(of: Flight?.self, returning: [Flight?].self) { group in
                        for workout in batch {
                            group.addTask {
                                let locations: [FlightLocation]? = await withCheckedContinuation { continuation in
                                    self.healthKitManager.fetchRoute(for: workout) { locs, _ in
                                        continuation.resume(returning: locs)
                                    }
                                }
                                guard let locs = locations, locs.count > 1 else { return nil }
                                return self.convertWorkoutToFlight(workout, locations: locs, includeSpeedHistory: true)
                            }
                        }
                        var collected: [Flight?] = []
                        for await result in group {
                            collected.append(result)
                        }
                        return collected
                    }

                    let validFlights: [Flight] = results.compactMap { result in
                        guard var flight = result else { return nil }
                        flight.workoutUUID = flight.id
                        return flight
                    }
                    skipped += results.count - validFlights.count
                    imported += validFlights.count

                    // Off-main batched save
                    await FlightDataStore.shared.saveDownloadedFlights(validFlights)

                    index = batchEnd
                    await MainActor.run {
                        downloadAllProgress = index
                        if #available(iOS 16.1, *) {
                            DownloadLiveActivityManager.shared.update(progress: index, total: candidates.count, message: "Downloading routes...")
                        }
                    }

                    await ThermalDownloadPacing.cooldown()
                }

                let wasCancelled = Task.isCancelled
                await MainActor.run {
                    isDownloadingAll = false
                    downloadAllTask = nil
                    if wasCancelled {
                        downloadAllMessage = "Stopped: \(imported) downloaded, \(skipped) skipped."
                        if #available(iOS 16.1, *) {
                            DownloadLiveActivityManager.shared.end(finalMessage: "Stopped after \(imported) downloads")
                        }
                    } else {
                        downloadAllMessage = "Done: \(imported) downloaded, \(skipped) skipped (no route)."
                        if #available(iOS 16.1, *) {
                            DownloadLiveActivityManager.shared.end(finalMessage: "\(imported) downloaded, \(skipped) skipped")
                        }
                    }
                    showDownloadAllAlert = true
                    loadFlights(includeHealthKit: manualLoadEnabled)
                }
            } catch {
                await MainActor.run {
                    isDownloadingAll = false
                    downloadAllTask = nil
                    downloadAllMessage = "Failed: \(error.localizedDescription)"
                    if #available(iOS 16.1, *) {
                        DownloadLiveActivityManager.shared.end(finalMessage: "Failed")
                    }
                    showDownloadAllAlert = true
                }
            }
        }
    }

    private func cancelDownloadAll() {
        print("🛑 User requested download cancel")
        downloadAllTask?.cancel()
    }

    private func mergeWorkouts(_ fetched: [HKWorkout]) -> Int {
        var newCount = 0

        for workout in fetched {
            let summary = WorkoutSummary(workout: workout)
            if let index = cachedWorkouts.firstIndex(where: { $0.id == summary.id }) {
                cachedWorkouts[index] = summary
            } else {
                cachedWorkouts.append(summary)
                newCount += 1
            }
        }

        cachedWorkouts.sort { $0.startDate > $1.startDate }
        lastWorkoutDate = cachedWorkouts.last?.startDate
        WorkoutCacheStore.shared.saveWorkouts(cachedWorkouts)

        // Refresh loaded workouts with updated summaries
        let loadedIDs = Set(workouts.map { $0.id })
        workouts = cachedWorkouts.filter { loadedIDs.contains($0.id) }
        workouts.sort { $0.startDate > $1.startDate }
        loadedWorkoutIDs = Set(workouts.map { $0.id })
        return newCount
    }

    private func rebuildLoadedWorkouts(forcePageSize: Bool = false) {
        let targetCount: Int
        if forcePageSize || workouts.isEmpty {
            targetCount = min(workoutPageSize, cachedWorkouts.count)
        } else {
            targetCount = min(workouts.count, cachedWorkouts.count)
        }
        workouts = Array(cachedWorkouts.prefix(targetCount))
        loadedWorkoutIDs = Set(workouts.map { $0.id })
        hasMoreWorkouts = cachedWorkouts.count > workouts.count
    }

    private func appendNextPageFromCache() -> Bool {
        let start = workouts.count
        guard cachedWorkouts.count > start else { return false }
        let end = min(start + workoutPageSize, cachedWorkouts.count)
        guard end > start else { return false }
        let slice = cachedWorkouts[start..<end]
        workouts.append(contentsOf: slice)
        loadedWorkoutIDs.formUnion(slice.map { $0.id })
        hasMoreWorkouts = cachedWorkouts.count > workouts.count
        return true
    }

    private func autoResyncIfNeeded() {
        guard healthKitManager.isAuthorized else { return }
        let workoutMap = Dictionary(uniqueKeysWithValues: cachedWorkouts.map { ($0.id, $0) })

        for flight in flightDataStore.savedFlights {
            guard let workoutUUID = flight.workoutUUID else { continue }
            guard autoResyncedWorkouts.contains(workoutUUID) == false else { continue }
            guard let workout = workoutMap[workoutUUID] else { continue }
            guard let metrics = flight.metrics else { continue }

            let localDistance = metrics.totalDistance
            let hkDistance = workout.totalDistance
            let difference = abs(localDistance - hkDistance)

            if localDistance > 0 && (hkDistance == 0 || difference > 100) {
                autoResyncedWorkouts.insert(workoutUUID)
                print("🔁 Auto-resync: local \(String(format: "%.2f", localDistance/1000))km vs HealthKit \(String(format: "%.2f", hkDistance/1000))km")
                resyncFlight(flight, showAlert: false)
            }
        }
    }

    private func syncWorkoutsFromHealthKit(completion: (() -> Void)? = nil) {
        guard healthKitManager.isAuthorized else {
            completion?()
            return
        }

        healthKitManager.syncWorkoutsWithAnchor { workouts, deletedIDs, _ in
            DispatchQueue.main.async {
                if !deletedIDs.isEmpty {
                    self.cachedWorkouts.removeAll { deletedIDs.contains($0.id) }
                }

                if !workouts.isEmpty {
                    _ = self.mergeWorkouts(workouts)
                } else {
                    WorkoutCacheStore.shared.saveWorkouts(self.cachedWorkouts)
                }

                self.rebuildLoadedWorkouts()
                self.hasMoreWorkouts = self.cachedWorkouts.count > self.workouts.count
                completion?()
            }
        }
    }

    private func recalculateAndResyncWorkout(_ workout: WorkoutSummary) {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.recalculateAndResyncWorkout(workout)
            }
            return
        }

        guard healthKitManager.isAuthorized else {
            recalculateMessage = "Please authorize HealthKit access to resync workouts."
            showRecalculateAlert = true
            return
        }

        isRecalculating = true

        healthKitManager.fetchWorkout(uuid: workout.id) { fetchedWorkout, error in
            guard let fetchedWorkout = fetchedWorkout else {
                DispatchQueue.main.async {
                    self.isRecalculating = false
                    self.recalculateMessage = "Failed to load workout: \(error?.localizedDescription ?? "Unknown error")"
                    self.showRecalculateAlert = true
                }
                return
            }

            self.healthKitManager.fetchRoute(for: fetchedWorkout) { locations, routeError in
                guard let locations = locations, !locations.isEmpty else {
                    DispatchQueue.main.async {
                        self.isRecalculating = false
                        self.recalculateMessage = "This workout has no route data to recalculate."
                        self.showRecalculateAlert = true
                    }
                    return
                }

                DispatchQueue.global(qos: .userInitiated).async {
                    let (recalculatedDistance, validSegments, invalidSegments) = self.calculateDistance(from: locations)

                    var metrics = FlightMetrics()
                    metrics.totalDistance = recalculatedDistance
                    metrics.duration = fetchedWorkout.duration
                    if metrics.duration > 0 {
                        metrics.averageSpeed = recalculatedDistance / metrics.duration
                    }
                    metrics.caloriesBurned = workout.calories ?? 0
                    metrics.stepsCount = workout.steps
                    metrics.maxAltitude = locations.map { $0.altitude }.max() ?? 0
                    metrics.minAltitude = locations.map { $0.altitude }.min() ?? 0
                    metrics.totalPoints = locations.count
                    metrics.validPoints = locations.filter { $0.isValid }.count
                    if metrics.totalPoints > 0 {
                        metrics.averageAccuracy = locations.map { $0.horizontalAccuracy }.reduce(0, +) / Double(metrics.totalPoints)
                        metrics.signalCoverage = (Double(metrics.validPoints) / Double(metrics.totalPoints)) * 100.0
                    }
                    let speeds = locations.map { $0.speed }.filter { $0 >= 0 }
                    if !speeds.isEmpty {
                        metrics.maxSpeed = speeds.max() ?? 0
                    }

                    var flight = Flight(id: fetchedWorkout.uuid, startDate: fetchedWorkout.startDate)
                    flight.endDate = fetchedWorkout.endDate
                    flight.locations = locations
                    flight.workoutType = fetchedWorkout.workoutActivityType.rawValue
                    flight.workoutUUID = fetchedWorkout.uuid
                    flight.metrics = metrics
                    DispatchQueue.main.async {
                        FlightDataStore.shared.saveFlight(flight)
                        self.updateCachedWorkoutDistance(id: flight.id, distance: recalculatedDistance)
                    }

                    let previousWorkoutID = flight.workoutUUID ?? flight.id
                    self.healthKitManager.resyncFlightToHealthKit(
                        flight: flight,
                        locations: locations,
                        metrics: metrics
                    ) { success, resyncError, workout in
                        DispatchQueue.main.async {
                            self.isRecalculating = false

                            if let workout = workout {
                                FlightDataStore.shared.updateWorkoutUUID(for: flight.id, workoutUUID: workout.uuid)
                                self.applyResyncedWorkout(workout, oldWorkoutID: previousWorkoutID)
                                let signature = FlightDataStore.shared.resyncSignature(for: flight)
                                FlightDataStore.shared.markResynced(flightID: flight.id, signature: signature)
                            }

                            if success {
                                self.recalculateMessage = """
                                ✅ Workout Resynced!

                                Distance: \(String(format: "%.2f", recalculatedDistance/1000))km
                                Valid GPS segments: \(validSegments)
                                Invalid/glitch segments: \(invalidSegments)
                                """
                            } else {
                                self.recalculateMessage = "Failed to resync: \(resyncError?.localizedDescription ?? "Unknown error")"
                            }

                            self.showRecalculateAlert = true
                        }
                    }
                }
            }
        }
    }

    private func updateCachedWorkoutDistance(id: UUID, distance: Double) {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.updateCachedWorkoutDistance(id: id, distance: distance)
            }
            return
        }

        if let index = cachedWorkouts.firstIndex(where: { $0.id == id }) {
            cachedWorkouts[index].totalDistance = distance
            WorkoutCacheStore.shared.saveWorkouts(cachedWorkouts)
            rebuildLoadedWorkouts()
            return
        }

        // Update persisted cache even if we haven't loaded it into memory yet
        var stored = WorkoutCacheStore.shared.loadWorkouts()
        if let storedIndex = stored.firstIndex(where: { $0.id == id }) {
            stored[storedIndex].totalDistance = distance
            WorkoutCacheStore.shared.saveWorkouts(stored)
        }
    }

    private func applyResyncedWorkout(_ workout: HKWorkout, oldWorkoutID: UUID) {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.applyResyncedWorkout(workout, oldWorkoutID: oldWorkoutID)
            }
            return
        }

        let summary = WorkoutSummary(workout: workout)
        if oldWorkoutID != summary.id {
            cachedWorkouts.removeAll { $0.id == oldWorkoutID }
        }

        if let index = cachedWorkouts.firstIndex(where: { $0.id == summary.id }) {
            cachedWorkouts[index] = summary
        } else {
            cachedWorkouts.append(summary)
        }

        cachedWorkouts.sort { $0.startDate > $1.startDate }
        WorkoutCacheStore.shared.saveWorkouts(cachedWorkouts)
        rebuildLoadedWorkouts()
        hasMoreWorkouts = cachedWorkouts.count > workouts.count
    }

    private func calculateDistance(from locations: [FlightLocation]) -> (Double, Int, Int) {
        var recalculatedDistance: Double = 0
        var validSegments = 0
        var invalidSegments = 0

        for i in 1..<locations.count {
            let current = locations[i]
            let previous = locations[i - 1]

            guard current.isValid && previous.isValid else {
                invalidSegments += 1
                continue
            }

            let distance = current.distance(to: previous)
            if distance < 1000.0 {
                recalculatedDistance += distance
                validSegments += 1
            } else {
                invalidSegments += 1
            }
        }

        return (recalculatedDistance, validSegments, invalidSegments)
    }

    private func recalculateFlight(_ flight: Flight) {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.recalculateFlight(flight)
            }
            return
        }

        print("🧮 ========== RECALCULATE DISTANCE DEBUG ==========")
        print("🧮 User requested distance recalculation for flight: \(flight.id)")

        // Load full flight details if needed
        let fullFlight: Flight
        if flight.locations.isEmpty {
            print("📂 Loading full flight details from disk...")
            if let details = flightDataStore.loadFlightDetails(id: flight.id) {
                fullFlight = details
                print("✅ Loaded \(details.locations.count) locations from disk")
            } else {
                recalculateMessage = "❌ Could not load flight details from storage."
                showRecalculateAlert = true
                return
            }
        } else {
            fullFlight = flight
            print("✅ Flight already has \(flight.locations.count) locations loaded")
        }

        guard !fullFlight.locations.isEmpty, let metrics = fullFlight.metrics else {
            recalculateMessage = "❌ This workout has no location data or metrics."
            showRecalculateAlert = true
            return
        }

        isRecalculating = true
        recalculatingFlightID = flight.id

        // Run recalculation on background thread
        DispatchQueue.global(qos: .userInitiated).async {
            print("🧮 Starting recalculation...")
            print("📊 Current stored metrics:")
            print("   Distance: \(String(format: "%.2f", metrics.totalDistance/1000))km (\(metrics.totalDistance)m)")
            print("   Locations: \(fullFlight.locations.count)")
            print("   Duration: \(String(format: "%.1f", metrics.duration))s")

            // Recalculate distance from GPS points
            var recalculatedDistance: Double = 0
            var validSegments = 0
            var invalidSegments = 0

            print("🧮 Calculating distance from GPS coordinates...")
            for i in 1..<fullFlight.locations.count {
                let current = fullFlight.locations[i]
                let previous = fullFlight.locations[i - 1]

                // Only count valid GPS points
                guard current.isValid && previous.isValid else {
                    invalidSegments += 1
                    continue
                }

                // Calculate distance
                let distance = current.distance(to: previous)

                // Sanity check: ignore impossible jumps (GPS glitches)
                if distance < 1000.0 { // Less than 1km jump
                    recalculatedDistance += distance
                    validSegments += 1

                    // Log every 500 segments for progress
                    if validSegments % 500 == 0 {
                        print("   Progress: \(validSegments) segments, distance so far: \(String(format: "%.2f", recalculatedDistance/1000))km")
                    }
                } else {
                    print("   ⚠️ Skipping GPS glitch at segment \(i): \(String(format: "%.0f", distance))m jump")
                    invalidSegments += 1
                }
            }

            print("🧮 Recalculation complete:")
            print("   Valid segments: \(validSegments)")
            print("   Invalid/glitch segments: \(invalidSegments)")
            print("   📊 STORED Distance: \(String(format: "%.2f", metrics.totalDistance/1000))km (\(metrics.totalDistance)m)")
            print("   📊 RECALCULATED Distance: \(String(format: "%.2f", recalculatedDistance/1000))km (\(recalculatedDistance)m)")

            let difference = abs(recalculatedDistance - metrics.totalDistance)
            let percentDiff = (difference / metrics.totalDistance) * 100.0
            print("   📊 DIFFERENCE: \(String(format: "%.2f", difference/1000))km (\(String(format: "%.1f", percentDiff))%)")

            let oldDistance = metrics.totalDistance
            let duration = metrics.duration

            let activityType = fullFlight.workoutType.flatMap { HKWorkoutActivityType(rawValue: $0) } ?? .walking
            let newAverageSpeed = duration > 0 ? recalculatedDistance / duration : 0
            var newSteps: Double?
            var oldSteps: Double = 0

            if activityType == .running || activityType == .walking || activityType == .hiking {
                let strideLength: Double = activityType == .running ? 1.2 : 0.75
                oldSteps = metrics.stepsCount ?? 0
                newSteps = recalculatedDistance / strideLength
            }

            // Save updated flight back to local storage
            var updatedFlight = fullFlight

            print("🧮 ========================================")

            // Update local storage + UI on main thread
            DispatchQueue.main.async {
                var updatedMetrics = metrics
                updatedMetrics.totalDistance = recalculatedDistance
                if duration > 0 {
                    let oldAvgSpeed = metrics.averageSpeed
                    updatedMetrics.averageSpeed = newAverageSpeed
                    print("   🏃 Average Speed: \(String(format: "%.1f", oldAvgSpeed * 3.6))km/h → \(String(format: "%.1f", updatedMetrics.averageSpeed * 3.6))km/h")
                }
                if let newSteps {
                    updatedMetrics.stepsCount = newSteps
                    print("   👟 Steps: \(String(format: "%.0f", oldSteps)) → \(String(format: "%.0f", newSteps))")
                }

                updatedFlight.metrics = updatedMetrics
                print("💾 Saving recalculated metrics to local storage...")
                print("   Flight ID: \(updatedFlight.id)")
                print("   Locations count: \(updatedFlight.locations.count)")
                print("   Distance: \(String(format: "%.2f", updatedMetrics.totalDistance/1000))km")
                FlightDataStore.shared.saveFlight(updatedFlight)
                if let workoutUUID = updatedFlight.workoutUUID {
                    self.updateCachedWorkoutDistance(id: workoutUUID, distance: updatedMetrics.totalDistance)
                }
                self.updateCachedWorkoutDistance(id: updatedFlight.id, distance: updatedMetrics.totalDistance)
                print("✅ Saved to local storage - full details persisted")

                self.isRecalculating = false
                self.recalculatingFlightID = nil

                if difference > 100.0 { // More than 100m difference
                    self.recalculateMessage = """
                    ✅ Distance Recalculated!

                    BEFORE: \(String(format: "%.2f", oldDistance/1000))km
                    AFTER: \(String(format: "%.2f", recalculatedDistance/1000))km

                    Difference: \(String(format: "%.2f", difference/1000))km (\(String(format: "%.1f", percentDiff))%)

                    Valid GPS segments: \(validSegments)
                    Invalid/glitch segments: \(invalidSegments)

                    The corrected distance has been saved to local storage. Pull down to refresh the list.
                    """
                } else {
                    self.recalculateMessage = """
                    ✅ Distance Verified!

                    Distance: \(String(format: "%.2f", recalculatedDistance/1000))km

                    No significant corruption detected.
                    Valid GPS segments: \(validSegments)
                    """
                }

                self.showRecalculateAlert = true

                // Refresh the flights list to show updated distance
                print("🔄 Refreshing flights list to show recalculated distance...")
                self.loadFlights(includeHealthKit: self.manualLoadEnabled)
            }
        }
    }

    private func convertWorkoutToFlight(_ workout: HKWorkout, locations: [FlightLocation], includeSpeedHistory: Bool = false) -> Flight {
        var flight = Flight(id: workout.uuid, startDate: workout.startDate)
        flight.workoutType = workout.workoutActivityType.rawValue
        flight.endDate = workout.endDate

        // CRITICAL: Only store locations if we need them for detail view
        if includeSpeedHistory {
            flight.locations = locations
        } else {
            flight.locations = [] // Don't store locations for list view
        }

        var metrics = FlightMetrics()
        if let distance = workout.totalDistance?.doubleValue(for: .meter()) {
            metrics.totalDistance = distance
        }
        metrics.duration = workout.duration
        if metrics.duration > 0 && metrics.totalDistance > 0 {
            metrics.averageSpeed = metrics.totalDistance / metrics.duration
        }

        if #available(iOS 18.0, *) {
            if let calories = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()) {
                metrics.caloriesBurned = calories
            }
            // Get steps count
            if let steps = workout.statistics(for: HKQuantityType(.stepCount))?.sumQuantity()?.doubleValue(for: .count()) {
                metrics.stepsCount = steps
            }
        } else {
            if let calories = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()) {
                metrics.caloriesBurned = calories
            }
            // Get steps count for iOS < 18
            if let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount),
               let steps = workout.statistics(for: stepType)?.sumQuantity()?.doubleValue(for: .count()) {
                metrics.stepsCount = steps
            }
        }

        // Only process location data if we have it and need it
        if !locations.isEmpty && includeSpeedHistory {
            metrics.maxAltitude = locations.map { $0.altitude }.max() ?? 0
            metrics.minAltitude = locations.map { $0.altitude }.min() ?? 0
            metrics.totalPoints = locations.count
            metrics.validPoints = locations.filter { $0.isValid }.count
            if metrics.totalPoints > 0 {
                metrics.averageAccuracy = locations.map { $0.horizontalAccuracy }.reduce(0, +) / Double(metrics.totalPoints)
                metrics.signalCoverage = (Double(metrics.validPoints) / Double(metrics.totalPoints)) * 100.0
            }

            // Calculate max speed from location speed values
            let speeds = locations.map { $0.speed }.filter { $0 >= 0 }
            if !speeds.isEmpty {
                metrics.maxSpeed = speeds.max() ?? 0
                print("📊 Calculated max speed from \(speeds.count) location speeds: \(String(format: "%.1f", metrics.maxSpeed * 3.6))km/h")
            }

            // Build speed history ONLY when needed (detail view)
            // Aggressive sampling to minimize memory
            var speedHistory: [SpeedSample] = []
            let samplingInterval = locations.count > 500 ? 10 : (locations.count > 200 ? 5 : 2)

            for (index, location) in locations.enumerated() {
                if index % samplingInterval == 0 && location.speed >= 0 {
                    speedHistory.append(SpeedSample(timestamp: location.timestamp, speed: location.speed))
                }
            }

            metrics.speedHistory = speedHistory
            print("📊 Built speed history: \(speedHistory.count) points from \(locations.count) locations (sampling: 1/\(samplingInterval))")

            // Calculate altitude gain and loss
            for i in stride(from: 1, to: locations.count, by: 2) { // Sample every 2nd point
                let altitudeDelta = locations[i].altitude - locations[i-1].altitude
                if altitudeDelta > 0 {
                    metrics.totalAltitudeGain += altitudeDelta
                } else {
                    metrics.totalAltitudeLoss += abs(altitudeDelta)
                }
            }
        }

        flight.metrics = metrics
        return flight
    }

}
// MARK: - Enhanced Stats Section

struct EnhancedStatsSection: View, Equatable {
    let flights: [Flight]
    let healthKitWorkouts: [WorkoutSummary]

    // Skip recomputing the totals (iterates every flight + workout) unless the
    // counts actually change — avoids redundant CPU work (heat) on every render.
    static func == (lhs: EnhancedStatsSection, rhs: EnhancedStatsSection) -> Bool {
        lhs.flights.count == rhs.flights.count
            && lhs.healthKitWorkouts.count == rhs.healthKitWorkouts.count
    }

    // Pre-compute stats to avoid holding references during rendering
    private var stats: (count: Int, distance: Double, duration: TimeInterval, calories: Double) {
        let flightCount = flights.count
        let workoutCount = healthKitWorkouts.count

        // Calculate flight stats
        var flightDistance: Double = 0
        var flightDuration: TimeInterval = 0
        var flightCalories: Double = 0

        for flight in flights {
            flightDistance += flight.metrics?.totalDistance ?? 0
            flightDuration += flight.metrics?.duration ?? 0
            flightCalories += flight.metrics?.caloriesBurned ?? 0
        }

        // Calculate workout stats (lightweight - only metadata)
        var workoutDistance: Double = 0
        var workoutDuration: TimeInterval = 0
        var workoutCalories: Double = 0

        for workout in healthKitWorkouts {
            workoutDistance += workout.totalDistance
            workoutDuration += workout.duration
            workoutCalories += workout.calories ?? 0
        }

        return (
            count: flightCount + workoutCount,
            distance: (flightDistance + workoutDistance) / 1000.0,
            duration: flightDuration + workoutDuration,
            calories: flightCalories + workoutCalories
        )
    }

    private var totalWorkouts: Int {
        stats.count
    }

    private var totalDistance: Double {
        stats.distance
    }

    private var totalDuration: TimeInterval {
        stats.duration
    }

    private var totalCalories: Double {
        stats.calories
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Your Activity")
                .font(.title2)
                .fontWeight(.bold)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                EnhancedStatCard(
                    icon: "figure.run",
                    title: "Total Workouts",
                    value: "\(totalWorkouts)",
                    color: .blue
                )

                EnhancedStatCard(
                    icon: "map.fill",
                    title: "Total Distance",
                    value: String(format: "%.1f", totalDistance),
                    unit: "km",
                    color: .green
                )

                EnhancedStatCard(
                    icon: "clock.fill",
                    title: "Total Time",
                    value: formatDuration(totalDuration),
                    color: .orange
                )

                EnhancedStatCard(
                    icon: "flame.fill",
                    title: "Calories",
                    value: String(format: "%.0f", totalCalories),
                    unit: "kcal",
                    color: .red
                )
            }
            .padding(.horizontal)
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) / 60 % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

struct EnhancedStatCard: View {
    let icon: String
    let title: String
    let value: String
    var unit: String = ""
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(color)
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.title)
                    .fontWeight(.bold)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
}

// MARK: - Activity Type Filter

enum WorkoutActivityType: String, CaseIterable {
    case all = "All"
    case flight = "Workout"
    case running = "Running"
    case walking = "Walking"
    case cycling = "Cycling"
    case hiking = "Hiking"
    case other = "Other"

    var icon: String {
        switch self {
        case .all: return "list.bullet"
        case .flight: return "figure.run"
        case .running: return "figure.run"
        case .walking: return "figure.walk"
        case .cycling: return "bicycle"
        case .hiking: return "mountain.2.fill"
        case .other: return "figure.mixed.cardio"
        }
    }

    func matches(_ activityType: HKWorkoutActivityType) -> Bool {
        switch self {
        case .all: return true
        case .flight: return activityType == .other
        case .running: return activityType == .running
        case .walking: return activityType == .walking
        case .cycling: return activityType == .cycling
        case .hiking: return activityType == .hiking
        case .other: return true
        }
    }
}

struct ActivityTypeFilter: View {
    @Binding var selectedType: WorkoutActivityType

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(WorkoutActivityType.allCases, id: \.self) { type in
                    FilterChip(
                        title: type.rawValue,
                        icon: type.icon,
                        isSelected: selectedType == type
                    ) {
                        selectedType = type
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}

struct FilterChip: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isSelected ? Color.blue : Color(.secondarySystemGroupedBackground))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(20)
        }
    }
}

// MARK: - Compact Speed Graph

struct CompactSpeedGraph: View {
    let speedHistory: [SpeedSample]

    // Downsample for performance if too many points
    private var sampledHistory: [SpeedSample] {
        if speedHistory.count <= 100 {
            return speedHistory
        }
        // Sample every Nth point to keep around 100 points for smooth rendering
        let step = speedHistory.count / 100
        return stride(from: 0, to: speedHistory.count, by: step).map { speedHistory[$0] }
    }

    var body: some View {
        if #available(iOS 16.0, *) {
            Chart(sampledHistory, id: \.timestamp) { sample in
                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Speed", sample.speed * 3.6)
                )
                .foregroundStyle(.blue.opacity(0.8))
                .interpolationMethod(.catmullRom)

                AreaMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Speed", sample.speed * 3.6)
                )
                .foregroundStyle(.blue.opacity(0.1))
                .interpolationMethod(.catmullRom)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 40)
        } else {
            // Fallback for iOS < 16
            CompactLineChart(data: sampledHistory.map { $0.speed * 3.6 })
                .frame(height: 40)
        }
    }
}

struct CompactLineChart: View {
    let data: [Double]

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                guard data.count > 1 else { return }

                let maxValue = data.max() ?? 1.0
                let minValue = data.min() ?? 0.0
                let range = max(maxValue - minValue, 0.1)

                let xStep = geometry.size.width / CGFloat(data.count - 1)

                for (index, value) in data.enumerated() {
                    let x = CGFloat(index) * xStep
                    let normalized = (value - minValue) / range
                    let y = geometry.size.height * (1 - CGFloat(normalized))

                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(Color.blue, lineWidth: 1.5)
        }
    }
}

// MARK: - Grouped Workouts Section

struct GroupedWorkoutsSection: View, Equatable {
    let flights: [Flight]
    let workouts: [WorkoutSummary]
    let sortOption: SortOption
    let onWorkoutTap: (WorkoutSummary) -> Void
    let onWorkoutRecalculate: ((WorkoutSummary) -> Void)?
    let onFlightTap: (Flight) -> Void
    let onFlightResync: ((Flight) -> Void)?
    let onFlightRecalculate: ((Flight) -> Void)?

    // Skip re-rendering this heavy list (sorts + builds every row) unless the
    // activity set or sort order actually changes. Ignores the closures, which
    // are recreated on every parent render (e.g. download progress ticks).
    static func == (lhs: GroupedWorkoutsSection, rhs: GroupedWorkoutsSection) -> Bool {
        lhs.sortOption == rhs.sortOption
            && lhs.flights.count == rhs.flights.count
            && lhs.workouts.count == rhs.workouts.count
            && lhs.flightSignature == rhs.flightSignature
            && lhs.workoutSignature == rhs.workoutSignature
    }

    private var flightSignature: String {
        flights.map { "\($0.id.uuidString):\(Int(($0.metrics?.totalDistance ?? 0)))" }.joined(separator: ",")
    }
    private var workoutSignature: String {
        workouts.map { "\($0.id.uuidString):\(Int($0.totalDistance))" }.joined(separator: ",")
    }

    // Combine and sort all activities by date
    private var allActivities: [(date: Date, isWorkout: Bool, workout: WorkoutSummary?, flight: Flight?)] {
        var combined: [(date: Date, isWorkout: Bool, workout: WorkoutSummary?, flight: Flight?)] = []

        // Add HealthKit workouts
        for workout in workouts {
            combined.append((date: workout.startDate, isWorkout: true, workout: workout, flight: nil))
        }

        // Add local flights
        for flight in flights {
            combined.append((date: flight.startDate, isWorkout: false, workout: nil, flight: flight))
        }

        return combined
    }

    private func activityID(workout: WorkoutSummary?, flight: Flight?) -> String {
        if let workout = workout {
            return "w_\(workout.id.uuidString)"
        }
        if let flight = flight {
            return "f_\(flight.id.uuidString)"
        }
        return UUID().uuidString
    }

    private func activityDistance(_ activity: (date: Date, isWorkout: Bool, workout: WorkoutSummary?, flight: Flight?)) -> Double {
        if let workout = activity.workout {
            return workout.totalDistance
        }
        if let flight = activity.flight {
            return flight.metrics?.totalDistance ?? 0
        }
        return 0
    }

    private func activityDuration(_ activity: (date: Date, isWorkout: Bool, workout: WorkoutSummary?, flight: Flight?)) -> TimeInterval {
        if let workout = activity.workout {
            return workout.duration
        }
        if let flight = activity.flight {
            return flight.metrics?.duration ?? 0
        }
        return 0
    }

    private var sortedActivities: [(date: Date, isWorkout: Bool, workout: WorkoutSummary?, flight: Flight?)] {
        switch sortOption {
        case .dateNewest:
            return allActivities.sorted { $0.date > $1.date }
        case .dateOldest:
            return allActivities.sorted { $0.date < $1.date }
        case .distanceLongest:
            return allActivities.sorted {
                let lhs = activityDistance($0)
                let rhs = activityDistance($1)
                return lhs == rhs ? $0.date > $1.date : lhs > rhs
            }
        case .distanceShortest:
            return allActivities.sorted {
                let lhs = activityDistance($0)
                let rhs = activityDistance($1)
                return lhs == rhs ? $0.date > $1.date : lhs < rhs
            }
        case .durationLongest:
            return allActivities.sorted {
                let lhs = activityDuration($0)
                let rhs = activityDuration($1)
                return lhs == rhs ? $0.date > $1.date : lhs > rhs
            }
        case .durationShortest:
            return allActivities.sorted {
                let lhs = activityDuration($0)
                let rhs = activityDuration($1)
                return lhs == rhs ? $0.date > $1.date : lhs < rhs
            }
        }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            ForEach(Array(sortedActivities.enumerated()), id: \.offset) { _, activity in
                if activity.isWorkout, let workout = activity.workout {
                    EnhancedWorkoutCard(
                        workout: workout,
                        onRecalculate: onWorkoutRecalculate.map { handler in { handler(workout) } }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onWorkoutTap(workout)
                    }
                    .padding(.horizontal)
                    .id(activityID(workout: workout, flight: nil))
                } else if !activity.isWorkout, let flight = activity.flight {
                    EnhancedFlightCard(
                        flight: flight,
                        onRecalculate: onFlightRecalculate.map { handler in { handler(flight) } },
                        onResync: onFlightResync.map { handler in { handler(flight) } }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onFlightTap(flight)
                    }
                    .padding(.horizontal)
                    .id(activityID(workout: nil, flight: flight))
                }
            }
        }
    }
}

struct EnhancedWorkoutCard: View {
    let workout: WorkoutSummary
    var onRecalculate: (() -> Void)? = nil

    private var activityIcon: String {
        let type = workout.activityType ?? .other
        switch type {
        case .running: return "figure.run"
        case .walking: return "figure.walk"
        case .cycling: return "bicycle"
        case .hiking: return "mountain.2.fill"
        default: return "figure.mixed.cardio"
        }
    }

    private var activityName: String {
        let type = workout.activityType ?? .other
        switch type {
        case .running: return "Running"
        case .walking: return "Walking"
        case .cycling: return "Cycling"
        case .hiking: return "Hiking"
        default: return "Workout"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: activityIcon)
                    .font(.title2)
                    .foregroundColor(.blue)
                    .frame(width: 40, height: 40)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(10)

                VStack(alignment: .leading, spacing: 4) {
                    Text(activityName)
                        .font(.headline)
                    Text(workout.startDate, style: .date)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(String(format: "%.2f km", workout.totalDistance / 1000))
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(formatDuration(workout.duration))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            HStack(spacing: 20) {
                if workout.duration > 0 {
                    MetricPill(icon: "speedometer", value: String(format: "%.1f km/h", (workout.totalDistance / workout.duration) * 3.6))
                }

                if let calories = workout.calories, calories > 0 {
                    MetricPill(icon: "flame.fill", value: String(format: "%.0f kcal", calories))
                }
                if let steps = workout.steps, steps > 0 {
                    MetricPill(icon: "figure.walk", value: String(format: "%.0f steps", steps))
                }

                Spacer()
            }

            if let onRecalculate = onRecalculate {
                Divider()
                HStack(spacing: 12) {
                    Button(action: onRecalculate) {
                        HStack(spacing: 4) {
                            Image(systemName: "function")
                                .font(.caption)
                            Text("Recalc & Resync")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.15))
                        .foregroundColor(.blue)
                        .cornerRadius(8)
                    }
                    Spacer()
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) / 60 % 60
        let seconds = Int(duration) % 60

        if hours > 0 {
            return String(format: "%dh %dm", hours, minutes)
        } else if minutes > 0 {
            return String(format: "%dm %ds", minutes, seconds)
        } else {
            return String(format: "%ds", seconds)
        }
    }
}

struct EnhancedFlightCard: View {
    let flight: Flight
    var onRecalculate: (() -> Void)? = nil
    var onResync: (() -> Void)? = nil

    private var activityType: HKWorkoutActivityType? {
        guard let rawValue = flight.workoutType else { return nil }
        return HKWorkoutActivityType(rawValue: rawValue)
    }

    private var activityName: String {
        switch activityType {
        case .cycling:
            return "Cycling"
        case .running:
            return "Running"
        case .walking:
            return "Walking"
        case .hiking:
            return "Hiking"
        case .other:
            return "Other"
        case .traditionalStrengthTraining:
            return "General"
        case .none:
            return "Workout"
        default:
            return "Workout"
        }
    }

    private var activityIcon: String {
        switch activityType {
        case .cycling:
            return "bicycle"
        case .running:
            return "figure.run"
        case .walking:
            return "figure.walk"
        case .hiking:
            return "mountain.2.fill"
        case .other:
            return "figure.mixed.cardio"
        case .traditionalStrengthTraining:
            return "figure.mixed.cardio"
        case .none:
            return "figure.run"
        default:
            return "figure.mixed.cardio"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: activityIcon)
                    .font(.title2)
                    .foregroundColor(.purple)
                    .frame(width: 40, height: 40)
                    .background(Color.purple.opacity(0.1))
                    .cornerRadius(10)

                VStack(alignment: .leading, spacing: 4) {
                    Text(activityName)
                        .font(.headline)
                    Text(flight.startDate, style: .date)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    if let metrics = flight.metrics {
                        Text(String(format: "%.2f km", metrics.totalDistance / 1000))
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(metrics.formattedDuration)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if let metrics = flight.metrics {
                // Don't show speed graph in list view to save memory
                // Only show in detail view
                Divider()

                HStack(spacing: 20) {
                    MetricPill(icon: "speedometer", value: String(format: "%.1f km/h", metrics.averageSpeedKmh))
                    MetricPill(icon: "mountain.2.fill", value: String(format: "%.0f m", metrics.maxAltitude))
                    // Show steps count if available
                    if let steps = metrics.stepsCount, steps > 0 {
                        MetricPill(icon: "figure.walk", value: String(format: "%.0f steps", steps))
                    }
                    if let effort = flight.effort {
                        MetricPill(icon: "bolt.fill", value: "Effort \(effort)/10")
                    }
                    Spacer()
                }

                // Action buttons
                if onRecalculate != nil || onResync != nil {
                    Divider()

                    HStack(spacing: 12) {
                        if let onRecalculate = onRecalculate {
                            Button(action: onRecalculate) {
                                HStack(spacing: 4) {
                                    Image(systemName: "function")
                                        .font(.caption)
                                    Text("Recalc")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.blue.opacity(0.15))
                                .foregroundColor(.blue)
                                .cornerRadius(8)
                            }
                        }

                        if let onResync = onResync {
                            Button(action: onResync) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(.caption)
                                    Text("Resync")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.orange.opacity(0.15))
                                .foregroundColor(.orange)
                                .cornerRadius(8)
                            }
                        }

                        Spacer()
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
}

struct MetricPill: View {
    let icon: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Loading Overlay

struct LoadingOverlay: View {
    let message: String

    var body: some View {
        Color.black.opacity(0.4)
            .ignoresSafeArea()

        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
                .progressViewStyle(CircularProgressViewStyle(tint: .white))

            Text(message)
                .font(.subheadline)
                .foregroundColor(.white)
        }
        .padding(24)
        .background(Color(.systemBackground).opacity(0.9))
        .cornerRadius(16)
    }
}
