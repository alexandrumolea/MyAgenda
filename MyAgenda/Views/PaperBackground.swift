//
//  PaperBackground.swift
//  MyAgenda
//
//  A clean white page with a configurable template: dots, ruled lines, or plain.
//

import SwiftUI

enum PageStyle: String, CaseIterable, Identifiable {
    case dots
    case lines
    case plain

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dots: return "Puncte"
        case .lines: return "Linii"
        case .plain: return "Simplu"
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
    var spacing: CGFloat = 28

    var body: some View {
        Canvas { context, size in
            switch style {
            case .plain:
                break

            case .lines:
                let color = Color.black.opacity(0.06)
                var y = spacing
                while y < size.height {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(path, with: .color(color), lineWidth: 1)
                    y += spacing
                }

            case .dots:
                let color = Color.black.opacity(0.13)
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
        .background(Color.white)
    }
}
