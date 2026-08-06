import SwiftUI
import CoreLocation

/// In-session debugging, usable WHILE MOVING and with no network at all.
///
/// Two modes:
///  • Track — the recorded route drawn as vectors on a plain grid. Deliberately NOT MapKit:
///    map tiles are fetched over the network, so a tiled map is blank in exactly the places
///    this mode matters (a tunnel, a basement, an aircraft). Drawing the polyline directly
///    needs nothing but the points already in memory.
///  • Live — the numbers behind the current reading: which source is driving it, the vibration
///    feature, the fitted curve, how much of the speed range GPS has actually labelled, and
///    whether the estimate is extrapolating beyond that.
struct SessionDebugView: View {
    let locations: [FlightLocation]
    @ObservedObject var diagnostics: SessionDiagnosticsRecorder
    let statusLine: String

    enum Mode: String, CaseIterable { case track = "Track", live = "Live" }
    @State private var mode: Mode = .track

    var body: some View {
        VStack(spacing: 12) {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            switch mode {
            case .track: trackMode
            case .live:  liveMode
            }
        }
        .padding(.vertical)
    }

    // MARK: - Track

    private var trackMode: some View {
        VStack(spacing: 8) {
            OfflineTrackPlot(locations: locations)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

            HStack {
                Label("\(locations.count) pts", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                Spacer()
                Text(spanText).foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal)

            Text("Drawn from recorded points only — no map tiles, so it works with no signal.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    private var spanText: String {
        guard locations.count > 1,
              let minLat = locations.map(\.latitude).min(),
              let maxLat = locations.map(\.latitude).max(),
              let minLon = locations.map(\.longitude).min(),
              let maxLon = locations.map(\.longitude).max() else { return "—" }
        let h = CLLocation(latitude: minLat, longitude: minLon)
            .distance(from: CLLocation(latitude: minLat, longitude: maxLon))
        let v = CLLocation(latitude: minLat, longitude: minLon)
            .distance(from: CLLocation(latitude: maxLat, longitude: minLon))
        return String(format: "%.0f × %.0f m", h, v)
    }

    // MARK: - Live

    private var liveMode: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(statusLine)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                if let r = diagnostics.latest {
                    group("Reading") {
                        row("source", r.source)
                        row("activity", r.activity)
                        row("speed", String(format: "%.1f km/h", r.reportedSpeed * 3.6))
                        row("distance this tick", String(format: "%.2f m", r.distanceAdded))
                    }
                    group("Vibration model") {
                        row("feature u", String(format: "%.4f", r.feature))
                        row("fit", fitText(r))
                        row("calibrated u", rangeText(r.minCalU, r.maxCalU, "%.3f"))
                        row("calibrated speed",
                            rangeText(r.minCalSpeed * 3.6, r.maxCalSpeed * 3.6, "%.0f") + " km/h")
                        row("samples", String(format: "%.0f", r.calSamples))
                        row("extrapolating", r.extrapolating ? "YES — above calibrated range" : "no")
                    }
                    group("Context") {
                        row("handling rotation", String(format: "%.3f rad/s", r.handlingRotation))
                        row("heading", String(format: "%.0f°", r.heading))
                        row("compass", r.compass.map { String(format: "%.0f°", $0) } ?? "—")
                        row("offset", r.offset.map { String(format: "%+.0f°", $0) } ?? "not learned")
                        row("GPS speed", r.gpsSpeed.map { String(format: "%.1f km/h", $0 * 3.6) } ?? "—")
                        row("GPS accuracy", r.gpsAccuracy.map { String(format: "±%.0f m", $0) } ?? "—")
                    }
                } else {
                    Text("No ticks recorded yet.")
                        .foregroundStyle(.secondary)
                }

                Button {
                    diagnostics.exportCSV()
                } label: {
                    Label("Export \(diagnostics.rowCount) rows + \(diagnostics.rawCount) raw samples", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(diagnostics.isEmpty)
                .padding(.top, 4)
            }
            .padding(.horizontal)
        }
    }

    private func fitText(_ r: SessionDiagnosticsRecorder.Row) -> String {
        guard r.p0.isFinite else { return "not calibrated" }
        return String(format: "%.2f %+.2fu %+.3fu²", r.p0, r.p1, r.p2)
    }

    private func rangeText(_ a: Double, _ b: Double, _ f: String) -> String {
        guard a.isFinite, b.isFinite else { return "—" }
        return String(format: "\(f) … \(f)", a, b)
    }

    @ViewBuilder
    private func group(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).bold().foregroundStyle(.secondary)
            content()
        }
        .padding(.top, 6)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(v).multilineTextAlignment(.trailing)
        }
        .font(.system(.footnote, design: .monospaced))
    }
}

/// The recorded track as a scaled polyline. Equirectangular projection about the track's own
/// centre — over a single workout the distortion is far below the width of the drawn line, and
/// it keeps the whole thing dependency-free and instant.
private struct OfflineTrackPlot: View {
    let locations: [FlightLocation]

    var body: some View {
        GeometryReader { geo in
            let pts = projected(in: geo.size)
            ZStack {
                Path { p in
                    let step = max(geo.size.width, geo.size.height) / 8
                    var x: CGFloat = 0
                    while x <= geo.size.width { p.move(to: .init(x: x, y: 0)); p.addLine(to: .init(x: x, y: geo.size.height)); x += step }
                    var y: CGFloat = 0
                    while y <= geo.size.height { p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: geo.size.width, y: y)); y += step }
                }
                .stroke(Color.gray.opacity(0.18), lineWidth: 0.5)

                if pts.count > 1 {
                    Path { p in
                        p.move(to: pts[0])
                        for pt in pts.dropFirst() { p.addLine(to: pt) }
                    }
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
                if let first = pts.first {
                    Circle().fill(.green).frame(width: 9, height: 9).position(first)
                }
                if let last = pts.last, pts.count > 1 {
                    Circle().fill(.red).frame(width: 9, height: 9).position(last)
                }
                if pts.count < 2 {
                    Text("waiting for points…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .position(x: geo.size.width/2, y: geo.size.height/2)
                }
            }
        }
    }

    private func projected(in size: CGSize) -> [CGPoint] {
        guard locations.count > 1 else { return [] }
        let lats = locations.map(\.latitude), lons = locations.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return [] }
        let midLat = (minLat + maxLat) / 2
        let lonScale = cos(midLat * .pi / 180)          // metres per degree shrink with latitude
        let w = max((maxLon - minLon) * lonScale, 1e-9)
        let h = max(maxLat - minLat, 1e-9)
        let inset: CGFloat = 16
        // One scale for both axes, so the shape is never stretched.
        let scale = min((size.width - inset*2) / w, (size.height - inset*2) / h)
        let offsetX = (size.width - w * scale) / 2
        let offsetY = (size.height - h * scale) / 2
        return locations.map { loc in
            CGPoint(x: offsetX + (loc.longitude - minLon) * lonScale * scale,
                    // screen y grows downward, latitude grows north — flip it
                    y: size.height - offsetY - (loc.latitude - minLat) * scale)
        }
    }
}
