import Foundation
import HealthKit

struct WorkoutSummary: Identifiable, Codable, Hashable {
    let id: UUID
    var startDate: Date
    var endDate: Date
    var duration: TimeInterval
    var totalDistance: Double
    var activityTypeRaw: UInt
    var calories: Double?
    var steps: Double?

    var activityType: HKWorkoutActivityType? {
        HKWorkoutActivityType(rawValue: activityTypeRaw)
    }

    init(
        id: UUID,
        startDate: Date,
        endDate: Date,
        duration: TimeInterval,
        totalDistance: Double,
        activityTypeRaw: UInt,
        calories: Double?,
        steps: Double?
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.duration = duration
        self.totalDistance = totalDistance
        self.activityTypeRaw = activityTypeRaw
        self.calories = calories
        self.steps = steps
    }

    init(workout: HKWorkout) {
        let distance = workout.totalDistance?.doubleValue(for: .meter()) ?? 0
        let calories: Double?
        let steps: Double?

        if #available(iOS 18.0, *) {
            calories = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
                .sumQuantity()?
                .doubleValue(for: .kilocalorie())
            steps = workout.statistics(for: HKQuantityType(.stepCount))?
                .sumQuantity()?
                .doubleValue(for: .count())
        } else {
            calories = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie())
            if let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) {
                steps = workout.statistics(for: stepType)?
                    .sumQuantity()?
                    .doubleValue(for: .count())
            } else {
                steps = nil
            }
        }

        self.init(
            id: workout.uuid,
            startDate: workout.startDate,
            endDate: workout.endDate,
            duration: workout.duration,
            totalDistance: distance,
            activityTypeRaw: workout.workoutActivityType.rawValue,
            calories: calories,
            steps: steps
        )
    }
}

final class WorkoutCacheStore {
    static let shared = WorkoutCacheStore()

    private let fileName = "healthkit_workouts_cache.json"
    private let folderName = "WorkoutCache"
    private let anchorFileName = "healthkit_workouts_anchor.dat"
    private let markerFileName = "README.txt"

    private var cacheDirectoryURL: URL {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let cacheDirectory = documentsDirectory.appendingPathComponent(folderName, isDirectory: true)
        ensureDirectoryExists(cacheDirectory)
        ensureMarkerFile(at: cacheDirectory)
        return cacheDirectory
    }

    private var fileURL: URL {
        cacheDirectoryURL.appendingPathComponent(fileName)
    }

    private var anchorURL: URL {
        cacheDirectoryURL.appendingPathComponent(anchorFileName)
    }

    private init() {}

    private func ensureDirectoryExists(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) { return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            print("✅ Created workout cache folder: \(url.lastPathComponent)")
        } catch {
            print("❌ Failed to create workout cache folder: \(error.localizedDescription)")
        }
    }

    private func ensureMarkerFile(at folderURL: URL) {
        let markerURL = folderURL.appendingPathComponent(markerFileName)
        guard !FileManager.default.fileExists(atPath: markerURL.path) else { return }
        let contents = """
        Workout cache files for GPS location app.
        You can safely keep this file.
        """
        do {
            try contents.data(using: .utf8)?.write(to: markerURL, options: .atomic)
        } catch {
            print("❌ Failed to create workout cache marker file: \(error.localizedDescription)")
        }
    }

    func loadWorkouts() -> [WorkoutSummary] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([WorkoutSummary].self, from: data)
        } catch {
            print("❌ Failed to load workout cache: \(error.localizedDescription)")
            return []
        }
    }

    func saveWorkouts(_ workouts: [WorkoutSummary]) {
        do {
            _ = cacheDirectoryURL
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(workouts)
            try data.write(to: fileURL, options: .atomic)
            print("✅ Saved \(workouts.count) workouts to cache")
        } catch {
            print("❌ Failed to save workout cache: \(error.localizedDescription)")
        }
    }

    func ensureVisibleFolder() -> URL? {
        _ = cacheDirectoryURL
        return cacheDirectoryURL
    }

    func loadAnchor() -> HKQueryAnchor? {
        guard FileManager.default.fileExists(atPath: anchorURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: anchorURL, options: .mappedIfSafe)
            return try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
        } catch {
            print("❌ Failed to load workout anchor: \(error.localizedDescription)")
            return nil
        }
    }

    func saveAnchor(_ anchor: HKQueryAnchor) {
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
            try data.write(to: anchorURL, options: .atomic)
            print("✅ Saved workout anchor")
        } catch {
            print("❌ Failed to save workout anchor: \(error.localizedDescription)")
        }
    }

    func clear() {
        do {
            let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let cacheDirectory = documentsDirectory.appendingPathComponent(folderName, isDirectory: true)
            if FileManager.default.fileExists(atPath: cacheDirectory.path) {
                try FileManager.default.removeItem(at: cacheDirectory)
            } else if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            print("🧹 Cleared workout cache folder")
        } catch {
            print("❌ Failed to clear workout cache: \(error.localizedDescription)")
        }
    }
}
