//
//  TimerActivityAttributes.swift
//  MyAgenda
//
//  Shared Live Activity attributes for the work timer. This file must be a
//  member of BOTH the app target AND the widget-extension target (add it to the
//  widget target's membership in Xcode) so the countdown can be rendered on the
//  Lock Screen / Dynamic Island.
//

import Foundation
import ActivityKit

nonisolated struct TimerActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// The moment the interval ends — the widget uses this to count down
        /// live on the Lock Screen without the app running.
        var endDate: Date
        var isRunning: Bool
    }

    var durationMinutes: Int
}
