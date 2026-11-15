//
//  DateStrip.swift
//  MyAgenda
//
//  Horizontal day/date scroller for the top bar's glass pill. The current page's day is
//  highlighted; today is marked with a dot at the top, days with notes with a
//  discreet dot below the number. Tap a day to jump to it.
//

import SwiftUI

struct DateStrip: View {
    let selectedDay: Date
    /// Start-of-day dates that have notes.
    var markedDays: Set<Date> = []
    var onSelect: (Date) -> Void

    private let calendar = Calendar.current
    private let days: [Date]

    init(selectedDay: Date, markedDays: Set<Date> = [], onSelect: @escaping (Date) -> Void) {
        self.selectedDay = selectedDay
        self.markedDays = markedDays
        self.onSelect = onSelect
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -180, to: cal.startOfDay(for: .now)) ?? .now
        self.days = (0..<365).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // Lazy: only the visible days exist, which keeps the strip light
                // while it stretches and drains during the bar's hide/show flow.
                LazyHStack(spacing: 2) {
                    ForEach(days, id: \.self) { day in
                        dayCell(day)
                            .id(day)
                            .onTapGesture { onSelect(day) }
                    }
                }
                // Keeps the first/last day clear of the capsule's rounded ends.
                .padding(.horizontal, 16)
            }
            .onAppear {
                proxy.scrollTo(calendar.startOfDay(for: selectedDay), anchor: .center)
            }
            .onChange(of: selectedDay) { _, newDay in
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(calendar.startOfDay(for: newDay), anchor: .center)
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
        let isToday = calendar.isDateInToday(day)
        let isFirstOfMonth = calendar.component(.day, from: day) == 1
        let top = isFirstOfMonth
            ? day.formatted(.dateTime.month(.abbreviated).locale(.app))
            : day.formatted(.dateTime.weekday(.narrow).locale(.app))

        return VStack(spacing: 1) {
            Text(top)
                .font(.system(size: 10, weight: isFirstOfMonth ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            Text(day.formatted(.dateTime.day()))
                .font(.system(size: 15, weight: isSelected ? .bold : .regular))
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
            Capsule()
                .fill(isSelected ? Color.accentColor : .clear)
                .frame(width: 16, height: 2.5)
                .overlay {
                    if !isSelected && markedDays.contains(calendar.startOfDay(for: day)) {
                        Circle().fill(Color.secondary).frame(width: 3.5, height: 3.5)
                    }
                }
        }
        .frame(width: 34)
        .padding(.vertical, 2)
        .overlay(alignment: .topTrailing) {
            if isToday && !isSelected {
                Circle().fill(Color.accentColor).frame(width: 5, height: 5).offset(x: -6, y: 0)
            }
        }
        .contentShape(Rectangle())
    }
}
