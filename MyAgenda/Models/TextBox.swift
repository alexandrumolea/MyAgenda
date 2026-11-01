//
//  TextBox.swift
//  MyAgenda
//
//  A rich-text annotation placed on a page. Position/size are stored as
//  fractions of the page so they map consistently across devices. The text
//  itself is stored as RTF data so per-range formatting is preserved.
//

import Foundation
import SwiftData

@Model
final class TextBox {
    var id: UUID = UUID()

    /// Top-left position as a fraction of the page (0...1).
    var x: Double = 0.1
    var y: Double = 0.1
    /// Width as a fraction of the page width (0...1).
    var widthFraction: Double = 0.5

    /// RTF-encoded NSAttributedString. Empty = no content yet.
    var rtfData: Data = Data()

    /// Hex background tint; empty = none (same as a checklist's).
    var backgroundColorRaw: String = ""

    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    var page: JournalPage?

    init(x: Double = 0.1, y: Double = 0.1, widthFraction: Double = 0.5, page: JournalPage? = nil) {
        self.id = UUID()
        self.x = x
        self.y = y
        self.widthFraction = widthFraction
        self.rtfData = Data()
        self.createdAt = .now
        self.updatedAt = .now
        self.page = page
    }
}
