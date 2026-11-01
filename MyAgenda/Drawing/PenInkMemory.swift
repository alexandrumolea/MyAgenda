//
//  PenInkMemory.swift
//  MyAgenda
//
//  Each ink style of the writing pen (Uniform, Pix, Pix 2, Creion, Cretă)
//  remembers its own color and width: switching ink stores the settings of
//  the one you leave and restores those of the one you pick. The highlighter
//  already keeps its own color and width in PenSettings.
//

import SwiftUI

extension PenSettings {
    /// Switch the pen's ink, restoring that ink's remembered color and width.
    func selectInk(_ ink: PenInk) {
        guard ink != penInk else { return }
        let defaults = UserDefaults.standard
        defaults.set(penColor.hexString, forKey: Self.inkKey(penInk, "colorHex"))
        defaults.set(Double(width), forKey: Self.inkKey(penInk, "width"))

        penInk = ink
        // An ink never used before simply keeps the current settings.
        if let hex = defaults.string(forKey: Self.inkKey(ink, "colorHex")),
           let color = Color(hex: hex) {
            penColor = color
        }
        let widthKey = Self.inkKey(ink, "width")
        if defaults.object(forKey: widthKey) != nil {
            width = CGFloat(defaults.double(forKey: widthKey))
        }
    }

    private static func inkKey(_ ink: PenInk, _ field: String) -> String {
        "pen.ink.\(ink.rawValue).\(field)"
    }
}
