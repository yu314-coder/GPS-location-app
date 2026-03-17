//
//  MonthSelectionIntent.swift
//  WorkoutWidget
//
//  Created by Claude on 2/26/26.
//

import AppIntents
import WidgetKit

enum MonthOption: Int, CaseIterable, AppEnum {
    case january = 1
    case february = 2
    case march = 3
    case april = 4
    case may = 5
    case june = 6
    case july = 7
    case august = 8
    case september = 9
    case october = 10
    case november = 11
    case december = 12

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Month")

    static var caseDisplayRepresentations: [MonthOption: DisplayRepresentation] {
        [
            .january: "January",
            .february: "February",
            .march: "March",
            .april: "April",
            .may: "May",
            .june: "June",
            .july: "July",
            .august: "August",
            .september: "September",
            .october: "October",
            .november: "November",
            .december: "December"
        ]
    }

    var shortName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        let date = Calendar.current.date(from: DateComponents(month: self.rawValue))!
        return formatter.string(from: date).uppercased()
    }
}

struct WorkoutWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Workout Stats Configuration"
    static var description: IntentDescription = "Choose which month to display."

    @Parameter(title: "Month")
    var selectedMonth: MonthOption?
}
