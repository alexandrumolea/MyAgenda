//
//  WelcomeTourPictures.swift
//  MyAgenda
//
//  The small line drawings on the Welcome Tour cards: a device, a page and a
//  gesture, with the notebook's accent on whatever the card is about.
//

import SwiftUI

enum TourPicture {
    case pagesUpright, pagesSideways, calendar, squeeze, toolbar, moveBox, moveTimer, paste
    case hideBar, hideTools, clock, tags, sync
}

struct TourPictureView: View {
    let picture: TourPicture
    let isPhone: Bool
    let accent: Color

    /// As large as the card's width allows: about 350 points on iPhone, 375 on
    /// iPad, smaller in a narrow window.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            drawing(scale: isPhone ? 1.6 : 1.7)
            drawing(scale: 1.3)
            drawing(scale: 1)
        }
    }

    private func drawing(scale: CGFloat) -> some View {
        Group {
            switch picture {
            case .pagesUpright: pagesUpright
            case .pagesSideways: pagesSideways
            case .calendar: calendar
            case .squeeze: squeeze
            case .toolbar: toolbar
            case .moveBox: moveBox
            case .moveTimer: moveTimer
            case .paste: paste
            case .hideBar: quiet(barHidden: true, toolsHidden: false, clock: false)
            case .hideTools: quiet(barHidden: false, toolsHidden: true, clock: false)
            case .clock: quiet(barHidden: true, toolsHidden: false, clock: true)
            case .tags: tags
            case .sync: sync
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // Drawn small, shown large: lines and marks grow with it.
        .scaleEffect(scale)
        .frame(width: Self.size.width * scale, height: Self.size.height * scale)
    }

    /// Every drawing is laid out in this fixed space, at any text size.
    private static let size = CGSize(width: 220, height: 140)
    private var center: CGPoint { CGPoint(x: Self.size.width / 2, y: Self.size.height / 2) }

    /// The device the card happens on: an iPad lying sideways, or an iPhone.
    private var screen: Screen { Screen(isPhone: isPhone, center: center) }
    private var screenOutline: some View {
        DeviceOutline(isPhone: isPhone, landscape: !isPhone, long: Screen.long(isPhone))
            .position(center)
    }

    // MARK: - Pictures

    /// iPad only: upright, All Pages lays many pages out at once.
    private var pagesUpright: some View {
        ZStack {
            DeviceOutline(isPhone: false, landscape: false, long: 128)
                .position(center)
            RoundButton(symbol: "square.grid.2x2", accent: accent)
                .position(x: 140, y: 22)
            ForEach(0..<9, id: \.self) { i in
                PageMark(highlighted: i == 4, accent: accent)
                    .frame(width: 18, height: 24)
                    .position(x: 110 + CGFloat(i % 3 - 1) * 25, y: 78 + CGFloat(i / 3 - 1) * 32)
            }
        }
    }

    /// iPad only: sideways, two pages side by side, turned with a swipe.
    @ViewBuilder private var pagesSideways: some View {
        let s = screen
        ZStack {
            screenOutline
            ForEach(0..<2, id: \.self) { i in
                PageMark(highlighted: true, accent: accent)
                    .frame(width: s.width * 0.4, height: s.height * 0.8)
                    .position(s.at(0.5 + CGFloat(i * 2 - 1) * 0.21, 0.5))
            }
            TouchMark(hold: false)
                .position(s.at(0.82, 0.62))
            DragArrow(from: s.at(0.76, 0.62), to: s.at(0.58, 0.62), bend: s.at(0.67, 0.44))
                .stroke(accent, style: .accent)
        }
    }

    /// Pulling down on the date strip opens the month under it.
    @ViewBuilder private var calendar: some View {
        let s = screen
        ZStack {
            screenOutline
            Capsule()
                .stroke(.secondary, lineWidth: 1.5)
                .frame(width: s.width * (isPhone ? 0.8 : 0.6), height: 13)
                .position(s.at(0.5, isPhone ? 0.1 : 0.14))
            TouchMark(hold: false)
                .position(s.at(0.5, isPhone ? 0.1 : 0.14))
            DragArrow(from: s.at(0.5, isPhone ? 0.17 : 0.25), to: s.at(0.5, isPhone ? 0.38 : 0.45))
                .stroke(accent, style: .accent)
            monthGrid(width: s.width * (isPhone ? 0.82 : 0.62))
                .position(s.at(0.5, isPhone ? 0.62 : 0.72))
        }
    }

    /// iPad only: a squeeze brings the tools to the Pencil's tip.
    @ViewBuilder private var squeeze: some View {
        let s = screen
        ZStack {
            screenOutline
            Image(systemName: "applepencil")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .position(s.at(0.56, 0.4))
            Capsule()
                .fill(accent.opacity(0.2))
                .strokeBorder(accent, lineWidth: 2)
                .frame(width: 62, height: 18)
                .position(s.at(0.32, 0.72))
        }
    }

    /// iPad only: the toolbar, held, then dragged to the right edge.
    @ViewBuilder private var toolbar: some View {
        let s = screen
        ZStack {
            screenOutline
            Capsule()
                .stroke(.secondary, lineWidth: 1.5)
                .frame(width: s.width * 0.42, height: 12)
                .position(s.at(0.45, 0.88))
            TouchMark(hold: true)
                .position(s.at(0.45, 0.88))
            DragArrow(from: s.at(0.62, 0.78), to: s.at(0.86, 0.6), bend: s.at(0.84, 0.84))
                .stroke(accent, style: .accent)
            Capsule()
                .stroke(accent, style: .landing)
                .frame(width: 12, height: s.height * 0.5)
                .position(s.at(0.94, 0.5))
        }
    }

    /// A held text or checklist moves to where it lands.
    @ViewBuilder private var moveBox: some View {
        let s = screen
        let block = isPhone ? CGSize(width: s.width * 0.7, height: 18) : CGSize(width: s.width * 0.3, height: 26)
        let from = isPhone ? s.at(0.5, 0.25) : s.at(0.24, 0.5)
        let to = isPhone ? s.at(0.5, 0.72) : s.at(0.76, 0.5)
        ZStack {
            screenOutline
            TextLines()
                .frame(width: block.width, height: block.height)
                .position(from)
            TouchMark(hold: true)
                .position(from)
            DragArrow(from: isPhone ? s.at(0.5, 0.36) : s.at(0.42, 0.48),
                      to: isPhone ? s.at(0.5, 0.6) : s.at(0.57, 0.48),
                      bend: isPhone ? nil : s.at(0.5, 0.3))
                .stroke(accent, style: .accent)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(accent, style: .landing)
                .frame(width: block.width + 6, height: block.height + 6)
                .position(to)
        }
    }

    /// The timer just follows the finger.
    @ViewBuilder private var moveTimer: some View {
        let s = screen
        let timer = isPhone ? CGSize(width: s.width * 0.6, height: 14) : CGSize(width: s.width * 0.28, height: 18)
        let from = isPhone ? s.at(0.5, 0.78) : s.at(0.3, 0.72)
        let to = isPhone ? s.at(0.5, 0.25) : s.at(0.72, 0.3)
        ZStack {
            screenOutline
            Capsule()
                .stroke(.secondary, lineWidth: 1.5)
                .frame(width: timer.width, height: timer.height)
                .position(from)
            Image(systemName: "timer")
                .font(.system(size: isPhone ? 8 : 10))
                .foregroundStyle(.secondary)
                .position(x: from.x - timer.width / 2 + 9, y: from.y)
            TouchMark(hold: false)
                .position(from)
            DragArrow(from: isPhone ? s.at(0.5, 0.68) : s.at(0.44, 0.62),
                      to: isPhone ? s.at(0.5, 0.36) : s.at(0.58, 0.44))
                .stroke(accent, style: .accent)
            Capsule()
                .stroke(accent, style: .landing)
                .frame(width: timer.width + 6, height: timer.height + 6)
                .position(to)
        }
    }

    /// Holding an empty spot drops the copied ink right there.
    @ViewBuilder private var paste: some View {
        let s = screen
        let spot = s.at(0.5, isPhone ? 0.55 : 0.6)
        ZStack {
            screenOutline
            TextLines()
                .frame(width: s.width * (isPhone ? 0.7 : 0.5), height: isPhone ? 18 : 22)
                .position(s.at(0.5, isPhone ? 0.2 : 0.24))
                .opacity(0.6)
            Squiggle()
                .stroke(accent, style: .accent)
                .frame(width: isPhone ? s.width * 0.6 : s.width * 0.34, height: 16)
                .position(spot)
            TouchMark(hold: true)
                .position(spot)
        }
    }

    /// The "…" menu puts the bar or (on iPad) the tools away; with the bar
    /// gone, the small clock can keep the time at the top.
    @ViewBuilder private func quiet(barHidden: Bool, toolsHidden: Bool, clock: Bool) -> some View {
        let s = screen
        ZStack {
            screenOutline
            // The clock takes the hidden bar's place.
            if !clock {
                Capsule()
                    .stroke(Color.secondary.opacity(barHidden ? 0.5 : 1),
                            style: barHidden ? .faint : StrokeStyle(lineWidth: 1.5))
                    .frame(width: s.width * (isPhone ? 0.36 : 0.62), height: 12)
                    .position(s.at(isPhone ? 0.32 : 0.45, isPhone ? 0.12 : 0.14))
            }
            RoundButton(symbol: "ellipsis", accent: clock ? nil : accent)
                .position(s.at(isPhone ? 0.72 : 0.89, isPhone ? 0.12 : 0.14))
            if clock {
                Capsule()
                    .fill(accent.opacity(0.2))
                    .strokeBorder(accent, lineWidth: 2)
                    .frame(width: isPhone ? 22 : 26, height: 13)
                    .overlay {
                        Image(systemName: "clock")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(accent)
                    }
                    .position(s.at(isPhone ? 0.34 : 0.5, isPhone ? 0.12 : 0.14))
            }
            if !isPhone {
                Capsule()
                    .stroke(Color.secondary.opacity(toolsHidden ? 0.5 : 1),
                            style: toolsHidden ? .faint : StrokeStyle(lineWidth: 1.5))
                    .frame(width: s.width * 0.42, height: 12)
                    .position(s.at(0.5, 0.88))
            }
        }
    }

    /// Pages of the same kind of meeting carry the same tag.
    @ViewBuilder private var tags: some View {
        let s = screen
        let page = isPhone ? CGSize(width: s.width * 0.56, height: s.height * 0.22)
                           : CGSize(width: s.width * 0.2, height: s.height * 0.56)
        ZStack {
            screenOutline
            ForEach(0..<3, id: \.self) { i in
                let at = isPhone ? s.at(0.46, 0.2 + CGFloat(i) * 0.3) : s.at(0.25 + CGFloat(i) * 0.25, 0.55)
                PageMark(highlighted: false, accent: accent)
                    .frame(width: page.width, height: page.height)
                    .position(at)
                if i != 1 {
                    TagShape()
                        .fill(accent)
                        .frame(width: 16, height: 8)
                        .position(x: at.x + page.width / 2, y: at.y - page.height / 2 + 7)
                }
            }
        }
    }

    /// iPhone only: the same pages on both devices.
    private var sync: some View {
        ZStack {
            DeviceOutline(isPhone: false, landscape: false, long: 104)
                .position(x: 68, y: 70)
            TextLines()
                .frame(width: 44, height: 22)
                .position(x: 68, y: 50)
            DeviceOutline(isPhone: true, landscape: false, long: 84)
                .position(x: 166, y: 70)
            TextLines()
                .frame(width: 24, height: 16)
                .position(x: 166, y: 52)
            DragArrow(from: CGPoint(x: 112, y: 58), to: CGPoint(x: 138, y: 58))
                .stroke(accent, style: .accent)
            DragArrow(from: CGPoint(x: 138, y: 82), to: CGPoint(x: 112, y: 82))
                .stroke(accent, style: .accent)
        }
    }

    private func monthGrid(width: CGFloat) -> some View {
        let dot: CGFloat = isPhone ? 3 : 4
        return VStack(spacing: isPhone ? 7 : 8) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { day in
                        let today = row == 1 && day == 3
                        Circle()
                            .fill(today ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
                            .frame(width: today ? dot + 3 : dot, height: today ? dot + 3 : dot)
                            .frame(maxWidth: .infinity)
                    }
                }
                // Only the top of the month is out yet.
                .opacity(row == 2 ? 0.4 : 1)
            }
        }
        .padding(.vertical, 8)
        .frame(width: width)
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(.secondary, lineWidth: 1.5)
        }
    }
}

// MARK: - Parts

/// Where the screen of `DeviceOutline` sits in the drawing space.
private struct Screen {
    let rect: CGRect

    static func long(_ isPhone: Bool) -> CGFloat { isPhone ? 128 : 168 }

    init(isPhone: Bool, center: CGPoint) {
        let size = DeviceOutline.size(isPhone: isPhone, landscape: !isPhone, long: Self.long(isPhone))
        rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                      width: size.width, height: size.height)
    }

    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }

    /// A point given as fractions of the screen.
    func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
    }
}

private struct DeviceOutline: View {
    let isPhone: Bool
    let landscape: Bool
    let long: CGFloat

    static func size(isPhone: Bool, landscape: Bool, long: CGFloat) -> CGSize {
        let short = long * (isPhone ? 0.46 : 0.72)
        return landscape ? CGSize(width: long, height: short) : CGSize(width: short, height: long)
    }

    var body: some View {
        let size = Self.size(isPhone: isPhone, landscape: landscape, long: long)
        RoundedRectangle(cornerRadius: long * (isPhone ? 0.13 : 0.06), style: .continuous)
            .stroke(.secondary, lineWidth: 1.5)
            .frame(width: size.width, height: size.height)
    }
}

/// A sheet of paper; the one the card is about is in the accent.
private struct PageMark: View {
    let highlighted: Bool
    let accent: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 2.5, style: .continuous)
        if highlighted {
            shape.fill(accent.opacity(0.2)).strokeBorder(accent, lineWidth: 2)
        } else {
            shape.strokeBorder(.secondary, lineWidth: 1.5)
        }
    }
}

/// A round bar button, as "…" or All Pages; in the accent when it is the one to tap.
private struct RoundButton: View {
    let symbol: String
    let accent: Color?

    var body: some View {
        let style = accent.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary)
        ZStack {
            Circle().fill(accent?.opacity(0.2) ?? .clear)
            Circle().strokeBorder(style, lineWidth: accent == nil ? 1.5 : 2)
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(style)
        }
        .frame(width: 18, height: 18)
    }
}

/// A finger on the glass; the ring means it is held.
private struct TouchMark: View {
    let hold: Bool

    var body: some View {
        ZStack {
            Circle().fill(.secondary).frame(width: 8, height: 8)
            if hold {
                Circle().stroke(.secondary, lineWidth: 1.5).frame(width: 20, height: 20)
            }
        }
    }
}

/// A few lines of handwriting.
private struct TextLines: View {
    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 0) {
                ForEach([1, 0.85, 0.6], id: \.self) { (part: CGFloat) in
                    Capsule()
                        .fill(.secondary)
                        .frame(width: geo.size.width * part, height: 2.5)
                        .frame(maxHeight: .infinity)
                }
            }
        }
    }
}

/// A line with an arrowhead, straight or bent through `bend`.
private nonisolated struct DragArrow: Shape {
    let from: CGPoint
    let to: CGPoint
    var bend: CGPoint?

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        if let bend {
            path.addQuadCurve(to: to, control: bend)
        } else {
            path.addLine(to: to)
        }
        // The head points along the line's last stretch.
        let back = bend ?? from
        let angle = atan2(to.y - back.y, to.x - back.x) + .pi
        for side: CGFloat in [-0.5, 0.5] {
            path.move(to: to)
            path.addLine(to: CGPoint(x: to.x + 6 * cos(angle + side), y: to.y + 6 * sin(angle + side)))
        }
        return path
    }
}

/// A stroke of ink, as pasted.
private nonisolated struct Squiggle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let humps = 3
        let step = rect.width / CGFloat(humps)
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        for i in 0..<humps {
            let x = rect.minX + CGFloat(i) * step
            path.addCurve(to: CGPoint(x: x + step, y: rect.midY),
                          control1: CGPoint(x: x + step * 0.3, y: rect.minY),
                          control2: CGPoint(x: x + step * 0.7, y: rect.maxY))
        }
        return path
    }
}

/// A label with a pointed end, as on a tag.
private nonisolated struct TagShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.height / 2, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + rect.height / 2, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private extension StrokeStyle {
    /// The accent line: arrows and ink.
    static let accent = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
    /// Where something lands.
    static let landing = StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 3])
    /// What is put away.
    static let faint = StrokeStyle(lineWidth: 1.5, dash: [3, 3])
}

#Preview {
    let all: [TourPicture] = [.pagesUpright, .pagesSideways, .calendar, .squeeze, .toolbar, .moveBox, .moveTimer,
                              .paste, .hideBar, .hideTools, .clock, .tags, .sync]
    ScrollView {
        ForEach([false, true], id: \.self) { phone in
            ForEach(all, id: \.self) { picture in
                TourPictureView(picture: picture, isPhone: phone, accent: .orange)
                    .border(.quaternary)
            }
        }
    }
}
