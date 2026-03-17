//
//  AnalysisView.swift
//  GPS location app
//
//  Created by Claude on 2/26/26.
//

import SwiftUI

struct AnalysisView: View {
    @StateObject private var analytics = WorkoutAnalyticsManager.shared
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var isIPad: Bool { sizeClass == .regular }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: isIPad ? 24 : 20) {
                    // Month & Activity picker
                    MonthActivityPickerSection(analytics: analytics)

                    // Summary stat cards
                    SummaryStatsSection(analytics: analytics)

                    if analytics.isLoading {
                        ProgressView("Loading data...")
                            .frame(maxWidth: .infinity, minHeight: isIPad ? 300 : 200)
                    } else if isIPad {
                        // iPad: charts side by side
                        HStack(alignment: .top, spacing: 16) {
                            DailyDistanceChartView(analytics: analytics)
                            YearlyDistanceChartView(analytics: analytics)
                        }
                    } else {
                        // iPhone: charts stacked
                        DailyDistanceChartView(analytics: analytics)
                        YearlyDistanceChartView(analytics: analytics)
                    }
                }
                .padding(isIPad ? 24 : 16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Analysis")
            .onAppear {
                analytics.fetchData()
            }
            .onChange(of: analytics.selectedMonth) {
                analytics.fetchData()
            }
            .onChange(of: analytics.selectedYear) {
                analytics.fetchData()
            }
            .onChange(of: analytics.activityFilter) {
                analytics.fetchData()
            }
        }
        .navigationViewStyle(.stack)
    }
}

#Preview {
    AnalysisView()
}
