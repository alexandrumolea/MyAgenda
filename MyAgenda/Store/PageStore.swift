//
//  PageStore.swift
//  MyAgenda
//
//  Thin helper around ModelContext for fetching and creating pages, scoped to
//  a notebook.
//

import Foundation
import SwiftData

struct PageStore {
    let context: ModelContext

    /// All pages of a notebook on a given day, ordered.
    func pages(on day: Date, in notebook: Notebook) -> [JournalPage] {
        let start = Calendar.current.startOfDay(for: day)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return [] }
        let nbID = notebook.id
        let predicate = #Predicate<JournalPage> {
            $0.notebookID == nbID && $0.day >= start && $0.day < end
        }
        let descriptor = FetchDescriptor<JournalPage>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.orderInDay)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// The first page of a day, optionally creating one if none exists.
    @discardableResult
    func firstPage(on day: Date, in notebook: Notebook, createIfMissing: Bool = true) -> JournalPage? {
        if let first = pages(on: day, in: notebook).first { return first }
        guard createIfMissing else { return nil }
        let page = JournalPage(day: day, orderInDay: 0, notebook: notebook)
        context.insert(page)
        return page
    }

    /// Append a new page to a day.
    @discardableResult
    func addPage(on day: Date, in notebook: Notebook) -> JournalPage {
        let nextOrder = (pages(on: day, in: notebook).map(\.orderInDay).max() ?? -1) + 1
        let page = JournalPage(day: day, orderInDay: nextOrder, notebook: notebook)
        context.insert(page)
        return page
    }
}
