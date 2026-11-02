//
//  Notebook.swift
//  MyAgenda
//
//  A themed notebook. Each notebook owns its own set of dated pages (and thus
//  its own calendar / thumbnail timeline).
//

import SwiftUI
import SwiftData

@Model
final class Notebook {
    var id: UUID = UUID()
    var title: String = "Agendă"
    var accentHex: String = "#0A84FF"
    var pageStyleRaw: String = PageStyle.dots.rawValue
    /// Paper color of every page that doesn't choose its own.
    var paperRaw: String = PaperColor.white.rawValue
    var sortIndex: Int = 0
    var createdAt: Date = Date.now

    @Relationship(deleteRule: .cascade, inverse: \JournalPage.notebook)
    var pages: [JournalPage]? = []

    init(title: String = "Agendă",
         accentHex: String = "#0A84FF",
         pageStyle: PageStyle = .dots,
         sortIndex: Int = 0) {
        self.id = UUID()
        self.title = title
        self.accentHex = accentHex
        self.pageStyleRaw = pageStyle.rawValue
        self.sortIndex = sortIndex
        self.createdAt = .now
    }

    var pageStyle: PageStyle {
        get { PageStyle(rawValue: pageStyleRaw) ?? .dots }
        set { pageStyleRaw = newValue.rawValue }
    }

    var paper: PaperColor {
        get { PaperColor(rawValue: paperRaw) ?? .white }
        set { paperRaw = newValue.rawValue }
    }

    var accentColor: Color { Color(hex: accentHex) ?? .blue }

    /// A small palette to offer when creating/editing notebooks.
    static let themeColors: [String] = [
        "#0A84FF", "#FF375F", "#FF9F0A", "#30D158",
        "#BF5AF2", "#64D2FF", "#FF6482", "#5E5CE6"
    ]
}
