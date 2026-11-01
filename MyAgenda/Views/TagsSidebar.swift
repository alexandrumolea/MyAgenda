//
//  TagsSidebar.swift
//  MyAgenda
//
//  Left navigation sidebar for tags: edit the current page's tags and browse /
//  jump to every page in the notebook by tag.
//

import SwiftUI
import SwiftData

struct TagsSidebar: View {
    let page: JournalPage?
    let notebookPages: [JournalPage]
    var onJump: (UUID) -> Void
    var onClose: () -> Void

    @Environment(\.modelContext) private var context
    @State private var newTag = ""

    var body: some View {
        let entries = tagIndex
        let allTags = entries.map(\.tag)
        let currentTags = page?.tags ?? []
        let suggestions = allTags.filter { tag in
            !currentTags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }

        VStack(spacing: 0) {
            HStack {
                Text("Etichete").font(.headline)
                Spacer()
                Button { onClose() } label: {
                    Image(systemName: "sidebar.leading").font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            List {
                if !favorites.isEmpty {
                    Section("Cuprins") {
                        ForEach(favorites) { p in
                            Button {
                                onJump(p.id)
                            } label: {
                                HStack {
                                    Image(systemName: "star.fill")
                                        .font(.caption)
                                        .foregroundStyle(.yellow)
                                    Text(favoriteLabel(p))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer()
                                    if p.id == page?.id {
                                        Image(systemName: "checkmark").font(.caption).foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }
                }

                if let page {
                    Section("Pagina curentă") {
                        if page.tags.isEmpty {
                            Text("Nicio etichetă").foregroundStyle(.secondary).font(.subheadline)
                        }
                        ForEach(page.tags, id: \.self) { tag in
                            HStack {
                                Label(tag, systemImage: "tag")
                                Spacer()
                                Button { removeTag(tag, from: page) } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        HStack {
                            TextField("Etichetă nouă", text: $newTag)
                                .textInputAutocapitalization(.never)
                                .onSubmit { add(newTag, to: page) }
                            Button { add(newTag, to: page) } label: {
                                Image(systemName: "plus.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                        }

                        if !suggestions.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(suggestions, id: \.self) { tag in
                                        Button { add(tag, to: page) } label: {
                                            Text(tag)
                                                .font(.caption)
                                                .padding(.horizontal, 10).padding(.vertical, 5)
                                                .background(Color(.tertiarySystemFill), in: Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        }
                    }
                }

                Section("Toate etichetele") {
                    if entries.isEmpty {
                        Text("Nicio etichetă în notebook").foregroundStyle(.secondary).font(.subheadline)
                    }
                    ForEach(entries, id: \.tag) { entry in
                        DisclosureGroup {
                            ForEach(entry.pages) { p in
                                Button { onJump(p.id) } label: {
                                    HStack {
                                        Text(p.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)).capitalized)
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        if p.id == page?.id {
                                            Image(systemName: "checkmark").font(.caption).foregroundStyle(.tint)
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Label(entry.tag, systemImage: "tag.fill")
                                Spacer()
                                Text("\(entry.pages.count)").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    // MARK: - Helpers

    private var favorites: [JournalPage] {
        notebookPages.filter { $0.isFavorite }.sorted { $0.day < $1.day }
    }

    private func favoriteLabel(_ p: JournalPage) -> String {
        let name = p.title.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { return name }
        return p.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)).capitalized
    }

    private var tagIndex: [(tag: String, pages: [JournalPage])] {
        let grouped = Dictionary(grouping: notebookPages.flatMap { page in
            page.tags.map { tag in (tag: tag, page: page) }
        }, by: \.tag)

        return grouped
            .map { tag, entries in
                (
                    tag: tag,
                    pages: entries.map(\.page).sorted { $0.day < $1.day }
                )
            }
            .sorted { $0.tag.localizedCaseInsensitiveCompare($1.tag) == .orderedAscending }
    }

    private func add(_ raw: String, to page: JournalPage) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if !page.tags.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            var tags = page.tags
            tags.append(trimmed)
            page.tags = tags
            page.updatedAt = .now
            try? context.save()
        }
        newTag = ""
    }

    private func removeTag(_ tag: String, from page: JournalPage) {
        page.tags = page.tags.filter { $0 != tag }
        page.updatedAt = .now
        try? context.save()
    }
}
