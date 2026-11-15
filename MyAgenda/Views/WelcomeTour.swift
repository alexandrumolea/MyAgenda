//
//  WelcomeTour.swift
//  MyAgenda
//
//  A few cards on what the app can do. Shown once on first launch and again
//  from the "…" menu.
//

import SwiftUI

struct WelcomeTour: View {
    var accent: Color

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.self) private var environment
    @State private var index = 0
    /// A Continue page turn still sliding: a touch on the pages then would
    /// stop the slide on the old card while `index` has moved on.
    @State private var turning: Task<Void, Never>?

    private struct Card {
        let picture: TourPicture
        let title: String
        let text: String

        // One thing to do on each card. On both devices:
        static let calendar = Card(picture: .calendar, title: "Pull down for the calendar",
                                   text: "Pull down on the dates to open the month.")
        static let moveBox = Card(picture: .moveBox, title: "Hold, then drag",
                                  text: "Hold a text or checklist for a moment, then drag it where you want.")
        static let moveTimer = Card(picture: .moveTimer, title: "Drag the timer anywhere",
                                    text: "The timer follows your finger, out of the way of your writing.")
        static let paste = Card(picture: .paste, title: "Hold to paste",
                                text: "Hold an empty spot to paste what you copied.")
        static let hideBar = Card(picture: .hideBar, title: "Just the page",
                                  text: "Choose Hide Bar from “…” to put the dates away.")
        static let clock = Card(picture: .clock, title: "And a quiet clock",
                                text: "With the bar hidden, choose Small Clock from “…” to keep the time.")
        static let tags = Card(picture: .tags, title: "Follow the thread",
                               text: "Tag each kind of meeting, then filter by tag to read them in order.")

        static let pad: [Card] = [
            Card(picture: .pagesUpright, title: "Many pages at once",
                 text: "Hold iPad upright and tap All Pages to see many of them together."),
            Card(picture: .pagesSideways, title: "Leaf through it like a paper agenda",
                 text: "Turn iPad sideways in All Pages and swipe, two pages at a time."),
            calendar,
            Card(picture: .squeeze, title: "Tools at the tip",
                 text: "Squeeze Apple Pencil Pro to bring the tools to where you write."),
            Card(picture: .toolbar, title: "Put the toolbar where you like",
                 text: "Hold the toolbar, then drag it to a side."),
            moveBox,
            moveTimer,
            paste,
            hideBar,
            Card(picture: .hideTools, title: "Just you and your pen",
                 text: "Choose Hide Tools from “…” to put the toolbar away."),
            clock,
            tags
        ]

        static let phone: [Card] = [
            Card(picture: .sync, title: "iPad and iPhone, always in step",
                 text: "Your pages from iPad sync here through iCloud."),
            calendar,
            moveBox,
            moveTimer,
            paste,
            hideBar,
            clock,
            tags
        ]
    }

    /// The width cards and footer keep to on a wide sheet.
    private static let readableWidth: CGFloat = 460

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    private var cards: [Card] { isPhone ? Card.phone : Card.pad }
    private var isLast: Bool { index == cards.count - 1 }

    /// The button's label on the accent: white, unless the accent is too light
    /// for it (cyan, green, orange, pink). The label is bold, so 3:1 is the bar.
    private var labelOnAccent: Color {
        let c = accent.resolve(in: environment)
        let luminance = 0.2126 * c.linearRed + 0.7152 * c.linearGreen + 0.0722 * c.linearBlue
        return 1.05 / (luminance + 0.05) < 3 ? .black.opacity(0.85) : .white
    }

    var body: some View {
        NavigationStack {
            // The footer takes its own room under the cards, not an inset: the
            // pages of a TabView don't see an inset, and the largest text must
            // scroll clear of the button, never under it.
            VStack(spacing: 0) {
                pager
                footer
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .tint(accent)
    }

    @ViewBuilder
    private var pager: some View {
        if reduceMotion {
            // No sliding pages: the cards cross-fade, a swipe still turns them.
            ZStack {
                card(index)
                    .id(index)
                    .transition(.opacity)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 30).onEnded { value in
                    let dx = value.translation.width
                    guard abs(dx) > abs(value.translation.height), abs(dx) > 50 else { return }
                    withAnimation(.easeInOut) {
                        if dx < 0 { index = min(index + 1, cards.count - 1) }
                        if dx > 0 { index = max(index - 1, 0) }
                    }
                }
            )
        } else {
            TabView(selection: $index) {
                ForEach(cards.indices, id: \.self) { i in
                    card(i).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .allowsHitTesting(turning == nil)
        }
    }

    private func card(_ i: Int) -> some View {
        let card = cards[i]
        let content = VStack(spacing: 20) {
            TourPictureView(picture: card.picture, isPhone: isPhone, accent: accent)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            Text(card.title)
                .font(.title2.bold())
            Text(card.text)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .frame(maxWidth: Self.readableWidth)
        .accessibilityElement(children: .combine)
        .accessibilityValue("Card \(i + 1) of \(cards.count)")

        // Large text may not fit the sheet: then the card scrolls.
        return ViewThatFits(in: .vertical) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            ScrollView { content.frame(maxWidth: .infinity) }
        }
    }

    private var footer: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                ForEach(cards.indices, id: \.self) { i in
                    Circle()
                        .fill(i == index ? accent : Color.secondary.opacity(0.35))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityHidden(true)

            Button {
                if isLast { dismiss() } else { advance() }
            } label: {
                Text(isLast ? "Start Writing" : "Continue")
                    .font(.headline)
                    .foregroundStyle(labelOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: Self.readableWidth)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
    }

    private func advance() {
        withAnimation(reduceMotion ? .easeInOut : .default) { index += 1 }
        if !reduceMotion {
            turning?.cancel()
            turning = Task {
                try? await Task.sleep(for: .milliseconds(450))
                if !Task.isCancelled { turning = nil }
            }
        }
        // VoiceOver stays on the button, so say where the tour went.
        let announcement = "Card \(index + 1) of \(cards.count), \(cards[index].title)"
        AccessibilityNotification.Announcement(announcement).post()
    }
}

#Preview {
    WelcomeTour(accent: .blue)
}
