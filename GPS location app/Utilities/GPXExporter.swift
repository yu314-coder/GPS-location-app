import Foundation
import UIKit

class GPXExporter {
    static func exportToGPX(flight: Flight) -> URL? {
        guard let metrics = flight.metrics else {
            print("❌ No metrics available for GPX export")
            return nil
        }

        let gpxContent = generateGPXContent(flight: flight, metrics: metrics)

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

    private static func generateGPXContent(flight: Flight, metrics: FlightMetrics) -> String {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Flight GPS Tracker" xmlns="http://www.topografix.com/GPX/1/1">
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

            // Add extensions for additional data
            gpx += """
                    <extensions>
                      <speed>\(location.speed)</speed>
                      <course>\(location.course)</course>
                      <accuracy>\(location.horizontalAccuracy)</accuracy>
                    </extensions>

            """

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
