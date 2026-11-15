//
//  PaperBackground.swift
//  MyAgenda
//
//  A clean page with a configurable template (dots, ruled lines, or plain) on
//  white, light yellow or dark paper.
//

import SwiftUI
import PencilKit

/// The paper's color. Everything on the page is stored as it looks on white
/// paper; dark paper shows it inverted (black ink and text turn white), the
/// way PencilKit shows ink in dark mode.
nonisolated enum PaperColor: String, CaseIterable, Identifiable, Sendable {
    case white
    case yellow
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .white: return "White"
        case .yellow: return "Yellow"
        case .dark: return "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .white: return "sun.max"
        case .yellow: return "note.text"
        case .dark: return "moon"
        }
    }

    var isDark: Bool { self == .dark }

    var uiColor: UIColor {
        switch self {
        case .white: return .white
        // A legal pad's yellow, kept pale so it stays calm to write on.
        case .yellow: return UIColor(red: 1, green: 0.985, blue: 0.88, alpha: 1)
        case .dark: return UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        }
    }

    var color: Color { Color(uiColor: uiColor) }

    var colorScheme: ColorScheme { isDark ? .dark : .light }
    var interfaceStyle: UIUserInterfaceStyle { isDark ? .dark : .light }

    /// How a color stored for white paper shows on this paper.
    func shown(_ color: UIColor) -> UIColor {
        isDark ? PKInkingTool.convertColor(color, from: .light, to: .dark) : color
    }

    /// The color to store for one shown on this paper (the reverse of `shown`).
    func stored(_ color: UIColor) -> UIColor {
        isDark ? PKInkingTool.convertColor(color, from: .dark, to: .light) : color
    }

    /// Text as it shows on this paper (text without a color is black).
    func shown(_ text: NSAttributedString) -> NSAttributedString { recolor(text, with: shown) }

    /// Text to store, from text shown on this paper.
    func stored(_ text: NSAttributedString) -> NSAttributedString { recolor(text, with: stored) }

    private func recolor(_ text: NSAttributedString, with convert: (UIColor) -> UIColor) -> NSAttributedString {
        guard isDark, text.length > 0 else { return text }
        let copy = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: copy.length)
        copy.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            copy.addAttribute(.foregroundColor, value: convert((value as? UIColor) ?? .black), range: range)
        }
        return copy
    }
}

enum PageStyle: String, CaseIterable, Identifiable {
    case dots
    case lines
    case plain

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dots: return "Dots"
        case .lines: return "Lines"
        case .plain: return "Plain"
        }
    }

    var symbol: String {
        switch self {
        case .dots: return "circle.grid.3x3"
        case .lines: return "line.3.horizontal"
        case .plain: return "rectangle"
        }
    }
}

struct PaperBackground: View {
    var style: PageStyle = .dots
    var paper: PaperColor = .white
    var spacing: CGFloat = 28

    var body: some View {
        // Lines and dots in the ink's color, faint on any paper.
        let ink = paper.isDark ? Color.white : Color.black
        Canvas { context, size in
            switch style {
            case .plain:
                break

            case .lines:
                let color = ink.opacity(paper == .yellow ? 0.09 : 0.06)
                var y = spacing
                while y < size.height {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(path, with: .color(color), lineWidth: 1)
                    y += spacing
                }

            case .dots:
                let color = ink.opacity(paper.isDark ? 0.16 : 0.13)
                let r: CGFloat = 1.4
                var y = spacing
                while y < size.height {
                    var x = spacing
                    while x < size.width {
                        let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                        context.fill(Path(ellipseIn: rect), with: .color(color))
                        x += spacing
                    }
                    y += spacing
                }
            }
        }
        .background(paper.color)
    }
}
