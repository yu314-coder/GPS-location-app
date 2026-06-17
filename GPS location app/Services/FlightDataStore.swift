import Foundation
import HealthKit
import CoreLocation

class FlightDataStore: ObservableObject {
    static let shared = FlightDataStore()

    @Published var savedFlights: [Flight] = []
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

    private func flightDetailsURL(for id: UUID) -> URL {
        documentsDirectory.appendingPathComponent("\(detailsFilePrefix)\(id.uuidString).json")
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
        // 1) Fast path: compact cache file.
        let cacheURL = routeCacheURL(for: id)
        if let data = try? Data(contentsOf: cacheURL, options: .mappedIfSafe),
           let entry = try? JSONDecoder().decode(RouteCacheEntry.self, from: data) {
            return entry.coords.compactMap { pair in
                guard pair.count == 2 else { return nil }
                return CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
            }
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
        let entry = RouteCacheEntry(coords: coordinates.map { [$0.latitude, $0.longitude] })
        if let data = try? JSONEncoder().encode(entry) {
            try? data.write(to: routeCacheURL(for: id), options: .atomic)
        }
    }

    private func deleteRouteCache(for id: UUID) {
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

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                // Write each flight's full details to disk off the main thread
                let summaries = flights.compactMap { flight -> Flight? in
                    guard !flight.id.uuidString.isEmpty else { return nil }
                    self.persistFlightDetails(flight)
                    return self.summarizedFlight(from: flight)
                }

                DispatchQueue.main.async {
                    // Merge summaries into the in-memory array (single update)
                    for summary in summaries {
                        if let index = self.savedFlights.firstIndex(where: { $0.id == summary.id }) {
                            self.savedFlights[index] = summary
                        } else {
                            self.savedFlights.insert(summary, at: 0)
                        }
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
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
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

        // Save full details to disk (overwrites previous version with updated data)
        persistFlightDetails(updatedFlight)

        // Update summary in memory
        let summary = summarizedFlight(from: updatedFlight)
        runOnMain {
            if let index = self.savedFlights.firstIndex(where: { $0.id == flight.id }) {
                self.savedFlights[index] = summary
            } else {
                self.savedFlights.insert(summary, at: 0)
            }

            // Persist summaries
            self.persistFlights()
        }
    }

    func mergeFlightCheckpoint(_ checkpoint: FlightCheckpointPayload) {
        var mergedFlight = loadFlightDetails(id: checkpoint.flightID) ?? Flight(
            id: checkpoint.flightID,
            startDate: checkpoint.startDate
        )

        mergedFlight.startDate = checkpoint.startDate
        mergedFlight.endDate = checkpoint.endDate
        mergedFlight.metrics = mergeMetrics(existing: mergedFlight.metrics, checkpoint: checkpoint.metrics)
        mergedFlight.effort = checkpoint.effort
        mergedFlight.workoutType = checkpoint.workoutType

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

        saveFlightIncremental(mergedFlight, metrics: mergedFlight.metrics ?? checkpoint.metrics)
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
        print("📂 Loading flights from local storage...")

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("   No saved flights file found")
            runOnMain {
                self.savedFlights = []
            }
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
            runOnMain {
                self.savedFlights = decodedFlights
            }

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
                runOnMain {
                    self.savedFlights = decodedFlights
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
            print("❌ Failed to load flights: \(error.localizedDescription)")
            runOnMain {
                self.savedFlights = []
            }
        }
    }

    // MARK: - Private Methods

    private func persistFlights() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(savedFlights)
            try data.write(to: fileURL, options: .atomic)
            print("✅ Saved \(savedFlights.count) flights to storage")
        } catch {
            print("❌ Failed to save flights: \(error.localizedDescription)")
        }
    }

    private func persistFlightDetails(_ flight: Flight) {
        let detailsURL = flightDetailsURL(for: flight.id)

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
            try data.write(to: detailsURL, options: .atomic)
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
            let data = try Data(contentsOf: detailsURL, options: .mappedIfSafe)
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
        let detailsURL = flightDetailsURL(for: id)
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
            encoder.outputFormatting = .prettyPrinted
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
