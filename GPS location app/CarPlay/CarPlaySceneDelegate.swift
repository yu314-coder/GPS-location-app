//
//  CarPlaySceneDelegate.swift
//  GPS location app
//
//  CarPlay navigation integration to display the live workout route.
//

import UIKit
import CarPlay
import MapKit

@available(iOS 14.0, *)
class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, MKMapViewDelegate, CPMapTemplateDelegate {
    var interfaceController: CPInterfaceController?
    private var carWindow: CPWindow?
    private var mapTemplate: CPMapTemplate?
    private var mapView: MKMapView?
    private var routeLine: MKPolyline?
    private var routeCoordinates: [CLLocationCoordinate2D] = []
    private var notificationObservers: [NSObjectProtocol] = []

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        self.interfaceController = interfaceController
        self.carWindow = window
        print("🚗 CarPlay connected (navigation)")

        configureMapWindow(window)
        configureMapTemplate()
        startRouteMonitoring()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        print("🚗 CarPlay disconnected")
        stopRouteMonitoring()
        mapView = nil
        mapTemplate = nil
        routeLine = nil
        routeCoordinates.removeAll()
        carWindow = nil
        self.interfaceController = nil
    }

    // MARK: - Map Setup

    private func configureMapWindow(_ window: CPWindow) {
        let mapView = MKMapView(frame: window.bounds)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.delegate = self
        mapView.showsUserLocation = true
        mapView.userTrackingMode = .follow
        mapView.pointOfInterestFilter = .excludingAll
        mapView.mapType = .standard

        let mapViewController = UIViewController()
        mapViewController.view = mapView
        window.rootViewController = mapViewController
        window.isHidden = false

        self.mapView = mapView
    }

    private func configureMapTemplate() {
        let mapTemplate = CPMapTemplate()
        mapTemplate.mapDelegate = self
        mapTemplate.automaticallyHidesNavigationBar = false

        let recenterButton = CPMapButton { [weak self] _ in
            self?.recenterMap()
        }
        recenterButton.image = UIImage(systemName: "location.fill")

        let stopButton = CPMapButton { _ in
            NotificationCenter.default.post(
                name: NSNotification.Name("CarPlayStopWorkout"),
                object: nil
            )
        }
        stopButton.image = UIImage(systemName: "stop.circle.fill")

        mapTemplate.mapButtons = [recenterButton, stopButton]

        interfaceController?.setRootTemplate(mapTemplate, animated: true, completion: nil)
        self.mapTemplate = mapTemplate
    }

    // MARK: - Route Monitoring

    private func startRouteMonitoring() {
        stopRouteMonitoring()

        let startObserver = NotificationCenter.default.addObserver(
            forName: .workoutDidStart,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resetRoute()
        }

        let stopObserver = NotificationCenter.default.addObserver(
            forName: .workoutDidStop,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recenterMap()
        }

        let locationObserver = NotificationCenter.default.addObserver(
            forName: .workoutLocationUpdated,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let location = notification.userInfo?["location"] as? CLLocation else { return }
            self?.appendLocation(location)
        }

        notificationObservers = [startObserver, stopObserver, locationObserver]
    }

    private func stopRouteMonitoring() {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }

    private func appendLocation(_ location: CLLocation) {
        guard CLLocationCoordinate2DIsValid(location.coordinate) else { return }
        routeCoordinates.append(location.coordinate)
        updateRouteOverlay()
        updateVisibleRegion(for: location.coordinate)
    }

    private func resetRoute() {
        routeCoordinates.removeAll()
        if let routeLine {
            mapView?.removeOverlay(routeLine)
        }
        routeLine = nil
    }

    private func updateRouteOverlay() {
        guard routeCoordinates.count > 1 else { return }
        if let routeLine {
            mapView?.removeOverlay(routeLine)
        }
        let newLine = MKPolyline(coordinates: routeCoordinates, count: routeCoordinates.count)
        routeLine = newLine
        mapView?.addOverlay(newLine)
    }

    private func updateVisibleRegion(for coordinate: CLLocationCoordinate2D) {
        guard let mapView else { return }
        if routeCoordinates.count < 3 {
            let region = MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 800,
                longitudinalMeters: 800
            )
            mapView.setRegion(region, animated: true)
            return
        }

        if routeCoordinates.count % 5 == 0, let routeLine {
            mapView.setVisibleMapRect(
                routeLine.boundingMapRect,
                edgePadding: UIEdgeInsets(top: 60, left: 60, bottom: 60, right: 60),
                animated: true
            )
        }
    }

    private func recenterMap() {
        guard let mapView else { return }
        if let routeLine {
            mapView.setVisibleMapRect(
                routeLine.boundingMapRect,
                edgePadding: UIEdgeInsets(top: 60, left: 60, bottom: 60, right: 60),
                animated: true
            )
        } else if let userLocation = mapView.userLocation.location {
            let region = MKCoordinateRegion(
                center: userLocation.coordinate,
                latitudinalMeters: 1000,
                longitudinalMeters: 1000
            )
            mapView.setRegion(region, animated: true)
        }
    }

    // MARK: - MKMapViewDelegate

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let polyline = overlay as? MKPolyline {
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = .systemBlue
            renderer.lineWidth = 6
            renderer.lineJoin = .round
            renderer.lineCap = .round
            return renderer
        }
        return MKOverlayRenderer(overlay: overlay)
    }
}
