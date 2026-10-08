import Foundation
import MapKit
import UIKit

/// Disk-backed map tiles, so the map still draws with no network.
///
/// Every tile fetched while online is written to Caches/. On a later load the file is served
/// first and the network is only consulted when nothing is stored, so any area already viewed
/// keeps working in a tunnel, a basement or an aircraft.
final class OfflineTileCache: ObservableObject {
    static let shared = OfflineTileCache()

    @Published private(set) var isDownloading = false
    @Published private(set) var downloadedCount = 0
    @Published private(set) var totalToDownload = 0

    /// Standard OSM raster tiles. Their tile policy asks for a real User-Agent and forbids bulk
    /// downloading, so the pre-fetch here is deliberately bounded: a coarse world overview, or
    /// one modest area at a time, never a whole planet at street zoom.
    private let template = "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
    private let userAgent = "GPSLocationApp/1.0 (personal workout tracker)"

    private lazy var root: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MapTiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func fileURL(_ path: MKTileOverlayPath) -> URL {
        root.appendingPathComponent("\(path.z)_\(path.x)_\(path.y).png")
    }

    func makeOverlay() -> MKTileOverlay { CachingTileOverlay(cache: self, template: template) }

    // MARK: - Reading / writing

    fileprivate func cachedData(for path: MKTileOverlayPath) -> Data? {
        try? Data(contentsOf: fileURL(path))
    }

    fileprivate func store(_ data: Data, for path: MKTileOverlayPath) {
        try? data.write(to: fileURL(path), options: .atomic)
    }

    fileprivate func url(for path: MKTileOverlayPath) -> URL {
        let s = template
            .replacingOccurrences(of: "{z}", with: String(path.z))
            .replacingOccurrences(of: "{x}", with: String(path.x))
            .replacingOccurrences(of: "{y}", with: String(path.y))
        return URL(string: s)!
    }

    fileprivate func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return r
    }

    // MARK: - Pre-fetching

    /// Coarse whole-world coverage: z0–z4 is 341 tiles, enough to show coastlines, countries and
    /// major cities. That is the right scale for a flight track, and small enough to be polite.
    func downloadWorldOverview() {
        var paths: [MKTileOverlayPath] = []
        for z in 0...4 {
            let n = 1 << z
            for x in 0..<n { for y in 0..<n {
                paths.append(MKTileOverlayPath(x: x, y: y, z: z, contentScaleFactor: 1))
            } }
        }
        prefetch(paths)
    }

    /// The area around the track, at zoom levels useful for reading a road-level route.
    func downloadCurrentArea(around location: FlightLocation?, fallback: CLLocation?) {
        let centre: CLLocationCoordinate2D
        if let location {
            centre = .init(latitude: location.latitude, longitude: location.longitude)
        } else if let fallback {
            centre = fallback.coordinate
        } else { return }

        var paths: [MKTileOverlayPath] = []
        // ±2 tiles about the centre at each zoom: a few km across at z14, bounded at every level
        // so this stays a handful of hundreds of tiles rather than an unbounded sweep.
        for z in 10...16 {
            let n = 1 << z
            let x = Int((centre.longitude + 180.0) / 360.0 * Double(n))
            let latRad = centre.latitude * .pi / 180
            let y = Int((1 - log(tan(latRad) + 1/cos(latRad)) / .pi) / 2 * Double(n))
            for dx in -2...2 { for dy in -2...2 {
                let tx = x + dx, ty = y + dy
                guard tx >= 0, ty >= 0, tx < n, ty < n else { continue }
                paths.append(MKTileOverlayPath(x: tx, y: ty, z: z, contentScaleFactor: 1))
            } }
        }
        prefetch(paths)
    }

    // MARK: - DEV ONLY: one flight's map (remove before the final release)

    /// DEV ONLY - remove before the final release, with its button in DeveloperView.
    ///
    /// The map along one flight, fetched on the ground so the route can be checked in the air:
    /// every tile within `halfWidthKm` of the great circle between two airports at zooms 3-9
    /// (coasts and islands at a glance, towns at 9), and zooms 11-14 around both airports for the
    /// taxi. About 850 tiles for Taoyuan-Changi. Bounded like the other pre-fetches, because the
    /// OpenStreetMap tile policy forbids bulk downloads; past zoom 9 at sea the map enlarges the
    /// stored tile instead (see CachingTileOverlay).
    func downloadFlightCorridor(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D,
                                halfWidthKm: Double = 150) {
        var seen = Set<String>()
        var paths: [MKTileOverlayPath] = []
        func add(_ x: Int, _ y: Int, _ z: Int) {
            let n = 1 << z
            guard x >= 0, y >= 0, x < n, y < n, seen.insert("\(z)/\(x)/\(y)").inserted else { return }
            paths.append(MKTileOverlayPath(x: x, y: y, z: z, contentScaleFactor: 1))
        }
        let samples = (0...400).map { Self.greatCircle(a, b, fraction: Double($0) / 400) }
        for z in 3...9 {
            for p in samples {
                let tileKm = 40_075.0 * cos(p.latitude * .pi / 180) / Double(1 << z)
                let k = Int((halfWidthKm / tileKm).rounded(.up))
                let (x, y) = Self.tile(p, z)
                for dx in -k...k { for dy in -k...k { add(x + dx, y + dy, z) } }
            }
        }
        for airport in [a, b] {
            for z in 11...14 {
                let (x, y) = Self.tile(airport, z)
                for dx in -2...2 { for dy in -2...2 { add(x + dx, y + dy, z) } }
            }
        }
        prefetch(paths)
    }

    private static func tile(_ c: CLLocationCoordinate2D, _ z: Int) -> (Int, Int) {
        let n = Double(1 << z)
        let latRad = c.latitude * .pi / 180
        return (Int((c.longitude + 180.0) / 360.0 * n),
                Int((1 - log(tan(latRad) + 1 / cos(latRad)) / .pi) / 2 * n))
    }

    private static func greatCircle(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D,
                                    fraction f: Double) -> CLLocationCoordinate2D {
        let r = Double.pi / 180
        let (la1, lo1, la2, lo2) = (a.latitude * r, a.longitude * r, b.latitude * r, b.longitude * r)
        let d = 2 * asin(sqrt(pow(sin((la2 - la1) / 2), 2) + cos(la1) * cos(la2) * pow(sin((lo2 - lo1) / 2), 2)))
        guard d > 0 else { return a }
        let wa = sin((1 - f) * d) / sin(d), wb = sin(f * d) / sin(d)
        let x = wa * cos(la1) * cos(lo1) + wb * cos(la2) * cos(lo2)
        let y = wa * cos(la1) * sin(lo1) + wb * cos(la2) * sin(lo2)
        let zz = wa * sin(la1) + wb * sin(la2)
        return CLLocationCoordinate2D(latitude: atan2(zz, hypot(x, y)) / r, longitude: atan2(y, x) / r)
    }

    /// With nothing stored at this zoom and no network: the nearest stored coarser tile, enlarged,
    /// so zooming in past what was downloaded shows a blurred map rather than a blank one.
    fileprivate func enlargedFromParent(_ path: MKTileOverlayPath) -> Data? {
        for up in 1...6 where path.z - up >= 0 {
            let parent = MKTileOverlayPath(x: path.x >> up, y: path.y >> up, z: path.z - up,
                                           contentScaleFactor: path.contentScaleFactor)
            guard let data = cachedData(for: parent), let cg = UIImage(data: data)?.cgImage else { continue }
            let n = 1 << up
            let w = cg.width / n, h = cg.height / n
            let fx = path.x - (parent.x << up), fy = path.y - (parent.y << up)
            guard w > 0, h > 0, let part = cg.cropping(to: CGRect(x: fx * w, y: fy * h, width: w, height: h)) else { continue }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format).pngData { _ in
                UIImage(cgImage: part).draw(in: CGRect(x: 0, y: 0, width: 256, height: 256))
            }
        }
        return nil
    }

    private func prefetch(_ paths: [MKTileOverlayPath]) {
        guard !isDownloading else { return }
        let missing = paths.filter { !FileManager.default.fileExists(atPath: fileURL($0).path) }
        guard !missing.isEmpty else { return }

        isDownloading = true
        downloadedCount = 0
        totalToDownload = missing.count

        let queue = DispatchQueue(label: "tile.prefetch")
        let session = URLSession(configuration: .default)
        // Serial with a small gap: bulk hammering a public tile server is exactly what its usage
        // policy prohibits, and a stalled download here would be worse than a slow one.
        queue.async { [weak self] in
            guard let self else { return }
            let group = DispatchGroup()
            let limit = DispatchSemaphore(value: 4)
            for path in missing {
                limit.wait(); group.enter()
                session.dataTask(with: self.request(self.url(for: path))) { data, _, _ in
                    if let data, !data.isEmpty { self.store(data, for: path) }
                    DispatchQueue.main.async { self.downloadedCount += 1 }
                    limit.signal(); group.leave()
                }.resume()
            }
            group.wait()
            DispatchQueue.main.async { self.isDownloading = false }
        }
    }

    func cacheSizeBytes() -> Int64 {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(0) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    func clearCache() { try? FileManager.default.removeItem(at: root) }
}

/// Serves the stored tile first and only then the network, so a cached area works with no signal.
private final class CachingTileOverlay: MKTileOverlay {
    private unowned let cache: OfflineTileCache

    init(cache: OfflineTileCache, template: String) {
        self.cache = cache
        super.init(urlTemplate: template)
        self.canReplaceMapContent = true
        self.tileSize = CGSize(width: 256, height: 256)
        self.maximumZ = 19
    }

    override func loadTile(at path: MKTileOverlayPath,
                           result: @escaping (Data?, Error?) -> Void) {
        if let data = cache.cachedData(for: path) {
            result(data, nil)
            return
        }
        let task = URLSession.shared.dataTask(with: cache.request(cache.url(for: path))) { data, _, error in
            if let data, !data.isEmpty {
                self.cache.store(data, for: path)
                result(data, nil)
            } else if let enlarged = self.cache.enlargedFromParent(path) {
                // Offline, nothing at this zoom: a coarser stored tile, enlarged (not stored).
                result(enlarged, nil)
            } else {
                // Offline with nothing stored: hand back empty rather than an error, so the map
                // draws a blank tile under the route instead of tearing the whole overlay down.
                result(Data(), error)
            }
        }
        task.resume()
    }
}
