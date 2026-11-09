//
//  TestInkCleanup.swift
//  MyAgenda
//
//  One-time cleanup of what the 2 Nov 2026 Pencil tests left behind: strokes
//  built by the custom pen engine with the Pencil's light pressure, which
//  PencilKit draws next to invisible. Invisible but synced, they made
//  PencilKit reorder that page on every load, and the devices kept sending it
//  back and forth. Also turns off the detailed iCloud log used to find that.
//

import Foundation
import PencilKit
import SwiftData

enum TestInkCleanup {
    private static let doneKey = "testInkCleanup.2026-11-02"

    static func runOnce(in context: ModelContext) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.removeObject(forKey: "com.apple.CoreData.CloudKitDebug")

        let pages = (try? context.fetch(FetchDescriptor<JournalPage>())) ?? []
        var cleaned = 0
        for page in pages where !page.drawingData.isEmpty {
            guard let drawing = try? PKDrawing(data: page.drawingData) else { continue }
            let kept = drawing.strokes.filter { !isEngineStroke($0) }
            guard kept.count < drawing.strokes.count else { continue }
            page.drawingData = PKDrawing(strokes: kept).dataRepresentation()
            page.updatedAt = .now
            cleaned += 1
        }
        if cleaned > 0 { try? context.save() }
        print("☁️ Sync: curățate liniile de test de pe \(cleaned) pagini")
        defaults.set(true, forKey: doneKey)
    }

    /// The custom engine's mark: a perfectly upright, unrotated pen on every
    /// point (a real Pencil always reports some tilt) and the first point
    /// repeated three times to pin the curve's start. The gel strokes it
    /// commits today carry force 1 on every point, which the test strokes
    /// never did, so a reinstall leaves them alone.
    private static func isEngineStroke(_ stroke: PKStroke) -> Bool {
        let path = stroke.path
        guard path.count >= 3 else { return false }
        let start = path[0].location
        guard path[1].location == start, path[2].location == start else { return false }
        return path.allSatisfy { point in
            abs(point.altitude - .pi / 2) < 0.001 && abs(point.azimuth) < 0.001 && point.force < 0.999
        }
    }
}
