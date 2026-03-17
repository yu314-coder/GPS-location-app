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

        print("✅ App launched successfully")
        print("🔔 Notification center delegate configured")

        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        print("⚠️ App will terminate")
        WorkoutSession.shared.handleAppWillTerminate()
    }
}
