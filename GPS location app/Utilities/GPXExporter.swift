import Foundation
import UIKit

class GPXExporter {
    static func exportToGPX(flight: Flight) -> URL? {
        // NO metrics requirement. This used to bail out whenever flight.metrics was nil, which
        // silently produced nothing at all — the button appeared to do absolutely nothing. The
        // metrics were never even referenced when building the file: a GPX track is made of the
        // recorded POINTS, and distance/speed summaries are derived data that belong nowhere in
        // it. A workout with a route but no stored summary is exactly the case worth exporting.
        guard !flight.locations.isEmpty else {
            print("❌ No locations to export")
            return nil
        }

        let gpxContent = generateGPXContent(flight: flight, metrics: flight.metrics)

        // Create temp file
        let tempDir = FileManager.default.temporaryDirectory
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let dateString = dateFormatter.string(from: flight.startDate)
        let fileName = "workout_\(dateString).gpx"
        let fileURL = tempDir.appendingPathComponent(fileName)

        do {
            try gpxContent.write(to: fileURL, atomically: true, encoding: .utf8)
            print("✅ GPX file created: \(fileURL.path)")
            return fileURL
        } catch {
            print("❌ Failed to write GPX file: \(error.localizedDescription)")
            return nil
        }
    }

    private static func generateGPXContent(flight: Flight, metrics: FlightMetrics?) -> String {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="GPS Workout Tracker" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata>
            <name>Workout \(dateFormatter.string(from: flight.startDate))</name>
            <time>\(dateFormatter.string(from: flight.startDate))</time>
        """

        if let origin = flight.origin, let destination = flight.destination {
            gpx += "\n    <desc>\(origin) → \(destination)</desc>"
        }

        gpx += """

          </metadata>
          <trk>
            <name>Workout Route</name>
            <type>Cycling</type>
            <trkseg>

        """

        // Add all location points
        for location in flight.locations {
            gpx += """
                  <trkpt lat="\(location.latitude)" lon="\(location.longitude)">
                    <ele>\(location.altitude)</ele>
                    <time>\(dateFormatter.string(from: location.timestamp))</time>

            """

            // Add extensions for additional data. Every motion field the sensors captured is
            // emitted so a dead-reckoned flight can be fully analysed off-device.
            func ext(_ name: String, _ value: Double?) -> String {
                guard let value else { return "" }
                return "                      <\(name)>\(value)</\(name)>\n"
            }
            gpx += """
                    <extensions>
                      <speed>\(location.speed)</speed>
                      <course>\(location.course)</course>
                      <accuracy>\(location.horizontalAccuracy)</accuracy>
                      <estimated>\(location.isEstimated)</estimated>

            """
            gpx += ext("acceleration", location.motionAcceleration)
            gpx += ext("forwardAcceleration", location.forwardAcceleration)
            gpx += ext("lateralAcceleration", location.lateralAcceleration)
            gpx += ext("deviceHeading", location.deviceHeading)
            gpx += ext("compassHeading", location.compassHeading)
            gpx += ext("movementDirection", location.movementDirection)
            gpx += ext("pitch", location.pitch)
            gpx += ext("roll", location.roll)
            gpx += ext("yaw", location.yaw)
            gpx += ext("rotationRate", location.rotationRate)
            gpx += ext("verticalSpeed", location.verticalSpeed)
            gpx += ext("relativeAltitude", location.relativeAltitude)
            gpx += ext("pressure", location.pressure)
            gpx += "                    </extensions>\n\n"

            gpx += "      </trkpt>\n"
        }

        gpx += """
                </trkseg>
              </trk>
            </gpx>
            """

        return gpx
    }

    static func shareGPX(from viewController: UIViewController, flight: Flight) {
        guard let fileURL = exportToGPX(flight: flight) else {
            print("❌ Failed to export GPX")
            return
        }

        let activityVC = UIActivityViewController(
            activityItems: [fileURL],
            applicationActivities: nil
        )

        // For iPad - set source view to prevent crash
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = viewController.view
            popover.sourceRect = CGRect(x: viewController.view.bounds.midX,
                                       y: viewController.view.bounds.midY,
                                       width: 0,
                                       height: 0)
            popover.permittedArrowDirections = []
        }

        viewController.present(activityVC, animated: true)
    }
}
