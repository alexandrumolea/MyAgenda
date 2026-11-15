//
//  EditBar.swift
//  MyAgenda
//
//  The editing bar above the keyboard, one design for text and checklists, on
//  iPad and iPhone: a glass capsule with the tools and a round Done on the
//  right. Colors open in place, replacing the tools, so nothing floats over
//  the page. On iPhone the less frequent tools sit one level down, behind "Aa";
//  iPad has the room to show them all.
//

import SwiftUI
import UIKit

/// What the bar shows as active; updated by the editor as the caret moves.
@Observable
final class EditBarState {
    var isBold = false
    var isItalic = false
    var isUnderline = false
    var isBulleted = false
    var alignment: NSTextAlignment = .left
    var textColor: UIColor = .black
    var backgroundHex = ""
}

struct EditBarActions {
    var toggleBold: () -> Void = {}
    var toggleItalic: () -> Void = {}
    var toggleUnderline: () -> Void = {}
    var toggleBullets: () -> Void = {}
    var changeSize: (CGFloat) -> Void = { _ in }
    var setTextColor: (UIColor) -> Void = { _ in }
    var setAlignment: (NSTextAlignment) -> Void = { _ in }
    var setBackground: (String) -> Void = { _ in }
    var addItem: () -> Void = {}
    var done: () -> Void = {}
}

enum EditPalette {
    static let text: [UIColor] = [
        .black,
        UIColor(red: 0.04, green: 0.52, blue: 1, alpha: 1),
        UIColor(red: 1, green: 0.22, blue: 0.37, alpha: 1),
        UIColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1),
        UIColor(red: 1, green: 0.62, blue: 0.04, alpha: 1),
        UIColor(red: 0.75, green: 0.35, blue: 0.95, alpha: 1)
    ]
    static let background = ["#FFD60A", "#FF9F0A", "#FF3B30", "#34C759", "#0A84FF", "#BF5AF2"]
    /// How strongly a background color tints the paper.
    static let backgroundOpacity = 0.22
}

struct EditBar: View {
    enum Kind { case text, checklist }
    private enum Panel { case tools, more, textColor, background }

    let kind: Kind
    let state: EditBarState
    let actions: EditBarActions
    let accent: Color

    @State private var panel: Panel = .tools

    private var isCompact: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    var body: some View {
        HStack(spacing: 10) {
            content
                .padding(.horizontal, 4)
                .frame(height: 46)
                .glassEffect(.regular, in: .capsule)
                .animation(.snappy(duration: 0.22), value: panel)

            Spacer(minLength: 0)

            Button(action: actions.done) {
                Image(systemName: "checkmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(accent), in: .circle)
            .accessibilityLabel("Done")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .tint(accent)
    }

    @ViewBuilder private var content: some View {
        switch panel {
        case .tools:
            HStack(spacing: 2) {
                if kind == .text { textTools } else { checklistTools }
            }
            .transition(.opacity)
        case .more:
            HStack(spacing: 2) {
                back
                sizeTools
                separator
                colorTools
            }
            .transition(.opacity)
        case .textColor:
            HStack(spacing: 2) {
                back
                ForEach(EditPalette.text, id: \.self) { color in
                    swatch(Color(uiColor: color), isOn: state.textColor.isSameColor(as: color)) {
                        actions.setTextColor(color)
                    }
                }
            }
            .transition(.opacity)
        case .background:
            HStack(spacing: 2) {
                back
                tool("circle.slash", isOn: state.backgroundHex.isEmpty, label: "No Background") {
                    actions.setBackground("")
                }
                ForEach(EditPalette.background, id: \.self) { hex in
                    swatch((Color(hex: hex) ?? .gray).opacity(0.55),
                           isOn: state.backgroundHex.caseInsensitiveCompare(hex) == .orderedSame) {
                        actions.setBackground(hex)
                    }
                }
            }
            .transition(.opacity)
        }
    }

    // MARK: Groups

    @ViewBuilder private var textTools: some View {
        tool("bold", isOn: state.isBold, label: "Bold", action: actions.toggleBold)
        tool("italic", isOn: state.isItalic, label: "Italic", action: actions.toggleItalic)
        tool("underline", isOn: state.isUnderline, label: "Underline", action: actions.toggleUnderline)
        tool("list.bullet", isOn: state.isBulleted, label: "List", action: actions.toggleBullets)
        if isCompact {
            separator
            tool("textformat.size", label: "Format") { panel = .more }
        } else {
            separator
            sizeTools
            separator
            colorTools
        }
    }

    @ViewBuilder private var checklistTools: some View {
        tool("plus", label: "Add Item", action: actions.addItem)
        separator
        backgroundTool
    }

    @ViewBuilder private var sizeTools: some View {
        tool("textformat.size.smaller", label: "Smaller") { actions.changeSize(-2) }
        tool("textformat.size.larger", label: "Larger") { actions.changeSize(2) }
    }

    @ViewBuilder private var colorTools: some View {
        Button { panel = .textColor } label: {
            Circle()
                .fill(Color(uiColor: state.textColor))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                .frame(width: 22, height: 22)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Text Color")

        backgroundTool

        tool(alignmentSymbol, label: "Alignment") {
            actions.setAlignment(state.alignment == .left ? .center
                                 : state.alignment == .center ? .right : .left)
        }
    }

    private var backgroundTool: some View {
        Button { panel = .background } label: {
            RoundedRectangle(cornerRadius: 6)
                .fill(backgroundFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.35),
                                      style: StrokeStyle(lineWidth: 1, dash: state.backgroundHex.isEmpty ? [3, 2.5] : []))
                )
                .frame(width: 22, height: 22)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Background Color")
    }

    private var backgroundFill: Color {
        state.backgroundHex.isEmpty ? .clear : (Color(hex: state.backgroundHex) ?? .clear).opacity(0.55)
    }

    private var alignmentSymbol: String {
        switch state.alignment {
        case .center: return "text.aligncenter"
        case .right: return "text.alignright"
        default: return "text.alignleft"
        }
    }

    // MARK: Pieces

    private var back: some View {
        tool("chevron.left", label: "Back") {
            panel = (isCompact && kind == .text && panel != .more) ? .more : .tools
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 3)
    }

    private func tool(_ system: String, isOn: Bool = false, label: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                .frame(width: 40, height: 40)
                .background(isOn ? Color.accentColor.opacity(0.15) : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func swatch(_ color: Color, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(isOn ? Color.accentColor : .clear, lineWidth: 2).padding(-4))
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

private extension UIColor {
    func isSameColor(as other: UIColor) -> Bool {
        Color(uiColor: self).hexString == Color(uiColor: other).hexString
    }
}

/// Hosts the bar as a keyboard accessory. One instance can serve several text
/// fields (the rows of a checklist), so moving between them doesn't flicker.
final class EditBarAccessory: UIView {
    private let host: UIHostingController<EditBar>

    init(kind: EditBar.Kind, state: EditBarState, actions: EditBarActions, accent: Color) {
        host = UIHostingController(rootView: EditBar(kind: kind, state: state, actions: actions, accent: accent))
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 58))
        autoresizingMask = .flexibleWidth
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 58) }
}

/// The faint line at the end of a box that sets its width: one look for text
/// and checklists. The touch area is much larger than the line.
struct WidthHandleMark: View {
    var scale: CGFloat = 1

    var body: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.4))
            .frame(width: 4, height: 18)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .scaleEffect(1 / scale)
            .offset(x: 22, y: 8)
    }
}
