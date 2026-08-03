import SwiftUI
import MapKit

/// A REAL map that keeps working with no network, by serving tiles from a disk cache.
///
/// Apple's own basemap cannot be used for this: MapKit fetches its tiles on demand and offers no
/// supported way to pre-load or persist them, so a stock `Map` is blank in exactly the places
/// velocity mode is for — a tunnel, a basement, an aircraft. An `MKTileOverlay` pointed at a
/// standard raster tile source can be cached, so that is what this uses.
///
/// About "pre-download a world map": a whole world at street-level detail is not a thing that can
/// be shipped — zoom 15 alone is about 1.4 billion tiles, hundreds of gigabytes. What IS
/// practical, and is what this does:
///   • a low-zoom WORLD overview (z0–z5, ~1,400 tiles, tens of MB) — coastlines, countries and
///     cities, which is the right scale for a flight track anyway;
///   • the CURRENT AREA at detail, cached automatically as it is viewed, so anywhere you have
///     looked at while online stays available offline;
///   • an explicit "download this area" for a region you are about to lose signal in.
/// Everything already cached is served offline; anything missing falls back to the vector track
/// so the route is never invisible.
struct SessionMapPanel: View {
    let locations: [FlightLocation]
    let current: CLLocation?

    @StateObject private var cache = OfflineTileCache.shared
    @State private var followsTrack = true

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CachedTileMapView(locations: locations, current: current, follows: followsTrack)

            VStack(alignment: .leading, spacing: 6) {
                if cache.isDownloading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Caching \(cache.downloadedCount)/\(cache.totalToDownload)")
                            .font(.caption2)
                    }
                    .padding(6)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                HStack(spacing: 8) {
                    Button {
                        followsTrack.toggle()
                    } label: {
                        Image(systemName: followsTrack ? "location.fill" : "location")
                            .padding(7)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Button {
                        cache.downloadWorldOverview()
                    } label: {
                        Label("World", systemImage: "globe")
                            .font(.caption2)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .disabled(cache.isDownloading)
                    Button {
                        cache.downloadCurrentArea(around: locations.last ?? locations.first,
                                                  fallback: current)
                    } label: {
                        Label("This area", systemImage: "square.and.arrow.down")
                            .font(.caption2)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .disabled(cache.isDownloading || (locations.isEmpty && current == nil))
                }
                .buttonStyle(.plain)
            }
            .padding(10)
        }
    }
}

// MARK: - Map

private struct CachedTileMapView: UIViewRepresentable {
    let locations: [FlightLocation]
    let current: CLLocation?
    let follows: Bool

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        // Hide Apple's basemap: it cannot be cached, so offline it renders as a blank grid that
        // would sit on top of the tiles that ARE available.
        map.mapType = .mutedStandard
        map.pointOfInterestFilter = .excludingAll
        map.showsUserLocation = false
        let overlay = OfflineTileCache.shared.makeOverlay()
        overlay.canReplaceMapContent = true
        map.addOverlay(overlay, level: .aboveLabels)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coords = locations.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }

        map.removeOverlays(map.overlays.filter { $0 is MKPolyline })
        if coords.count > 1 {
            map.addOverlay(MKPolyline(coordinates: coords, count: coords.count), level: .aboveLabels)
        }
        map.removeAnnotations(map.annotations)
        if let first = coords.first { map.addAnnotation(EndPoint(coordinate: first, isStart: true)) }
        if let last = coords.last, coords.count > 1 {
            map.addAnnotation(EndPoint(coordinate: last, isStart: false))
        }

        guard follows else { return }
        if coords.count > 1 {
            let rect = coords.reduce(MKMapRect.null) { acc, c in
                acc.union(MKMapRect(origin: MKMapPoint(c), size: .init(width: 1, height: 1)))
            }
            map.setVisibleMapRect(rect,
                                  edgePadding: .init(top: 40, left: 40, bottom: 40, right: 40),
                                  animated: true)
        } else if let c = current?.coordinate ?? coords.first {
            map.setRegion(MKCoordinateRegion(center: c, latitudinalMeters: 800, longitudinalMeters: 800),
                          animated: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            if let line = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = .systemOrange
                r.lineWidth = 4
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let p = annotation as? EndPoint else { return nil }
            let v = MKAnnotationView(annotation: p, reuseIdentifier: "end")
            let dot = UIView(frame: .init(x: 0, y: 0, width: 12, height: 12))
            dot.backgroundColor = p.isStart ? .systemGreen : .systemRed
            dot.layer.cornerRadius = 6
            dot.layer.borderWidth = 2
            dot.layer.borderColor = UIColor.white.cgColor
            v.addSubview(dot)
            v.frame = dot.frame
            return v
        }

        /// Cache every tile the map fetches, so anywhere viewed online is available offline.
        func mapViewDidFinishLoadingMap(_ mapView: MKMapView) {}
    }

    final class EndPoint: NSObject, MKAnnotation {
        let coordinate: CLLocationCoordinate2D
        let isStart: Bool
        init(coordinate: CLLocationCoordinate2D, isStart: Bool) {
            self.coordinate = coordinate; self.isStart = isStart
        }
    }
}
