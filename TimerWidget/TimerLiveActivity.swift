//
//  TimerLiveActivity.swift
//  MyAgendaWidget  (Widget Extension target)
//
//  Live Activity UI for the work timer: a live countdown on the Lock Screen and
//  in the Dynamic Island. Add this file to the widget-extension target, and make
//  sure `TimerActivityAttributes.swift` is a member of that target too.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct TimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TimerActivityAttributes.self) { context in
            // Lock Screen / banner presentation
            HStack(spacing: 14) {
                Image(systemName: "timer")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Interval de lucru")
                        .font(.subheadline.weight(.medium))
                    Text("\(context.attributes.durationMinutes) min")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(timerInterval: range(context), countsDown: true)
                    .monospacedDigit()
                    .font(.system(.title, design: .rounded).weight(.semibold))
                    .frame(width: 110, alignment: .trailing)
            }
            .padding()
            .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Lucru", systemImage: "timer")
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: range(context), countsDown: true)
                        .monospacedDigit()
                        .font(.title2)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                }
            } compactLeading: {
                Image(systemName: "timer")
            } compactTrailing: {
                Text(timerInterval: range(context), countsDown: true)
                    .monospacedDigit()
                    .frame(width: 44)
            } minimal: {
                Image(systemName: "timer")
            }
        }
    }

    /// A safe date range even if the end has already passed.
    private func range(_ context: ActivityViewContext<TimerActivityAttributes>) -> ClosedRange<Date> {
        let end = max(context.state.endDate, Date.now.addingTimeInterval(1))
        return Date.now...end
    }
}
