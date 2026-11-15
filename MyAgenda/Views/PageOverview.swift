//
//  PageOverview.swift
//  MyAgenda
//
//  A pinch-to-open page overview: a full-screen grid of large page thumbnails
//  so you see as many pages as possible at a glance. On an iPad wider than
//  tall it shows spreads instead: two pages side by side, as tall as fits,
//  one spread per swipe. Tap one to jump. Pinch out (or "Done") closes. The
//  notebook's tags, when it has any, filter the pages.
//

import SwiftUI

struct PageOverview: View {
    let pages: [JournalPage]
    let selection: UUID?
    let accent: Color
    var onSelect: (UUID) -> Void
    var onDelete: (JournalPage) -> Void
    var onClose: () -> Void

    /// The tag chosen in the row of chips; nil shows every page.
    @State private var chosenTag: String?

    @State private var windowSize: CGSize = .zero
    /// The room under the header and the chips.
    @State private var area: CGSize = .zero
    /// The spread in view, by its left page.
    @State private var spreadID: UUID?
    /// The page to keep in view when the layout changes (rotation): one per
    /// layout, each written only by its own, so the first layout shown opens
    /// on the selected page rather than on whatever it saw first.
    @State private var gridFocus: UUID?
    @State private var spreadFocus: UUID?

    private let pageAspect: CGFloat = 0.74   // width / height
    private let spreadGap: CGFloat = 28
    private let spreadMargin: CGFloat = 24

    private var isSpread: Bool {
        UIDevice.current.userInterfaceIdiom != .phone && windowSize.width > windowSize.height
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 270, maximum: 360), spacing: 24)]
    }

    /// Each tag once, however it was capitalized on each page.
    private var notebookTags: [String] {
        var seen = Set<String>()
        return pages.flatMap(\.tags)
            .filter { seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The chosen tag, while a page still has it (it may be removed on another
    /// device, or go with the last page that had it).
    private var activeTag: String? {
        guard let chosenTag else { return nil }
        return notebookTags.first { Self.same($0, chosenTag) }
    }

    private var shownPages: [JournalPage] {
        guard let activeTag else { return pages }
        return pages.filter { page in page.tags.contains { Self.same($0, activeTag) } }
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }

    var body: some View {
        let shown = shownPages
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Text("Pages")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Text(shown.count == 1 ? "1 page" : "\(shown.count) pages")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Done") { onClose() }
                        .fontWeight(.medium)
                        .padding(.leading, 12)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)

                if !notebookTags.isEmpty { tagFilter }

                // Nothing until both sizes are known, so neither layout starts
                // rendering thumbnails it won't keep.
                Color.clear
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { area = $0 }
                    .overlay {
                        if windowSize != .zero, area != .zero {
                            if isSpread { spreads(shown) } else { grid(shown) }
                        }
                    }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { windowSize = size }
        }
        .simultaneousGesture(
            MagnifyGesture().onEnded { value in
                if value.magnification > 1.25 { onClose() }
            }
        )
    }

    private func grid(_ shown: [JournalPage]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(shown) { page in
                        cell(page, thumbSize: CGSize(width: 400, height: 540)).id(page.id)
                    }
                }
                .padding(22)
                .scrollTargetLayout()
            }
            .onScrollTargetVisibilityChange(idType: UUID.self) { ids in
                if !ids.isEmpty { gridFocus = ids[ids.count / 2] }
            }
            .onAppear {
                // The spreads get a fresh position when they come back.
                spreadID = nil
                if let target = spreadFocus ?? selection {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
            .onChange(of: activeTag) {
                let pagesLeft = shownPages
                let target = pagesLeft.first { $0.id == selection } ?? pagesLeft.first
                if let target { proxy.scrollTo(target.id, anchor: .center) }
            }
        }
    }

    // MARK: Spreads

    /// Fixed pairs of the pages shown (1–2, 3–4, …); an odd last page is alone.
    private struct Spread: Identifiable {
        let index: Int
        let pages: [JournalPage]
        var id: UUID { pages[0].id }
    }

    private static func spreads(of shown: [JournalPage]) -> [Spread] {
        stride(from: 0, to: shown.count, by: 2).map { start in
            Spread(index: start / 2, pages: Array(shown[start..<min(start + 2, shown.count)]))
        }
    }

    /// The spread that holds `page`, by its left page.
    private static func spreadID(containing page: UUID?, in shown: [JournalPage]) -> UUID? {
        guard let page, let i = shown.firstIndex(where: { $0.id == page }) else { return nil }
        return shown[i - i % 2].id
    }

    /// As tall as fits under the label, two pages and the gap within the width.
    /// Whole tens, so a small change in the room doesn't render a new size.
    private var spreadPageSize: CGSize {
        let fitsHeight = area.height - 28 - 2 * 16
        let fitsWidth = (area.width - spreadGap - 2 * spreadMargin) / 2 / pageAspect
        let height = max(floor(min(fitsHeight, fitsWidth) / 10) * 10, 10)
        return CGSize(width: (height * pageAspect).rounded(), height: height)
    }

    private func spreads(_ shown: [JournalPage]) -> some View {
        let spreads = Self.spreads(of: shown)
        let size = spreadPageSize
        // While `spreadID` names no spread (before the first scroll, or a
        // moment after the pages changed) every spread may load: the lazy
        // stack only builds the few on screen.
        let current = spreads.firstIndex { $0.id == spreadID }
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(spreads) { spread in
                    // Only the spreads next to this one keep their thumbnails.
                    let loads = current.map { abs(spread.index - $0) <= 1 } ?? true
                    HStack(spacing: spreadGap) {
                        ForEach(spread.pages) { page in
                            cell(page, thumbSize: size, width: size.width, loads: loads)
                        }
                        if spread.pages.count == 1 {
                            Color.clear.frame(width: size.width)
                        }
                    }
                    .padding(.vertical, 16)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        // No margins on the scroll view itself: paging would drift.
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $spreadID)
        // A new filter re-pairs every page, and a scroll view whose content
        // changes under it keeps its old offset and drops any position set
        // then (even one tick later). A fresh one per filter opens where its
        // `onAppear` puts it, as on opening the overview.
        .id(activeTag)
        .onAppear {
            // The grid's page counts only for the rotation that brought us
            // here; after a filter change the selected page leads.
            let target = Self.spreadID(containing: gridFocus, in: shown)
                ?? Self.spreadID(containing: selection, in: shown)
                ?? shown.first?.id
            gridFocus = nil
            showSpread(target)
        }
        .onChange(of: spreadID) { _, id in
            let shown = shownPages
            guard let id, let i = shown.firstIndex(where: { $0.id == id }) else { return }
            let pair = shown[i..<min(i + 2, shown.count)]
            spreadFocus = pair.contains { $0.id == selection } ? selection : id
        }
        // Pages came or went (here or on another device): the spread's left
        // page may now be a right page, or gone. Re-pair around it, or stay
        // at the same place.
        .onChange(of: shown.map(\.id)) { old, new in
            guard let spreadID, !new.isEmpty else { return }
            if let i = new.firstIndex(of: spreadID) {
                if i % 2 == 1 { showSpread(new[i - 1]) }
            } else if let i = old.firstIndex(of: spreadID) {
                let kept = min(i, new.count - 1)
                showSpread(new[kept - kept % 2])
            }
        }
        .onChange(of: area.width) {
            showSpread(Self.spreadID(containing: spreadFocus, in: shownPages) ?? spreadID)
        }
    }

    private func showSpread(_ id: UUID?) {
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { spreadID = id }
    }

    private var tagFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", isOn: activeTag == nil) { chosenTag = nil }
                ForEach(notebookTags, id: \.self) { tag in
                    let isOn = activeTag.map { Self.same($0, tag) } ?? false
                    chip(tag, isOn: isOn) { chosenTag = isOn ? nil : tag }
                }
            }
            .padding(.horizontal, 24)
        }
        .padding(.bottom, 10)
    }

    private func chip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { action() }
        } label: {
            Text(title)
                .font(.subheadline.weight(isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isOn ? AnyShapeStyle(accent) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// `width` fixes the page at `thumbSize` (spreads); without it the page
    /// fills its column.
    private func cell(_ page: JournalPage, thumbSize: CGSize, width: CGFloat? = nil,
                      loads: Bool = true) -> some View {
        let isSelected = page.id == selection
        return VStack(spacing: 8) {
            AsyncPageThumbnail(page: page, size: thumbSize, loads: loads)
                .aspectRatio(width == nil ? pageAspect : thumbSize.width / thumbSize.height,
                             contentMode: .fit)
                .frame(maxWidth: width ?? .infinity)
                .background(page.paper.color, in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(isSelected ? accent : Color.black.opacity(0.12),
                                      lineWidth: isSelected ? 3 : 1)
                )
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)

            Text(label(for: page))
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? accent : .secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect(page.id) }
        .contextMenu {
            Button(role: .destructive) { onDelete(page) } label: {
                Label("Delete Page", systemImage: "trash")
            }
        }
    }

    private func label(for page: JournalPage) -> String {
        let day = page.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(.app))
        let sameDay = pages.filter { $0.day == page.day }
        if sameDay.count > 1, let idx = sameDay.firstIndex(where: { $0.id == page.id }) {
            return "\(day) · \(idx + 1)/\(sameDay.count)"
        }
        return day
    }
}

/// Shows the page's latest thumbnail: it reacts to any change on the page, and
/// renders only if this version of the page has no thumbnail yet.
private struct AsyncPageThumbnail: View {
    let page: JournalPage
    let size: CGSize
    /// False drops the thumbnail (spreads far from view), to save memory.
    var loads = true

    @State private var image: UIImage?

    var body: some View {
        let key = DrawingThumbnailRenderer.key(for: page, size: size)
        Group {
            if let image {
                Image(uiImage: image).resizable()
            } else {
                Rectangle()
                    .fill(page.paper.color)
                    .overlay {
                        ProgressView().controlSize(.small)
                    }
            }
        }
        .task(id: loads ? key : nil) {
            guard loads else {
                image = nil
                return
            }
            let cached = await Task.detached(priority: .utility) {
                DrawingThumbnailRenderer.cachedThumbnail(forKey: key).map(RenderedThumbnail.init)
            }.value
            // A newer version of the page may have started meanwhile: an older
            // result must never replace it. The old thumbnail stays until then.
            guard !Task.isCancelled else { return }
            if let cached {
                image = cached.image
                return
            }
            // A flick past many spreads starts and cancels many of these. The
            // detached render isn't cancelled with them, so wait to be sure
            // this one is still wanted before queueing it.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let snapshot = DrawingThumbnailRenderer.snapshot(for: page, size: size)
            let rendered = await Task.detached(priority: .utility) {
                RenderedThumbnail(image: DrawingThumbnailRenderer.thumbnail(for: snapshot))
            }.value
            guard !Task.isCancelled else { return }
            image = rendered.image
        }
    }

}

private struct RenderedThumbnail: @unchecked Sendable {
    let image: UIImage
}
