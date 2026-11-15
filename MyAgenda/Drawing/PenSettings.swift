//
//  PenSettings.swift
//  MyAgenda
//
//  Observable drawing state: pen, highlighter, eraser, lasso (cut), text.
//

import SwiftUI
import PencilKit

@Observable
final class PenSettings {
    enum ToolKind: Equatable {
        case pen
        case highlighter
        case eraser
        case lasso   // "cut": select strokes and move/cut/copy them
    }

    /// What the Pencil's double-tap does (iPad), chosen in the "…" menu. The
    /// system's preferred tap action is not followed.
    enum DoubleTapAction: String, CaseIterable {
        case lasso, highlighter, eraser, previousTool, quickTools, undo, nothing

        var label: String {
            switch self {
            case .lasso: return "Lasso"
            case .highlighter: return "Highlighter"
            case .eraser: return "Eraser"
            case .previousTool: return "Previous Tool"
            case .quickTools: return "Quick Tools"
            case .undo: return "Undo"
            case .nothing: return "Nothing"
            }
        }

        var symbol: String {
            switch self {
            case .lasso: return "lasso"
            case .highlighter: return "highlighter"
            case .eraser: return "eraser"
            case .previousTool: return "arrow.left.arrow.right"
            case .quickTools: return "rectangle.3.group"
            case .undo: return "arrow.uturn.backward"
            case .nothing: return "nosign"
            }
        }
    }

    /// Selectable ink styles for the writing pen.
    enum PenInk: String, CaseIterable, Identifiable {
        /// Keeps the raw value of the old "Pix 2" slot, so the persisted
        /// `pen.ink` and its `pen.ink.pen2.*` memory carry over as they are.
        case gel = "pen2"
        case monoline

        var id: String { rawValue }

        var label: String {
            switch self {
            case .gel: return "Gel"
            case .monoline: return "Uniform"
            }
        }

        /// Ball-pen profile for the ink surface; nil = uniform line.
        var ballpointTuning: BallpointTuning? {
            self == .gel ? .classic : nil
        }
    }

    // Only a real change: the toolbar sets the lasso again over itself.
    var tool: ToolKind = .pen { didSet { if tool != oldValue { previousTool = oldValue } } }
    /// The tool before the current one, for the Pencil's double-tap. This
    /// session only.
    private(set) var previousTool: ToolKind?
    var penInk: PenInk = .gel { didSet { persist() } }
    // Each tool keeps its own color.
    var penColor: Color = .black { didSet { persist() } }
    var highlighterColor: Color = .yellow { didSet { persist() } }
    var width: CGFloat = 4 { didSet { persist() } }              // pen width
    var highlighterWidth: CGFloat = 18 { didSet { persist() } }
    /// Eraser diameter, chosen in the eraser's popover.
    var eraserWidth: CGFloat = 16 { didSet { persist() } }

    /// Eraser sizes PencilKit accepts. Only the fixed-width pixel eraser
    /// takes a size: the plain `.bitmap` one reports 0…0 and ignores it
    /// (its size follows pencil pressure), which froze the size slider.
    static var eraserWidthRange: ClosedRange<CGFloat> {
        let range = PKEraserTool.EraserType.fixedWidthBitmap.validWidthRange
        return range.upperBound > range.lowerBound ? range : 8...80
    }

    private var isLoaded = false

    /// Color of the currently active tool (used by the color controls).
    var color: Color {
        get { tool == .highlighter ? highlighterColor : penColor }
        set { if tool == .highlighter { highlighterColor = newValue } else { penColor = newValue } }
    }

    /// Color for a specific tool (used for the per-tool color indicators).
    func color(for kind: ToolKind) -> Color {
        kind == .highlighter ? highlighterColor : penColor
    }

    init() {
        let d = UserDefaults.standard
        if let hex = d.string(forKey: Keys.penColor), let c = Color(hex: hex) { penColor = c }
        if let hex = d.string(forKey: Keys.highlighterColor), let c = Color(hex: hex) { highlighterColor = c }
        if d.object(forKey: Keys.width) != nil { width = CGFloat(d.double(forKey: Keys.width)) }
        if d.object(forKey: Keys.highlighterWidth) != nil {
            highlighterWidth = CGFloat(d.double(forKey: Keys.highlighterWidth))
        }
        // An ink no longer offered falls back to the gel pen.
        penInk = d.string(forKey: Keys.ink).flatMap(PenInk.init(rawValue:)) ?? .gel
        // Until chosen, the eraser keeps the size it had before (3× the pen).
        eraserWidth = d.object(forKey: Keys.eraserWidth) != nil
            ? CGFloat(d.double(forKey: Keys.eraserWidth))
            : max(width * 3, 16)
        isLoaded = true
    }

    private enum Keys {
        static let penColor = "pen.colorHex"          // reused: previously the shared color
        static let highlighterColor = "pen.highlighterColorHex"
        static let width = "pen.width"
        static let highlighterWidth = "pen.highlighterWidth"
        static let ink = "pen.ink"
        static let eraserWidth = "pen.eraserWidth"
    }

    private func persist() {
        guard isLoaded else { return }
        let d = UserDefaults.standard
        d.set(penColor.hexString, forKey: Keys.penColor)
        d.set(highlighterColor.hexString, forKey: Keys.highlighterColor)
        d.set(Double(width), forKey: Keys.width)
        d.set(Double(highlighterWidth), forKey: Keys.highlighterWidth)
        d.set(penInk.rawValue, forKey: Keys.ink)
        d.set(Double(eraserWidth), forKey: Keys.eraserWidth)
    }

    static let palette: [Color] = [.black, .blue, .red, .green, .orange, .purple]

    /// Width of the currently active inking tool.
    var activeWidth: CGFloat {
        get { tool == .highlighter ? highlighterWidth : width }
        set { if tool == .highlighter { highlighterWidth = newValue } else { width = newValue } }
    }

    /// What the ink surface does with the Pencil for the active tool.
    var surfaceMode: InkSurfaceView.Mode {
        switch tool {
        case .pen:
            let profile: LiveStroke.Profile = penInk.ballpointTuning.map { .gel($0) } ?? .uniform
            return .pen(profile, color: UIColor(penColor), width: width)
        case .highlighter:
            return .highlighter(color: UIColor(highlighterColor), width: highlighterWidth)
        case .eraser:
            return .eraser(width: eraserWidth)
        case .lasso:
            return .lasso
        }
    }

    // MARK: - Apple Pencil Pro gestures

    /// Double-tap on the lasso or the eraser: to it, or back from it to the
    /// tool before (or the pen).
    func toggle(_ kind: ToolKind) { tool = tool == kind ? (previousTool ?? .pen) : kind }
    /// Double-tap on Previous Tool: swaps with it. With none yet, the pen
    /// goes to the eraser and the rest to the pen.
    func swapWithPreviousTool() { tool = previousTool ?? (tool == .pen ? .eraser : .pen) }
}
