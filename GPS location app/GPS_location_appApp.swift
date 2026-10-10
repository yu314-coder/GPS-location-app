//
//  GPS_location_appApp.swift
//  GPS location app
//
//  GPS location app
//

import SwiftUI
import UserNotifications

@main
struct GPS_location_appApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Set notification delegate for workout notifications
        UNUserNotificationCenter.current().delegate = WorkoutNotificationManager.shared
        _ = WatchConnectivityManager.shared  // Ensure watch connectivity is active for background watch messages
        WorkoutSession.shared.handleAppLaunch(launchOptions: launchOptions)
        TempFileSweeper.sweep()   // half-written saves and old share copies left in tmp/
        ExitDiagnostics.shared.start()   // the system's account of how the app last ended

        // The road-alignment API key has been removed from the app. Clear anything a previous
        // build stored: without the settings field there is no way to see or change it, so a
        // leftover value would keep third-party map matching switched on invisibly — and it is
        // a credential, which should not outlive the screen that collected it.
        if UserDefaults.standard.object(forKey: "mapMatchingAPIKey") != nil {
            UserDefaults.standard.removeObject(forKey: "mapMatchingAPIKey")
            print("🧹 Removed stored road-alignment API key")
        }

        print("✅ App launched successfully")
        print("🔔 Notification center delegate configured")

        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        print("⚠️ App will terminate")
        WorkoutSession.shared.handleAppWillTerminate()
    }
}

#if !DEBUG
/// Release builds write nothing to the console (build 120). Hundreds of print calls run every second or every
/// fix during a workout - some every second for the whole of a GPS outage, which on a flight is hours - and no
/// one reads a release build's console; the logs that matter are the files and os_log. Debug builds still print.
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {}
#endif
