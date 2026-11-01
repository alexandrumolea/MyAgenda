//
//  TimerActivityAttributes.swift
//  TimerWidget
//
//  Must match the app's copy (MyAgenda/Models/TimerActivityAttributes.swift)
//  exactly so the Live Activity started by the app is rendered by this widget.
//

import Foundation
import ActivityKit

nonisolated struct TimerActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var endDate: Date
        var isRunning: Bool
    }

    var durationMinutes: Int
}
