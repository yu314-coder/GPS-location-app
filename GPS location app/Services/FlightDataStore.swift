import Foundation
import HealthKit
import CoreLocation
import UIKit

class FlightDataStore: ObservableObject {
    static let shared = FlightDataStore()

    @Published var savedFlights: [Flight] = []
    /// THE WORKOUT LIST LOADS OFF THE MAIN THREAD (build 160). With ~3,900 workouts the app's first screen waited for
    /// flights.json to be decoded on the main thread (FlightDataStore.shared is first touched by Home). It now loads in
    /// the background; until it has, nothing writes flights.json (a list without the saved workouts would replace the
    /// file), and anything saved meanwhile is merged into the loaded list, not overwritten by it.
    @Published private(set) var isLoaded = false
    private var persistAfterLoad = false
    private var loadInFlight = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private let loadQueue = DispatchQueue(label: "euleryu.gps.flights-load", qos: .userInitiated)

    /// Returns once the list has been loaded from disk (immediately after the first load).
    func waitUntilLoaded() async {
        if await MainActor.run(body: { self.isLoaded }) { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                if self.isLoaded { c.resume() } else { self.loadWaiters.append(c) }
            }
        }
    }

    /// In memory, the sampled route of each workout the Map has drawn (build 160): the Map re-read and re-decoded all
    /// ~3,900 route_<id>.json files on every period change. Cleared per workout when its route is rewritten or deleted.
    private var routeMemory: [UUID: [CLLocationCoordinate2D]] = [:]
    private let routeMemoryLock = NSLock()
    @Published var isLoading = false
    @Published var lastSyncDate: Date?

    private let fileName = "flights.json"
    private let detailsFilePrefix = "flight_details_"
    private let syncMetadataFileName = "sync_metadata.json"

    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    private var fileURL: URL {
        documentsDirectory.appendingPathComponent(fileName)
    }

    private var syncMetadataURL: URL {
        documentsDirectory.appendingPathComponent(syncMetadataFileName)
    }

    // SAVED ROUTES ARE GZIP (build 158). The full route files had grown to 7.2 GB on the owner's iPhone (3,859
    // flight_details_*.json, 2026-11-21). The same JSON is now stored gzip-compressed as .json.gz - 15% of the bytes
    // at level 6, nothing changed inside - and a plain .json from an older build is still read (and compressed when the
    // owner accepts the offer, see LogCompactor). Watch checkpoints, which rewrite the whole file each time, use level 1.
    private func flightDetailsURL(for id: UUID) -> URL {
        let gz = compressedDetailsURL(for: id)
        if FileManager.default.fileExists(atPath: gz.path) { return gz }
        let plain = plainDetailsURL(for: id)
        return FileManager.default.fileExists(atPath: plain.path) ? plain : gz
    }
    private func plainDetailsURL(for id: UUID) -> URL {
        documentsDirectory.appendingPathComponent("\(detailsFilePrefix)\(id.uuidString).json")
    }
    private func compressedDetailsURL(for id: UUID) -> URL {
        documentsDirectory.appendingPathComponent("\(detailsFilePrefix)\(id.uuidString).json.gz")
    }

    private func routeCacheURL(for id: UUID) -> URL {
        documentsDirectory.appendingPathComponent("route_\(id.uuidString).json")
    }

    /// Compact route cache: just sampled [lat, lon] pairs. The Map tab reads these
    /// tiny files instead of decoding the full flight detail (GPS points + every
    /// metric history) into memory — the main cause of map lag/memory-crashes on
    /// iPhone.
    private struct RouteCacheEntry: Codable {
        let coords: [[Double]]   // [[lat, lon], ...]
    }

    /// Returns sampled route coordinates for a flight (max ~400 points), reading
    /// the lightweight cache and building it on first use. Runs file I/O on the
    /// calling thread — call off the main thread.
    func loadRouteCoordinates(id: UUID) -> [CLLocationCoordinate2D] {
        routeMemoryLock.lock()
        if let held = routeMemory[id] { routeMemoryLock.unlock(); return held }
        routeMemoryLock.unlock()
        // 1) Fast path: compact cache file.
        let cacheURL = routeCacheURL(for: id)
        if let data = try? Data(contentsOf: cacheURL, options: .mappedIfSafe),
           let entry = try? JSONDecoder().decode(RouteCacheEntry.self, from: data) {
            let coords = entry.coords.compactMap { pair -> CLLocationCoordinate2D? in
                guard pair.count == 2 else { return nil }
                return CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
            }
            routeMemoryLock.lock(); routeMemory[id] = coords; routeMemoryLock.unlock()
            return coords
        }

        // 2) Build cache from the full detail (one-time cost per flight).
        guard let flight = loadFlightDetails(id: id), flight.locations.count > 1 else {
            return []
        }
        let sampled = Self.sampleLocations(flight.locations, maxPoints: 400)
        let coords = sampled.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        writeRouteCache(id: id, coordinates: coords)
        return coords
    }

    func writeRouteCache(id: UUID, coordinates: [CLLocationCoordinate2D]) {
        routeMemoryLock.lock(); routeMemory[id] = coordinates; routeMemoryLock.unlock()
        let entry = RouteCacheEntry(coords: coordinates.map { [$0.latitude, $0.longitude] })
        if let data = try? JSONEncoder().encode(entry) {
            try? data.write(to: routeCacheURL(for: id), options: .atomic)
        }
    }

    private func deleteRouteCache(for id: UUID) {
        routeMemoryLock.lock(); routeMemory[id] = nil; routeMemoryLock.unlock()
        try? FileManager.default.removeItem(at: routeCacheURL(for: id))
    }

    static func sampleLocations(_ locations: [FlightLocation], maxPoints: Int) -> [FlightLocation] {
        guard locations.count > maxPoints else { return locations }
        let stride = max(1, locations.count / maxPoints)
        var result: [FlightLocation] = []
        result.reserveCapacity(maxPoints + 1)
        var i = 0
        while i < locations.count {
            result.append(locations[i])
            i += stride
        }
        if let last = locations.last, result.last?.id != last.id {
            result.append(last)
        }
        return result
    }

    private init() {
        loadFlights()
        loadSyncMetadata()
    }

    /// The first load (and any later reload) has finished: merge what was saved meanwhile, mark loaded, write if a save
    /// was held back.
    private func finishLoad(_ decoded: [Flight]?) {
        dispatchPrecondition(condition: .onQueue(.main))
        loadInFlight = false
        if let decoded {
            let loadedIDs = Set(decoded.map { $0.id })
            let savedMeanwhile = savedFlights.filter { !loadedIDs.contains($0.id) }
            var merged = decoded
            // A workout saved or updated in memory before the load finished is newer than its copy on disk.
            let inMemory = Dictionary(savedFlights.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            if isLoaded || !savedFlights.isEmpty {
                for i in merged.indices { if let m = inMemory[merged[i].id] { merged[i] = m } }
            }
            savedFlights = savedMeanwhile + merged
        }
        let first = !isLoaded
        isLoaded = true
        if first, persistAfterLoad { persistAfterLoad = false; persistFlights() }
        let waiters = loadWaiters; loadWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async {
                work()
            }
        }
    }

    // MARK: - Public Methods

    func saveFlight(_ flight: Flight) {
        print("💾 Saving flight to local storage...")
        print("   Flight ID: \(flight.id)")
        print("   Locations: \(flight.locations.count)")
        print("   Distance: \(String(format: "%.2f", (flight.metrics?.totalDistance ?? 0) / 1000))km")

        // SAFETY: Validate flight data before saving
        guard !flight.id.uuidString.isEmpty else {
            print("❌ Cannot save flight - invalid ID")
            return
        }

        // Persist full details separately to avoid large memory spikes in the list view
        persistFlightDetails(flight)

        let summary = summarizedFlight(from: flight)
        print("   📋 Created summary (locations removed, metrics kept)")
        print("   📋 Summary distance: \(String(format: "%.2f", (summary.metrics?.totalDistance ?? 0) / 1000))km")

        runOnMain {
            // Check if flight already exists (update) or is new (append)
            if let index = self.savedFlights.firstIndex(where: { $0.id == flight.id }) {
                self.savedFlights[index] = summary
                print("   ✅ Updated existing flight in memory")
            } else {
                self.savedFlights.insert(summary, at: 0)  // Add to beginning (most recent first)
                print("   ✅ Added new flight to memory")
            }

            self.persistFlights()
            print("   ✅ Persisted summaries to flights.json")
        }
    }

    /// Bulk-save flights downloaded from HealthKit without blocking the main thread.
    /// Writes per-flight details on a background queue and defers the summary file
    /// write until all flights in the batch are processed.
    /// Returns once all writes complete.
    func saveDownloadedFlights(_ flights: [Flight]) async {
        guard !flights.isEmpty else { return }
        // Decided against the loaded list only (build 160): before it loads, every Health workout looks new.
        await waitUntilLoaded()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                // Write each flight's full details to disk off the main thread
                let summaries = flights.compactMap { flight -> Flight? in
                    guard !flight.id.uuidString.isEmpty else { return nil }
                    self.persistFlightDetails(flight)
                    return self.summarizedFlight(from: flight)
                }

                DispatchQueue.main.async {
                    // Merge summaries into the in-memory array (single update). Looked up by id through a dictionary
                    // (build 160; a firstIndex scan per summary made a full download quadratic), and a Health workout
                    // already saved under another id is not added twice.
                    var index = Dictionary(self.savedFlights.indices.map { (self.savedFlights[$0].id, $0) }, uniquingKeysWith: { a, _ in a })
                    let healthIDs = Set(self.savedFlights.compactMap { $0.workoutUUID })
                    var inserted: [Flight] = []
                    for summary in summaries {
                        if let i = index[summary.id] {
                            self.savedFlights[i] = summary
                        } else if let w = summary.workoutUUID, healthIDs.contains(w) {
                            continue
                        } else {
                            inserted.append(summary)
                        }
                    }
                    if !inserted.isEmpty {
                        self.savedFlights.insert(contentsOf: inserted.reversed(), at: 0)
                        index.removeAll()
                    }

                    // Single disk write for the summaries file, off main thread
                    let snapshot = self.savedFlights
                    DispatchQueue.global(qos: .utility).async {
                        self.persistFlightsSnapshot(snapshot)
                        continuation.resume()
                    }
                }
            }
        }
    }

    private func persistFlightsSnapshot(_ snapshot: [Flight]) {
        // Snapshots are taken on main after waitUntilLoaded / from a loaded list (build 160).
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("❌ Failed to save flights snapshot: \(error.localizedDescription)")
        }
    }

    func updateWorkoutUUID(for flightID: UUID, workoutUUID: UUID) {
        print("🔗 Updating workout UUID for flight \(flightID) → \(workoutUUID)")
        var didUpdateSummary = false

        runOnMain {
            if let index = self.savedFlights.firstIndex(where: { $0.id == flightID }) {
                self.savedFlights[index].workoutUUID = workoutUUID
                didUpdateSummary = true
            }
            if didUpdateSummary {
                self.persistFlights()
            }
        }

        if var details = loadFlightDetails(id: flightID) {
            details.workoutUUID = workoutUUID
            persistFlightDetails(details)
        }
        // A watch flight still being merged keeps the link too, or its next checkpoint would write it out again.
        checkpointLock.lock(); if checkpointFlight?.id == flightID { checkpointFlight?.workoutUUID = workoutUUID }; checkpointLock.unlock()
    }

    func resyncSignature(for flight: Flight) -> String {
        let metrics = flight.metrics
        let distance = metrics?.totalDistance ?? 0
        let duration = metrics?.duration ?? 0
        let calories = metrics?.caloriesBurned ?? 0
        let averageSpeed = metrics?.averageSpeed ?? 0
        let maxSpeed = metrics?.maxSpeed ?? 0
        let totalPoints = metrics?.totalPoints ?? flight.locations.count
        let start = flight.startDate.timeIntervalSince1970
        let end = (flight.endDate ?? flight.startDate).timeIntervalSince1970

        return "\(distance)|\(duration)|\(calories)|\(averageSpeed)|\(maxSpeed)|\(totalPoints)|\(start)|\(end)"
    }

    func markResynced(flightID: UUID, signature: String, date: Date = Date()) {
        runOnMain {
            if let index = self.savedFlights.firstIndex(where: { $0.id == flightID }) {
                self.savedFlights[index].lastResyncSignature = signature
                self.savedFlights[index].lastResyncedAt = date
                self.persistFlights()
            }
        }

        if var details = loadFlightDetails(id: flightID) {
            details.lastResyncSignature = signature
            details.lastResyncedAt = date
            persistFlightDetails(details)
        }
    }

    // CRITICAL: Incremental save to prevent memory overflow
    // This saves the flight progressively without waiting until the end
    func saveFlightIncremental(_ flight: Flight, metrics: FlightMetrics) {
        // Update the flight with current metrics
        var updatedFlight = flight
        updatedFlight.metrics = metrics

        // Save full details to disk (overwrites previous version with updated data); fast compression, as this
        // runs at every watch checkpoint.
        persistFlightDetails(updatedFlight, level: 1)

        // Update summary in memory
        let summary = summarizedFlight(from: updatedFlight)
        runOnMain {
            if let index = self.savedFlights.firstIndex(where: { $0.id == flight.id }) {
                self.savedFlights[index] = summary
            } else {
                self.savedFlights.insert(summary, at: 0)
            }

            // Persist summaries - coalesced (build 158): this runs at every watch checkpoint.
            self.schedulePersistFlights()
        }
    }

    // THE WORKOUT LIST IS WRITTEN AT MOST EVERY 30 s DURING A WATCH WORKOUT (build 158). Each watch checkpoint (about 75
    // a day) re-encoded all ~3,900 summaries on the main thread and rewrote flights.json (3.6 MB, pretty-printed).
    // Checkpoints now mark it dirty; one write follows 30 s later, encoded off the main thread, and a pending write is
    // made at once when the app goes to the background. Every other save (a finished workout, an edit, a deletion)
    // still writes straight away. Losing at most 30 s of a running watch workout's summary to a crash is harmless:
    // its full route is saved at every checkpoint and the final file rewrites the summary.
    private var persistFlightsPending: DispatchWorkItem?
    private let persistQueue = DispatchQueue(label: "euleryu.gps.flights-json", qos: .utility)
    private var backgroundObserver: NSObjectProtocol?

    private func schedulePersistFlights() {
        guard persistFlightsPending == nil else { return }
        if backgroundObserver == nil {
            backgroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.flushPendingPersistFlights()
            }
        }
        let work = DispatchWorkItem { [weak self] in self?.flushPendingPersistFlights() }
        persistFlightsPending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    /// On the main thread: write a pending coalesced list now (the snapshot is encoded off the main thread).
    private func flushPendingPersistFlights() {
        guard let pending = persistFlightsPending else { return }
        pending.cancel()
        persistFlightsPending = nil
        guard isLoaded else { persistAfterLoad = true; return }
        let snapshot = savedFlights
        persistQueue.async { [weak self] in self?.persistFlightsSnapshot(snapshot) }
    }

    /// THE WATCH'S FLIGHT, KEPT BETWEEN CHECKPOINTS (build 127). When the watch can reach the phone it sends each
    /// checkpoint twice - a file transfer and an immediate message - and both were merged: the location tail was
    /// replaced (harmless) but every history was appended twice, so a stored watch workout carried its speed,
    /// altitude and pressure samples twice over. And each merge decoded the whole growing file first. Now a checkpoint
    /// already merged is skipped, merges run one at a time (the two deliveries arrive on different queues), and the
    /// merged flight stays in memory for the next checkpoint instead of being read back from disk.
    private let checkpointLock = NSLock()
    private var checkpointFlight: Flight?
    private var mergedCheckpoints = Set<String>()

    func mergeFlightCheckpoint(_ checkpoint: FlightCheckpointPayload) {
        checkpointLock.lock(); defer { checkpointLock.unlock() }
        let key = "\(checkpoint.flightID)|\(checkpoint.locationStartIndex)|\(checkpoint.totalLocationCount)|\(checkpoint.locations.count)|\(checkpoint.isFinal)|\(checkpoint.metrics.totalDistance)"
        guard mergedCheckpoints.insert(key).inserted else {
            print("📱 Watch checkpoint already merged (second delivery) - skipped")
            return
        }
        var mergedFlight = (checkpointFlight?.id == checkpoint.flightID ? checkpointFlight : nil)
            ?? loadFlightDetails(id: checkpoint.flightID) ?? Flight(
            id: checkpoint.flightID,
            startDate: checkpoint.startDate
        )

        mergedFlight.startDate = checkpoint.startDate
        mergedFlight.endDate = checkpoint.endDate
        mergedFlight.metrics = mergeMetrics(existing: mergedFlight.metrics, checkpoint: checkpoint.metrics)
        mergedFlight.effort = checkpoint.effort
        mergedFlight.workoutType = checkpoint.workoutType
        // Link to the HealthKit workout so the Workouts tab can find this track.
        if let workoutUUID = checkpoint.workoutUUID {
            mergedFlight.workoutUUID = workoutUUID
        }

        if checkpoint.locationStartIndex <= mergedFlight.locations.count {
            if checkpoint.locationStartIndex < mergedFlight.locations.count {
                mergedFlight.locations.removeSubrange(checkpoint.locationStartIndex..<mergedFlight.locations.count)
            }
            mergedFlight.locations.append(contentsOf: checkpoint.locations)
        } else {
            print("📱 ⚠️ Watch checkpoint gap: local=\(mergedFlight.locations.count), incomingStart=\(checkpoint.locationStartIndex)")
            mergedFlight.locations.append(contentsOf: checkpoint.locations)
            mergedFlight.locations.sort { $0.timestamp < $1.timestamp }
        }

        let metrics = mergedFlight.metrics ?? checkpoint.metrics
        mergedFlight.metrics = metrics
        checkpointFlight = checkpoint.isFinal ? nil : mergedFlight
        // THE ROUTE FILE AT MOST EVERY 2 MINUTES DURING A WATCH WORKOUT (build 160). Each checkpoint re-encoded the whole
        // growing route as JSON and rewrote it - the work grows with the workout, at every checkpoint. The merged flight
        // stays in memory between writes, the summary still updates at once, the final checkpoint and the app going to
        // the background always write, and the watch keeps its own copy until its final file has arrived.
        let now = Date()
        if checkpoint.isFinal || checkpointPersistedFlightID != checkpoint.flightID
            || now.timeIntervalSince(checkpointPersistedAt) >= 120 {
            checkpointPersistedAt = now
            checkpointPersistedFlightID = checkpoint.isFinal ? nil : checkpoint.flightID
            checkpointUnsaved = nil
            saveFlightIncremental(mergedFlight, metrics: metrics)
        } else {
            checkpointUnsaved = mergedFlight
            updateSummaryOnly(mergedFlight, metrics: metrics)
            observeBackgroundForCheckpoints()
        }
    }

    private var checkpointPersistedAt = Date.distantPast
    private var checkpointPersistedFlightID: UUID?
    private var checkpointUnsaved: Flight?
    private var checkpointBackgroundObserver: NSObjectProtocol?

    private func updateSummaryOnly(_ flight: Flight, metrics: FlightMetrics) {
        var updated = flight
        updated.metrics = metrics
        let summary = summarizedFlight(from: updated)
        runOnMain {
            if let index = self.savedFlights.firstIndex(where: { $0.id == flight.id }) {
                self.savedFlights[index] = summary
            } else {
                self.savedFlights.insert(summary, at: 0)
            }
            self.schedulePersistFlights()
        }
    }

    private func observeBackgroundForCheckpoints() {
        guard checkpointBackgroundObserver == nil else { return }
        checkpointBackgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.checkpointLock.lock(); defer { self.checkpointLock.unlock() }
            if let pending = self.checkpointUnsaved, let m = pending.metrics {
                self.checkpointUnsaved = nil
                self.checkpointPersistedAt = Date()
                self.saveFlightIncremental(pending, metrics: m)
            }
        }
    }

    private func mergeMetrics(existing: FlightMetrics?, checkpoint: FlightMetrics) -> FlightMetrics {
        guard var existing else {
            return checkpoint
        }

        let existingSpeedHistory = existing.speedHistory
        let existingAltitudeHistory = existing.altitudeHistory
        let existingPressureHistory = existing.pressureHistory
        let existingAccelerationHistory = existing.accelerationHistory ?? []
        let existingMotionAccelerationHistory = existing.motionAccelerationHistory ?? []
        let existingAttitudeHistory = existing.attitudeHistory ?? []
        let existingRotationRateHistory = existing.rotationRateHistory ?? []
        let existingCompassHeadingHistory = existing.compassHeadingHistory ?? []
        let existingBarometricAltitudeHistory = existing.barometricAltitudeHistory ?? []
        let existingGPSQualityHistory = existing.gpsQualityHistory ?? []

        existing = checkpoint
        existing.speedHistory = existingSpeedHistory + checkpoint.speedHistory
        existing.altitudeHistory = existingAltitudeHistory + checkpoint.altitudeHistory
        existing.pressureHistory = existingPressureHistory + checkpoint.pressureHistory
        existing.accelerationHistory = existingAccelerationHistory + (checkpoint.accelerationHistory ?? [])
        existing.motionAccelerationHistory = existingMotionAccelerationHistory + (checkpoint.motionAccelerationHistory ?? [])
        existing.attitudeHistory = existingAttitudeHistory + (checkpoint.attitudeHistory ?? [])
        existing.rotationRateHistory = existingRotationRateHistory + (checkpoint.rotationRateHistory ?? [])
        existing.compassHeadingHistory = existingCompassHeadingHistory + (checkpoint.compassHeadingHistory ?? [])
        existing.barometricAltitudeHistory = existingBarometricAltitudeHistory + (checkpoint.barometricAltitudeHistory ?? [])
        existing.gpsQualityHistory = existingGPSQualityHistory + (checkpoint.gpsQualityHistory ?? [])
        return existing
    }

    func deleteFlight(_ flight: Flight) {
        print("🗑️ Deleting flight: \(flight.id)")
        checkpointLock.lock(); if checkpointFlight?.id == flight.id { checkpointFlight = nil }; checkpointLock.unlock()
        runOnMain {
            self.savedFlights.removeAll { $0.id == flight.id }
            self.persistFlights()
        }
        deleteFlightDetails(for: flight.id)
    }

    func deleteFlight(at index: Int) {
        runOnMain {
            guard index >= 0 && index < self.savedFlights.count else { return }
            let flight = self.savedFlights[index]
            print("🗑️ Deleting flight at index \(index): \(flight.id)")
            self.savedFlights.remove(at: index)
            self.persistFlights()
            self.deleteFlightDetails(for: flight.id)
        }
    }

    func getFlight(by id: UUID) -> Flight? {
        return savedFlights.first { $0.id == id }
    }

    func loadFlights() {
        runOnMain {
            guard !self.loadInFlight else { return }
            self.loadInFlight = true
            self.loadQueue.async { self.loadFlightsFromDisk() }
        }
    }

    private func loadFlightsFromDisk() {
        print("📂 Loading flights from local storage...")

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("   No saved flights file found")
            runOnMain { self.finishLoad([]) }
            return
        }

        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var decodedFlights = try decoder.decode([Flight].self, from: data)
            print("✅ Loaded \(decodedFlights.count) flights from storage")

            // Migrate any legacy full flights into detail files and keep summaries in memory.
            var needsSummaryUpdate = false
            for index in decodedFlights.indices {
                let flight = decodedFlights[index]
                if needsDetailMigration(for: flight) {
                    // Only write the detail file when this record actually carries
                    // location data — otherwise (history-only bloat) we'd clobber
                    // the existing good detail file with an empty-locations flight.
                    if !flight.locations.isEmpty {
                        persistFlightDetails(flight)
                    }
                    decodedFlights[index] = summarizedFlight(from: flight)
                    needsSummaryUpdate = true
                }
            }
            let loadedList = decodedFlights
            runOnMain { self.finishLoad(loadedList) }

            if needsSummaryUpdate {
                runOnMain {
                    self.persistFlights()
                }
                print("✅ Migrated legacy flights to detail files")
            }

            // Fix any flights missing max speed in their metrics
            var needsUpdate = false
            for i in 0..<decodedFlights.count {
                if var metrics = decodedFlights[i].metrics,
                   metrics.maxSpeed == 0.0,
                   !decodedFlights[i].locations.isEmpty {

                    // Recalculate max speed from saved locations
                    let speeds = decodedFlights[i].locations.map { $0.speed }.filter { $0 >= 0 }
                    if !speeds.isEmpty {
                        metrics.maxSpeed = speeds.max() ?? 0
                        decodedFlights[i].metrics = metrics
                        needsUpdate = true
                        print("   ⚠️ Fixed missing max speed for flight \(i + 1): \(String(format: "%.1f", metrics.maxSpeed * 3.6))km/h")
                    }
                }
            }

            // Save if we fixed any flights
            if needsUpdate {
                let fixed = Dictionary(decodedFlights.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                runOnMain {
                    for i in self.savedFlights.indices { if let f = fixed[self.savedFlights[i].id] { self.savedFlights[i] = f } }
                    self.persistFlights()
                }
                print("✅ Updated flights with recalculated max speeds")
            }

            // Effort is user-selected; no automatic migration needed.

            // Log summary
            for (index, flight) in decodedFlights.prefix(5).enumerated() {
                let distance = (flight.metrics?.totalDistance ?? 0) / 1000
                let maxSpeed = (flight.metrics?.maxSpeed ?? 0) * 3.6
                print("   \(index + 1). \(formatDate(flight.startDate)) - \(String(format: "%.2f", distance))km, \(flight.locations.count) locations, max speed: \(String(format: "%.1f", maxSpeed))km/h")
            }
            if decodedFlights.count > 5 {
                print("   ... and \(decodedFlights.count - 5) more")
            }
        } catch {
            // Kept aside (build 160), not overwritten by the next save as before: the next write starts a new list.
            print("❌ Failed to load flights: \(error.localizedDescription)")
            let aside = fileURL.deletingLastPathComponent()
                .appendingPathComponent("flights.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: fileURL, to: aside)
            runOnMain { self.finishLoad(nil) }
        }
    }

    // MARK: - Private Methods

    private func persistFlights() {
        persistFlightsPending?.cancel(); persistFlightsPending = nil
        guard isLoaded else { persistAfterLoad = true; return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(savedFlights)
            try data.write(to: fileURL, options: .atomic)
            print("✅ Saved \(savedFlights.count) flights to storage")
        } catch {
            print("❌ Failed to save flights: \(error.localizedDescription)")
        }
    }

    private func persistFlightDetails(_ flight: Flight, level: Int32 = LogCompression.level) {
        let detailsURL = compressedDetailsURL(for: flight.id)

        // SAFETY: Validate data before attempting to encode
        guard !flight.id.uuidString.isEmpty else {
            print("❌ Cannot persist flight details - invalid ID")
            return
        }

        // SAFETY: Check for NaN or Inf values in metrics that could cause encoding issues
        if let metrics = flight.metrics {
            guard !metrics.totalDistance.isNaN && !metrics.totalDistance.isInfinite,
                  !metrics.averageSpeed.isNaN && !metrics.averageSpeed.isInfinite,
                  !metrics.maxSpeed.isNaN && !metrics.maxSpeed.isInfinite else {
                print("❌ Cannot persist flight details - invalid metric values (NaN/Inf)")
                return
            }
        }

        // Refresh the compact route cache so the Map tab never has to decode the
        // full detail file.
        if flight.locations.count > 1 {
            let sampled = Self.sampleLocations(flight.locations, maxPoints: 400)
            writeRouteCache(id: flight.id, coordinates: sampled.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            })
        }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(flight)
            let packed = LogCompression.gzipMember(data, level: level)
            guard !packed.isEmpty else { throw CocoaError(.fileWriteUnknown) }
            try packed.write(to: detailsURL, options: .atomic)
            // An older plain copy of this route is now superseded.
            try? FileManager.default.removeItem(at: plainDetailsURL(for: flight.id))
            print("✅ Saved flight details for \(flight.id)")
            print("   📁 File: \(detailsURL.lastPathComponent)")
            print("   📍 Locations: \(flight.locations.count)")
            if let metrics = flight.metrics {
                print("   📏 Distance: \(String(format: "%.2f", metrics.totalDistance/1000))km")
            }
        } catch let error as EncodingError {
            print("❌ Encoding error saving flight details: \(error)")
            switch error {
            case .invalidValue(let value, let context):
                print("   Invalid value: \(value) at path: \(context.codingPath)")
            default:
                print("   \(error.localizedDescription)")
            }
        } catch {
            print("❌ Failed to save flight details: \(error.localizedDescription)")
        }
    }

    func loadFlightDetails(id: UUID) -> Flight? {
        let detailsURL = flightDetailsURL(for: id)
        guard FileManager.default.fileExists(atPath: detailsURL.path) else { return nil }

        do {
            let data = try LogCompression.gunzipIfNeeded(Data(contentsOf: detailsURL, options: .mappedIfSafe))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Flight.self, from: data)
        } catch {
            print("❌ Failed to load flight details: \(error.localizedDescription)")
            return nil
        }
    }

    private func deleteFlightDetails(for id: UUID) {
        deleteRouteCache(for: id)
        try? FileManager.default.removeItem(at: plainDetailsURL(for: id))
        let detailsURL = compressedDetailsURL(for: id)
        guard FileManager.default.fileExists(atPath: detailsURL.path) else { return }

        do {
            try FileManager.default.removeItem(at: detailsURL)
            print("✅ Deleted flight details for \(id)")
        } catch {
            print("❌ Failed to delete flight details: \(error.localizedDescription)")
        }
    }

    private func summarizedFlight(from flight: Flight) -> Flight {
        var summary = flight
        summary.locations = []
        if var metrics = summary.metrics {
            // Strip ALL time-series histories from the list summary. They live in
            // the per-flight detail file. Keeping them here bloats flights.json,
            // which is loaded/decoded into memory on the Workouts tab — a major
            // lag and memory source on iPhone.
            metrics.speedHistory = []
            metrics.altitudeHistory = []
            metrics.pressureHistory = []
            metrics.accelerationHistory = nil
            metrics.motionAccelerationHistory = nil
            metrics.attitudeHistory = nil
            metrics.rotationRateHistory = nil
            metrics.compassHeadingHistory = nil
            metrics.barometricAltitudeHistory = nil
            metrics.gpsQualityHistory = nil
            summary.metrics = metrics
        }
        return summary
    }

    private func needsDetailMigration(for flight: Flight) -> Bool {
        if !flight.locations.isEmpty {
            return true
        }
        guard let metrics = flight.metrics else { return false }
        // Any leftover history in a summary means the on-disk summary is bloated
        // and should be slimmed (histories belong only in the detail file).
        if !metrics.speedHistory.isEmpty || !metrics.altitudeHistory.isEmpty
            || !metrics.pressureHistory.isEmpty
            || (metrics.accelerationHistory?.isEmpty == false)
            || (metrics.motionAccelerationHistory?.isEmpty == false)
            || (metrics.attitudeHistory?.isEmpty == false)
            || (metrics.rotationRateHistory?.isEmpty == false)
            || (metrics.compassHeadingHistory?.isEmpty == false)
            || (metrics.barometricAltitudeHistory?.isEmpty == false)
            || (metrics.gpsQualityHistory?.isEmpty == false) {
            return true
        }
        return false
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func loadSyncMetadata() {
        guard FileManager.default.fileExists(atPath: syncMetadataURL.path) else {
            print("   No sync metadata file found")
            runOnMain {
                self.lastSyncDate = nil
            }
            return
        }

        do {
            let data = try Data(contentsOf: syncMetadataURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let metadata = try? decoder.decode([String: Date].self, from: data),
               let syncDate = metadata["lastSyncDate"] {
                runOnMain {
                    self.lastSyncDate = syncDate
                }
                print("✅ Loaded sync metadata - last sync: \(formatDate(syncDate))")
            }
        } catch {
            print("❌ Failed to load sync metadata: \(error.localizedDescription)")
            runOnMain {
                self.lastSyncDate = nil
            }
        }
    }

    private func saveSyncMetadata() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let metadata: [String: Date] = ["lastSyncDate": Date()]
            let data = try encoder.encode(metadata)
            try data.write(to: syncMetadataURL, options: .atomic)
            runOnMain {
                self.lastSyncDate = Date()
            }
            print("✅ Saved sync metadata")
        } catch {
            print("❌ Failed to save sync metadata: \(error.localizedDescription)")
        }
    }

    // MARK: - Storage Info

    var storageSize: String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return "0 KB"
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            if let size = attributes[.size] as? Int64 {
                if size < 1024 {
                    return "\(size) B"
                } else if size < 1024 * 1024 {
                    return String(format: "%.1f KB", Double(size) / 1024.0)
                } else {
                    return String(format: "%.1f MB", Double(size) / (1024.0 * 1024.0))
                }
            }
        } catch {
            print("❌ Failed to get storage size: \(error.localizedDescription)")
        }

        return "Unknown"
    }

    func clearAllFlights() {
        print("🗑️ Clearing all saved flights...")
        runOnMain {
            self.savedFlights = []
        }

        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
                print("✅ Deleted flights storage file")
            }

            let files = try FileManager.default.contentsOfDirectory(
                at: documentsDirectory,
                includingPropertiesForKeys: nil
            )
            for file in files where file.lastPathComponent.hasPrefix(detailsFilePrefix) {
                try? FileManager.default.removeItem(at: file)
            }
            print("✅ Deleted all flight detail files")
        } catch {
            print("❌ Failed to delete storage file: \(error.localizedDescription)")
        }
    }
}
