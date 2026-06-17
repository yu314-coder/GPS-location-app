//
//  WorkoutWidgetBundle.swift
//  WorkoutWidget
//
//  GPS location app
//

#if canImport(ActivityKit) && !os(watchOS)
import WidgetKit
import SwiftUI

@main
struct WorkoutWidgetBundle: WidgetBundle {
    var body: some Widget {
        WorkoutWidget()
        WorkoutWidgetLiveActivity()
        DownloadWidgetLiveActivity()
    }
}
#endif
