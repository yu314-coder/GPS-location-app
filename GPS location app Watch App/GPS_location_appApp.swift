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

#if !DEBUG
/// Release builds write nothing to the console (build 120). Hundreds of print calls run every second or every
/// fix during a workout - some every second for the whole of a GPS outage, which on a flight is hours - and no
/// one reads a release build's console; the logs that matter are the files and os_log. Debug builds still print.
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {}
#endif
