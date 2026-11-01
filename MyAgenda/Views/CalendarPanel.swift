//
//  CalendarPanel.swift
//  MyAgenda
//
//  The month calendar, on glass. It lives under the top bar and is pulled out
//  of the day strip with a finger: the panel follows the pull, and on release
//  settles open or closed. Days with notes carry a discreet dot.
//

import SwiftUI
import UIKit

/// How far the calendar is pulled out (0 closed … 1 open). Kept out of the main
/// view so only the panel re-renders while the finger moves.
@Observable
final class CalendarReveal {
    var progress: CGFloat = 0
    var isOpen: Bool { progress > 0.5 }

    func settle(open: Bool) {
        withAnimation(NotebookPagesView.liquid) { progress = open ? 1 : 0 }
    }

    /// Finger moved `distance` points down from where the pull began.
    func follow(_ distance: CGFloat, startedOpen: Bool) {
        let start: CGFloat = startedOpen ? 1 : 0
        progress = min(max(start + distance / CalendarPanel.height, 0), 1.04)
    }

    /// Open past a third of the way, or on a clear flick either way.
    func finish(velocity: CGFloat) {
        if abs(velocity) > 500 {
            settle(open: velocity > 0)
        } else {
            settle(open: progress > 0.33)
        }
    }
}

/// A vertical pan that shares the touch with what is under it, so it works on
/// the horizontally scrolling day strip and on the panel's buttons.
struct VerticalPullGesture: UIGestureRecognizerRepresentable {
    let reveal: CalendarReveal

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let distance = pan.translation(in: pan.view).y
        switch pan.state {
        case .began:
            context.coordinator.startedOpen = reveal.isOpen
        case .changed:
            reveal.follow(distance, startedOpen: context.coordinator.startedOpen)
        case .ended:
            reveal.finish(velocity: pan.velocity(in: pan.view).y)
        default:
            reveal.settle(open: context.coordinator.startedOpen)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var startedOpen = false

        /// Only clearly vertical drags: sideways ones stay with the day strip.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.y) > abs(velocity.x)
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

/// The panel in place: it grows out from under the bar, and a tap anywhere else
/// puts it away.
struct CalendarOverlay: View {
    let reveal: CalendarReveal
    let selectedDay: Date
    let markedDays: Set<Date>
    let topInset: CGFloat
    var onPick: (Date) -> Void

    var body: some View {
        let progress = reveal.progress
        if progress > 0.005 {
            ZStack(alignment: .top) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { reveal.settle(open: false) }

                CalendarPanel(selectedDay: selectedDay, markedDays: markedDays, onPick: onPick)
                    .frame(height: CalendarPanel.height, alignment: .top)
                    .opacity(Double(min(progress * 1.6, 1)))
                    .frame(height: CalendarPanel.height * progress, alignment: .top)
                    .clipped()
                    .frame(maxWidth: 380)
                    .glassEffect(.regular, in: .rect(cornerRadius: 28))
                    .gesture(VerticalPullGesture(reveal: reveal))
                    .padding(.horizontal, 16)
                    .padding(.top, topInset)
            }
        }
    }
}

struct CalendarPanel: View {
    let selectedDay: Date
    let markedDays: Set<Date>
    var onPick: (Date) -> Void

    @State private var month: Date

    /// Six week rows always, so the height never jumps between months.
    private static let rowHeight: CGFloat = 42
    static let height: CGFloat = 12 + 36 + 22 + rowHeight * 6 + 18

    private let calendar = Calendar.current

    init(selectedDay: Date, markedDays: Set<Date>, onPick: @escaping (Date) -> Void) {
        self.selectedDay = selectedDay
        self.markedDays = markedDays
        self.onPick = onPick
        let parts = Calendar.current.dateComponents([.year, .month], from: selectedDay)
        _month = State(initialValue: Calendar.current.date(from: parts) ?? selectedDay)
    }

    var body: some View {
        VStack(spacing: 0) {
            header.frame(height: 36)
            weekdays.frame(height: 22)
            grid
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 4)
                .frame(height: 18)
        }
        .padding(.top, 12)
        .padding(.horizontal, 12)
        // Sideways swipe changes the month.
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    changeMonth(by: value.translation.width < 0 ? 1 : -1)
                }
        )
    }

    private var header: some View {
        HStack {
            Button { changeMonth(by: -1) } label: { chevron("chevron.left") }
                .buttonStyle(.plain)
            Spacer()
            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(.subheadline.weight(.semibold))
                .contentTransition(.numericText())
            Spacer()
            Button { changeMonth(by: 1) } label: { chevron("chevron.right") }
                .buttonStyle(.plain)
        }
    }

    private func chevron(_ system: String) -> some View {
        Image(systemName: system)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
    }

    private var weekdays: some View {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        let ordered = Array(symbols[first...] + symbols[..<first])
        return HStack(spacing: 0) {
            ForEach(ordered.indices, id: \.self) { index in
                Text(ordered[index])
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var grid: some View {
        let days = gridDays
        return VStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { week in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { weekday in
                        dayCell(days[week * 7 + weekday])
                    }
                }
                .frame(height: Self.rowHeight)
            }
        }
    }

    /// The 42 days shown for `month`, from the week holding its first day.
    private var gridDays: [Date] {
        let weekday = calendar.component(.weekday, from: month)
        let lead = (weekday - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -lead, to: month) ?? month
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private func dayCell(_ day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
        let isToday = calendar.isDateInToday(day)
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let marked = markedDays.contains(calendar.startOfDay(for: day))

        return Button { onPick(day) } label: {
            ZStack {
                if isSelected {
                    Circle().fill(Color.accentColor).frame(width: 34, height: 34)
                }
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: 15, weight: isSelected || isToday ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.white
                                     : isToday ? Color.accentColor
                                     : inMonth ? Color.primary : Color.secondary.opacity(0.5))
                if marked {
                    Circle()
                        .fill(isSelected ? Color.white : Color.secondary)
                        .frame(width: 4, height: 4)
                        .offset(y: 12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func changeMonth(by delta: Int) {
        guard let next = calendar.date(byAdding: .month, value: delta, to: month) else { return }
        withAnimation(.snappy(duration: 0.2)) { month = next }
    }
}
