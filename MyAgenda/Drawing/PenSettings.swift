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

    /// Selectable ink styles for the writing pen.
    enum PenInk: String, CaseIterable, Identifiable {
        case monoline
        case pen
        /// Keeps the raw value of the old "Pix 2" slot, so the persisted
        /// `pen.ink` and its `pen.ink.pen2.*` memory carry over as they are.
        case gel = "pen2"
        case pencil
        case crayon

        var id: String { rawValue }

        /// The inks the surface draws; the others stay only so an old
        /// `pen.ink` value still decodes.
        static let visible: [PenInk] = [.gel, .monoline]

        var label: String {
            switch self {
            case .monoline: return "Uniform"
            case .pen: return "Pix"
            case .gel: return "Gel"
            case .pencil: return "Creion"
            case .crayon: return "Cretă"
            }
        }

        var inkType: PKInkingTool.InkType {
            switch self {
            case .monoline: return .monoline
            case .pen, .gel: return .pen
            case .pencil: return .pencil
            case .crayon: return .crayon
            }
        }

        /// Ball-pen profile for the ink surface; nil = uniform line.
        var ballpointTuning: BallpointTuning? {
            self == .gel ? .classic : nil
        }
    }

    var tool: ToolKind = .pen
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
        if let inkRaw = d.string(forKey: Keys.ink), let ink = PenInk(rawValue: inkRaw),
           PenInk.visible.contains(ink) {
            penInk = ink
        } else {
            penInk = .gel
        }
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
    static let penWidths: [CGFloat] = [2, 4, 7, 12]
    static let highlighterWidths: [CGFloat] = [12, 18, 26, 36]

    /// Whether a width control applies right now (pen or highlighter active).
    var hasWidthControl: Bool { tool == .pen || tool == .highlighter }

    /// Widths to show for the active tool.
    var widthOptions: [CGFloat] { tool == .highlighter ? Self.highlighterWidths : Self.penWidths }

    /// Width of the currently active inking tool.
    var activeWidth: CGFloat {
        get { tool == .highlighter ? highlighterWidth : width }
        set { if tool == .highlighter { highlighterWidth = newValue } else { width = newValue } }
    }

    var pkTool: PKTool {
        switch tool {
        case .pen:
            // The writing pen uses the user-selected ink style.
            return PKInkingTool(penInk.inkType, color: UIColor(penColor), width: width)
        case .highlighter:
            // `.marker` = translucent highlighter ink. PencilKit's marker
            // stops short of the widths our slider reaches.
            let range = PKInkingTool.InkType.marker.validWidthRange
            return PKInkingTool(.marker, color: UIColor(highlighterColor),
                                width: min(max(highlighterWidth, range.lowerBound), range.upperBound))
        case .eraser:
            let range = Self.eraserWidthRange
            // Pixel eraser with exactly the chosen size, whatever the pressure.
            return PKEraserTool(.fixedWidthBitmap,
                                width: min(max(eraserWidth, range.lowerBound), range.upperBound))
        case .lasso:
            return PKLassoTool()
        }
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

    /// Squeeze toggles the eraser (and back to pen).
    func toggleEraser() { tool = (tool == .eraser) ? .pen : .eraser }
    /// Double-tap toggles the lasso (and back to pen).
    func toggleLasso() { tool = (tool == .lasso) ? .pen : .lasso }
}
