import Foundation
import CoreLocation

/// Local OSM road-network cache for OFFLINE map matching.
///
/// Road geometry is fetched ONCE per ~5.5km tile from the Overpass API
/// (way["highway"] … out geom) and cached on disk. After that, road alignment
/// runs fully offline against the cached tiles — no key, no server.
/// Data © OpenStreetMap contributors (ODbL).
final class RoadNetworkStore {
    static let shared = RoadNetworkStore()
    private init() {}

    // MARK: - Types

    struct RoadSegment {
        let ax: Double, ay: Double   // start lon/lat
        let bx: Double, by: Double   // end lon/lat
        let wayID: Int64
    }

    struct Candidate {
        let segmentIndex: Int
        let wayID: Int64
        let location: CLLocationCoordinate2D  // projection onto the segment
        let distanceMeters: Double
    }

    /// In-memory spatial index over road segments for one align run.
    final class RoadIndex {
        fileprivate var segments: [RoadSegment] = []
        fileprivate var grid: [Int64: [Int32]] = [:]   // cell key -> segment indices
        fileprivate let cellSize = 0.0009              // ~100m in latitude degrees

        var segmentCount: Int { segments.count }

        fileprivate func cellKey(_ cx: Int32, _ cy: Int32) -> Int64 {
            (Int64(cx) << 32) | Int64(UInt32(bitPattern: cy))
        }

        fileprivate func insert(_ seg: RoadSegment, index: Int32) {
            // Cover every cell the segment's bbox touches (segments are short).
            let minX = Int32(floor(min(seg.ax, seg.bx) / cellSize))
            let maxX = Int32(floor(max(seg.ax, seg.bx) / cellSize))
            let minY = Int32(floor(min(seg.ay, seg.by) / cellSize))
            let maxY = Int32(floor(max(seg.ay, seg.by) / cellSize))
            var cx = minX
            while cx <= maxX {
                var cy = minY
                while cy <= maxY {
                    grid[cellKey(cx, cy), default: []].append(index)
                    cy += 1
                }
                cx += 1
            }
        }

        /// Nearest road candidates within maxDistance of a coordinate.
        func candidates(near coord: CLLocationCoordinate2D, maxDistance: Double, maxCount: Int) -> [Candidate] {
            let mPerDegLat = 111_320.0
            let mPerDegLon = mPerDegLat * cos(coord.latitude * .pi / 180)
            let reach = Int32((maxDistance / (cellSize * mPerDegLat)).rounded(.up))
            let cx0 = Int32(floor(coord.longitude / cellSize))
            let cy0 = Int32(floor(coord.latitude / cellSize))

            var seen = Set<Int32>()
            var found: [Candidate] = []
            var cx = cx0 - reach
            while cx <= cx0 + reach {
                var cy = cy0 - reach
                while cy <= cy0 + reach {
                    if let list = grid[cellKey(cx, cy)] {
                        for idx in list where !seen.contains(idx) {
                            seen.insert(idx)
                            let seg = segments[Int(idx)]
                            // Project point onto segment (planar approx).
                            let px = (coord.longitude - seg.ax) * mPerDegLon
                            let py = (coord.latitude - seg.ay) * mPerDegLat
                            let sx = (seg.bx - seg.ax) * mPerDegLon
                            let sy = (seg.by - seg.ay) * mPerDegLat
                            let lenSq = sx * sx + sy * sy
                            let t = lenSq > 0 ? max(0, min(1, (px * sx + py * sy) / lenSq)) : 0
                            let qx = t * sx, qy = t * sy
                            let dx = px - qx, dy = py - qy
                            let dist = (dx * dx + dy * dy).squareRoot()
                            if dist <= maxDistance {
                                let lon = seg.ax + (qx / mPerDegLon)
                                let lat = seg.ay + (qy / mPerDegLat)
                                found.append(Candidate(
                                    segmentIndex: Int(idx),
                                    wayID: seg.wayID,
                                    location: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                                    distanceMeters: dist
                                ))
                            }
                        }
                    }
                    cy += 1
                }
                cx += 1
            }
            found.sort { $0.distanceMeters < $1.distanceMeters }
            if found.count > maxCount { found.removeSubrange(maxCount...) }
            return found
        }
    }

    // MARK: - Tile cache

    private let tileSize = 0.05                    // degrees (~5.5km)
    private let maxTilesPerRun = 12                // Overpass courtesy cap
    private let overpassEndpoint = "https://overpass-api.de/api/interpreter"

    private var tilesDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("osm_tiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func tileURL(x: Int, y: Int) -> URL {
        tilesDirectory.appendingPathComponent("tile_\(x)_\(y).json")
    }

    private struct TilePayload: Codable {
        // Each way: flat [lat0, lon0, lat1, lon1, ...]
        let ids: [Int64]
        let ways: [[Double]]
    }

    private func tileList(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) -> [(x: Int, y: Int)] {
        let x0 = Int(floor(minLon / tileSize)), x1 = Int(floor(maxLon / tileSize))
        let y0 = Int(floor(minLat / tileSize)), y1 = Int(floor(maxLat / tileSize))
        var tiles: [(Int, Int)] = []
        for x in x0...x1 { for y in y0...y1 { tiles.append((x, y)) } }
        return tiles
    }

    /// True when every tile covering the bbox is already cached on disk.
    func hasCoverage(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) -> Bool {
        tileList(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)
            .allSatisfy { FileManager.default.fileExists(atPath: tileURL(x: $0.x, y: $0.y).path) }
    }

    /// Build the road index for a bbox. Missing tiles are downloaded from
    /// Overpass when allowDownload is true (the one-time "downloading part");
    /// otherwise only cached tiles are used. Returns nil when nothing is cached.
    func index(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double,
               allowDownload: Bool,
               progress: ((String) -> Void)? = nil) async -> RoadIndex? {
        var tiles = tileList(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)
        if tiles.count > maxTilesPerRun {
            print("🗺️ Road area too large (\(tiles.count) tiles) — clamping to \(maxTilesPerRun)")
            tiles = Array(tiles.prefix(maxTilesPerRun))
        }

        var payloads: [TilePayload] = []
        var downloaded = 0
        for (i, tile) in tiles.enumerated() {
            let url = tileURL(x: tile.x, y: tile.y)
            if let data = try? Data(contentsOf: url),
               let payload = try? JSONDecoder().decode(TilePayload.self, from: data) {
                payloads.append(payload)
                continue
            }
            guard allowDownload else { continue }
            progress?("Downloading road data \(i + 1)/\(tiles.count)…")
            if downloaded > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 rps courtesy
            }
            if let payload = await fetchTile(x: tile.x, y: tile.y) {
                payloads.append(payload)
                downloaded += 1
                if let data = try? JSONEncoder().encode(payload) {
                    try? data.write(to: url, options: .atomic)
                }
            }
        }

        guard !payloads.isEmpty else { return nil }

        let index = RoadIndex()
        for payload in payloads {
            for (w, flat) in payload.ways.enumerated() {
                let wayID = payload.ids.indices.contains(w) ? payload.ids[w] : 0
                var i = 0
                while i + 3 < flat.count {
                    let seg = RoadSegment(ax: flat[i + 1], ay: flat[i],
                                          bx: flat[i + 3], by: flat[i + 2],
                                          wayID: wayID)
                    index.segments.append(seg)
                    index.insert(seg, index: Int32(index.segments.count - 1))
                    i += 2
                }
            }
        }
        print("🗺️ Road index ready: \(index.segmentCount) segments from \(payloads.count) tiles (downloaded \(downloaded))")
        return index.segmentCount > 0 ? index : nil
    }

    private func fetchTile(x: Int, y: Int) async -> TilePayload? {
        let s = Double(y) * tileSize, w = Double(x) * tileSize
        let n = s + tileSize, e = w + tileSize
        let highways = "motorway|trunk|primary|secondary|tertiary|unclassified|residential|service|living_street|track|cycleway|footway|path|pedestrian|steps|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link"
        let query = "[out:json][timeout:25];way[\"highway\"~\"^(\(highways))$\"](\(s),\(w),\(n),\(e));out geom;"

        var request = URLRequest(url: URL(string: overpassEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query)".data(using: .utf8)
        request.timeoutInterval = 40

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let elements = json["elements"] as? [[String: Any]] else {
                print("🗺️ Overpass tile (\(x),\(y)) failed")
                return nil
            }
            var ids: [Int64] = []
            var ways: [[Double]] = []
            for element in elements where (element["type"] as? String) == "way" {
                guard let geometry = element["geometry"] as? [[String: Any]], geometry.count > 1 else { continue }
                var flat: [Double] = []
                flat.reserveCapacity(geometry.count * 2)
                for node in geometry {
                    if let lat = node["lat"] as? Double, let lon = node["lon"] as? Double {
                        flat.append(lat); flat.append(lon)
                    }
                }
                if flat.count >= 4 {
                    ids.append((element["id"] as? Int64) ?? Int64(element["id"] as? Int ?? 0))
                    ways.append(flat)
                }
            }
            print("🗺️ Overpass tile (\(x),\(y)): \(ways.count) ways")
            return TilePayload(ids: ids, ways: ways)
        } catch {
            print("🗺️ Overpass tile (\(x),\(y)) error: \(error.localizedDescription)")
            return nil
        }
    }
}
