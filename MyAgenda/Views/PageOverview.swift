//
//  PageOverview.swift
//  MyAgenda
//
//  A pinch-to-open page overview: a full-screen grid of large page thumbnails
//  so you see as many pages as possible at a glance. Tap one to jump. Pinch out
//  (or "Gata") closes. The notebook's tags, when it has any, filter the grid.
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

    private let pageAspect: CGFloat = 0.74   // width / height

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
                    Text("Pagini")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Text(shown.count == 1 ? "1 pagină" : "\(shown.count) pagini")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Gata") { onClose() }
                        .fontWeight(.medium)
                        .padding(.leading, 12)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)

                if !notebookTags.isEmpty { tagFilter }

                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVGrid(columns: columns, spacing: 22) {
                            ForEach(shown) { page in
                                cell(page).id(page.id)
                            }
                        }
                        .padding(22)
                    }
                    .onAppear {
                        if let selection {
                            proxy.scrollTo(selection, anchor: .center)
                        }
                    }
                    .onChange(of: activeTag) {
                        let pagesLeft = shownPages
                        let target = pagesLeft.first { $0.id == selection } ?? pagesLeft.first
                        if let target { proxy.scrollTo(target.id, anchor: .center) }
                    }
                }
            }
        }
        .simultaneousGesture(
            MagnifyGesture().onEnded { value in
                if value.magnification > 1.25 { onClose() }
            }
        )
    }

    private var tagFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("Toate", isOn: activeTag == nil) { chosenTag = nil }
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

    private func cell(_ page: JournalPage) -> some View {
        let isSelected = page.id == selection
        return VStack(spacing: 8) {
            AsyncPageThumbnail(page: page, size: CGSize(width: 400, height: 540))
                .aspectRatio(pageAspect, contentMode: .fit)
                .frame(maxWidth: .infinity)
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
                Label("Șterge pagina", systemImage: "trash")
            }
        }
    }

    private func label(for page: JournalPage) -> String {
        let day = page.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)).capitalized
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
        .task(id: key) {
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
