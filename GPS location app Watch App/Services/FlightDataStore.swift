import Foundation
import HealthKit

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

    private init() {
        loadFlights()
        loadSyncMetadata()
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

        // Check if flight already exists (update) or is new (append)
        if let index = savedFlights.firstIndex(where: { $0.id == flight.id }) {
            savedFlights[index] = summary
            print("   Updated existing flight")
        } else {
            savedFlights.insert(summary, at: 0)  // Add to beginning (most recent first)
            print("   Added new flight")
        }

        persistFlights()
    }

    // CRITICAL: Incremental save to prevent memory overflow on Apple Watch
    // This saves the flight progressively without waiting until the end
    func saveFlightIncremental(_ flight: Flight, metrics: FlightMetrics) {
        // Update the flight with current metrics
        var updatedFlight = flight
        updatedFlight.metrics = metrics

        // Validate data before saving
        guard !updatedFlight.id.uuidString.isEmpty else {
            print("❌ Cannot save flight - invalid ID")
            return
        }

        // Save full details to disk (overwrites previous version with updated data)
        persistFlightDetails(updatedFlight)

        // Update summary in memory
        let summary = summarizedFlight(from: updatedFlight)
        if let index = savedFlights.firstIndex(where: { $0.id == flight.id }) {
            savedFlights[index] = summary
        } else {
            savedFlights.insert(summary, at: 0)
        }

        // Persist summaries
        persistFlights()

        print("✅ Incremental save completed successfully - \(updatedFlight.locations.count) locations")
    }

    func deleteFlight(_ flight: Flight) {
        print("🗑️ Deleting flight: \(flight.id)")
        savedFlights.removeAll { $0.id == flight.id }
        deleteFlightDetails(for: flight.id)
        persistFlights()
    }

    func deleteFlight(at index: Int) {
        guard index >= 0 && index < savedFlights.count else { return }
        let flight = savedFlights[index]
        print("🗑️ Deleting flight at index \(index): \(flight.id)")
        savedFlights.remove(at: index)
        deleteFlightDetails(for: flight.id)
        persistFlights()
    }

    func getFlight(by id: UUID) -> Flight? {
        return savedFlights.first { $0.id == id }
    }

    func loadFlights() {
        print("📂 Loading flights from local storage...")

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("   No saved flights file found")
            savedFlights = []
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
                    persistFlightDetails(flight)
                    decodedFlights[index] = summarizedFlight(from: flight)
                    needsSummaryUpdate = true
                }
            }
            savedFlights = decodedFlights

            if needsSummaryUpdate {
                persistFlights()
                print("✅ Migrated legacy flights to detail files")
            }

            // Fix any flights missing max speed in their metrics
            var needsUpdate = false
            for i in 0..<savedFlights.count {
                if var metrics = savedFlights[i].metrics,
                   metrics.maxSpeed == 0.0,
                   !savedFlights[i].locations.isEmpty {

                    // Recalculate max speed from saved locations
                    let speeds = savedFlights[i].locations.map { $0.speed }.filter { $0 >= 0 }
                    if !speeds.isEmpty {
                        metrics.maxSpeed = speeds.max() ?? 0
                        savedFlights[i].metrics = metrics
                        needsUpdate = true
                        print("   ⚠️ Fixed missing max speed for flight \(i + 1): \(String(format: "%.1f", metrics.maxSpeed * 3.6))km/h")
                    }
                }
            }

            // Save if we fixed any flights
            if needsUpdate {
                persistFlights()
                print("✅ Updated flights with recalculated max speeds")
            }

            // Effort is user-selected; no automatic migration needed.

            // Log summary
            for (index, flight) in savedFlights.prefix(5).enumerated() {
                let distance = (flight.metrics?.totalDistance ?? 0) / 1000
                let maxSpeed = (flight.metrics?.maxSpeed ?? 0) * 3.6
                print("   \(index + 1). \(formatDate(flight.startDate)) - \(String(format: "%.2f", distance))km, \(flight.locations.count) locations, max speed: \(String(format: "%.1f", maxSpeed))km/h")
            }
            if savedFlights.count > 5 {
                print("   ... and \(savedFlights.count - 5) more")
            }
        } catch {
            print("❌ Failed to load flights: \(error.localizedDescription)")
            savedFlights = []
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
            print("⌚ ❌ Cannot persist flight details - invalid ID")
            return
        }

        // SAFETY: Check for NaN or Inf values in metrics that could cause encoding issues
        if let metrics = flight.metrics {
            guard !metrics.totalDistance.isNaN && !metrics.totalDistance.isInfinite,
                  !metrics.averageSpeed.isNaN && !metrics.averageSpeed.isInfinite,
                  !metrics.maxSpeed.isNaN && !metrics.maxSpeed.isInfinite else {
                print("⌚ ❌ Cannot persist flight details - invalid metric values (NaN/Inf)")
                return
            }
        }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(flight)
            try data.write(to: detailsURL, options: .atomic)
            print("⌚ ✅ Saved flight details for \(flight.id)")
        } catch let error as EncodingError {
            print("⌚ ❌ Encoding error saving flight details: \(error)")
            switch error {
            case .invalidValue(let value, let context):
                print("   Invalid value: \(value) at path: \(context.codingPath)")
            default:
                print("   \(error.localizedDescription)")
            }
        } catch {
            print("⌚ ❌ Failed to save flight details: \(error.localizedDescription)")
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
            metrics.speedHistory = []
            metrics.altitudeHistory = []
            summary.metrics = metrics
        }
        return summary
    }

    private func needsDetailMigration(for flight: Flight) -> Bool {
        if !flight.locations.isEmpty {
            return true
        }
        if let metrics = flight.metrics,
           !metrics.speedHistory.isEmpty || !metrics.altitudeHistory.isEmpty {
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
            lastSyncDate = nil
            return
        }

        do {
            let data = try Data(contentsOf: syncMetadataURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let metadata = try? decoder.decode([String: Date].self, from: data),
               let syncDate = metadata["lastSyncDate"] {
                lastSyncDate = syncDate
                print("✅ Loaded sync metadata - last sync: \(formatDate(syncDate))")
            }
        } catch {
            print("❌ Failed to load sync metadata: \(error.localizedDescription)")
            lastSyncDate = nil
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
            lastSyncDate = Date()
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
        savedFlights = []

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
