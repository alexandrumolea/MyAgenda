//
//  JournalPage.swift
//  MyAgenda
//
//  A single page in a notebook. Multiple pages can belong to the same day.
//  CloudKit-compatible: every stored property has a default value and there
//  are no unique constraints (both required for SwiftData + CloudKit sync).
//

import Foundation
import SwiftData

@Model
final class JournalPage {
    var id: UUID = UUID()
    /// The day this page belongs to, normalized to the start of the day.
    var day: Date = Calendar.current.startOfDay(for: .now)
    /// Order of this page within its day (0-based).
    var orderInDay: Int = 0
    /// Serialized PKDrawing (PencilKit). Empty data = blank page.
    var drawingData: Data = Data()
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    /// Favorites / table-of-contents.
    var isFavorite: Bool = false
    var title: String = ""

    /// Newline-separated tags (stored as a single string for CloudKit safety).
    var tagsRaw: String = ""
    /// Extra page height (points) beyond one screen, so the page can grow down.
    var contentHeight: Double = 0
    /// Logical size of the page/canvas (points) — used to composite thumbnails.
    var canvasWidth: Double = 0
    var canvasHeight: Double = 0
    /// Created on purpose (the "+" / pull past the last page), so it is kept
    /// even while blank. Pages opened implicitly — today's page at launch, a
    /// day tapped in the strip — are still tidied away if left empty.
    var keepsWhenEmpty: Bool = false
    /// This page's own paper color; empty = the notebook's.
    var paperRaw: String = ""

    /// Convenience accessor over `tagsRaw`.
    var tags: [String] {
        get {
            tagsRaw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        set {
            tagsRaw = newValue
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    /// The paper this page shows: its own, else its notebook's.
    var paper: PaperColor {
        PaperColor(rawValue: paperRaw) ?? notebook?.paper ?? .white
    }

    /// Owning notebook (relationship) + denormalized id for fast @Query filters.
    var notebook: Notebook?
    var notebookID: UUID = UUID()

    @Relationship(deleteRule: .cascade, inverse: \TextBox.page)
    var textBoxes: [TextBox]? = []

    @Relationship(deleteRule: .cascade, inverse: \ImageBox.page)
    var imageBoxes: [ImageBox]? = []

    @Relationship(deleteRule: .cascade, inverse: \ChecklistBox.page)
    var checklistBoxes: [ChecklistBox]? = []

    init(day: Date = .now, orderInDay: Int = 0, notebook: Notebook? = nil) {
        self.id = UUID()
        self.day = Calendar.current.startOfDay(for: day)
        self.orderInDay = orderInDay
        self.drawingData = Data()
        self.createdAt = .now
        self.updatedAt = .now
        self.notebook = notebook
        self.notebookID = notebook?.id ?? UUID()
    }
}
