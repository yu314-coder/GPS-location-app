import Foundation
import CoreLocation
import MapKit
import HealthKit

/// Road map-matching via Valhalla Meili (HMM map matching — Newson & Krumm 2009).
///
/// Sends a noisy GPS trace to a Valhalla `trace_route` endpoint and gets back a
/// route snapped to the OSM road network. This is true map matching (Hidden
/// Markov Model + Viterbi), far more accurate than stitching MKDirections
/// segments together.
///
/// Hosted via Stadia Maps' free tier (needs an API key — get one at
/// https://client.stadiamaps.com). The key is read from UserDefaults so it can be
/// set in Settings. Results render on any map (OSM/ODbL), so MapKit is fine.
enum MapMatchingService {

    enum Costing: String {
        case pedestrian
        case bicycle
        case auto
    }

    static var apiKey: String {
        UserDefaults.standard.string(forKey: "mapMatchingAPIKey")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static var isConfigured: Bool { !apiKey.isEmpty }

    private static var endpoint: String { "https://api.stadiamaps.com/trace_route/v1" }

    /// Map a workout activity type to the closest Valhalla costing model.
    static func costing(for activityType: HKWorkoutActivityType?) -> Costing {
        switch activityType {
        case .cycling: return .bicycle
        case .running, .walking, .hiking: return .pedestrian
        default: return .auto
        }
    }

    /// Match a GPS trace to roads. Returns the snapped polyline, or nil on failure
    /// (caller should fall back to the raw trace).
    static func matchRoute(coordinates: [CLLocationCoordinate2D], costing: Costing) async -> [CLLocationCoordinate2D]? {
        guard coordinates.count > 1, isConfigured else { return nil }

        // Valhalla handles long traces, but keep requests bounded. Our cached
        // routes are already ≤ ~400 points, so a single request is fine.
        let shape = coordinates.map { ["lat": $0.latitude, "lon": $0.longitude] }
        let body: [String: Any] = [
            "shape": shape,
            "costing": costing.rawValue,
            "shape_match": "map_snap",
            "trace_options": ["search_radius": 50, "gps_accuracy": 10],
            "directions_options": ["units": "kilometers"]
        ]

        guard let url = URL(string: "\(endpoint)?api_key=\(apiKey)"),
              let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let trip = json["trip"] as? [String: Any],
                  let legs = trip["legs"] as? [[String: Any]] else {
                return nil
            }

            var result: [CLLocationCoordinate2D] = []
            for leg in legs {
                guard let encoded = leg["shape"] as? String else { continue }
                let decoded = decodePolyline6(encoded)
                if result.isEmpty {
                    result.append(contentsOf: decoded)
                } else {
                    result.append(contentsOf: decoded.dropFirst())
                }
            }
            return result.count > 1 ? result : nil
        } catch {
            return nil
        }
    }

    /// Decode a Valhalla-encoded polyline (precision 6 / 1e6).
    static func decodePolyline6(_ encoded: String) -> [CLLocationCoordinate2D] {
        let chars = Array(encoded.unicodeScalars)
        var coords: [CLLocationCoordinate2D] = []
        var i = 0
        var lat = 0
        var lon = 0

        func decodeValue() -> Int {
            var result = 0
            var shift = 0
            var byte = 0
            repeat {
                guard i < chars.count else { break }
                byte = Int(chars[i].value) - 63
                result |= (byte & 0x1f) << shift
                shift += 5
                i += 1
            } while byte >= 0x20
            return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
        }

        while i < chars.count {
            lat += decodeValue()
            lon += decodeValue()
            coords.append(CLLocationCoordinate2D(latitude: Double(lat) / 1e6, longitude: Double(lon) / 1e6))
        }
        return coords
    }
}
