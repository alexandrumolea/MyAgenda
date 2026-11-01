//
//  ChecklistBox.swift
//  MyAgenda
//
//  A dedicated checklist element on a page (separate from text boxes). By
//  default it's in "check mode": tapping a circle toggles it. Editing the text
//  requires the explicit edit button.
//

import Foundation
import SwiftData

struct ChecklistItem: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var text: String = ""
    var checked: Bool = false
}

@Model
final class ChecklistBox {
    var id: UUID = UUID()
    var x: Double = 0.15
    var y: Double = 0.12
    var widthFraction: Double = 0.45
    /// JSON-encoded [ChecklistItem].
    var itemsData: Data = Data()
    /// "#RRGGBB" background tint, or "" for no background. Rendered semi-transparent.
    var backgroundColorRaw: String = ""
    var createdAt: Date = Date.now
    var page: JournalPage?

    init(x: Double = 0.15, y: Double = 0.12, widthFraction: Double = 0.45, page: JournalPage? = nil) {
        self.id = UUID()
        self.x = x
        self.y = y
        self.widthFraction = widthFraction
        self.itemsData = Data()
        self.createdAt = .now
        self.page = page
    }

    var items: [ChecklistItem] {
        get { (try? JSONDecoder().decode([ChecklistItem].self, from: itemsData)) ?? [] }
        set { itemsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}
