//
//  GPS_location_appApp.swift
//  GPS location app Watch App
//
//  GPS location app
//

import SwiftUI

@main
struct GPS_location_app_Watch_AppApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        // Initialize logger
        AppLogger.shared.log("Watch App launched")
    }

    func applicationWillResignActive() {
        AppLogger.shared.log("Watch App will resign active")
    }
}
