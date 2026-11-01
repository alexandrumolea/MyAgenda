//
//  ImageBox.swift
//  MyAgenda
//
//  A photo placed on a page. Position/size are fractions of the page so they
//  map consistently across devices. The image blob is stored externally.
//  Cropping is non-destructive: the original stays in `imageData` and the crop
//  is a rectangle over it, so it can always be redone.
//

import Foundation
import SwiftData
import UIKit

@Model
final class ImageBox {
    var id: UUID = UUID()

    /// Top-left position as a fraction of the page (0...1).
    var x: Double = 0.2
    var y: Double = 0.2
    /// Width as a fraction of the page width.
    var widthFraction: Double = 0.4
    /// height / width of the visible (cropped) image.
    var aspectRatio: Double = 1.0
    /// Visible part of the original, as fractions of it (0...1).
    var cropX: Double = 0
    var cropY: Double = 0
    var cropWidth: Double = 1
    var cropHeight: Double = 1

    @Attribute(.externalStorage) var imageData: Data = Data()

    var createdAt: Date = Date.now
    var page: JournalPage?

    init(x: Double = 0.2, y: Double = 0.2,
         widthFraction: Double = 0.4, aspectRatio: Double = 1.0,
         imageData: Data = Data(), page: JournalPage? = nil) {
        self.id = UUID()
        self.x = x
        self.y = y
        self.widthFraction = widthFraction
        self.aspectRatio = aspectRatio
        self.imageData = imageData
        self.createdAt = .now
        self.page = page
    }
}

extension ImageBox {
    /// Visible part of the original, in unit coordinates.
    var cropRect: CGRect { CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight) }

    /// height / width of the whole original.
    var originalAspectRatio: Double { aspectRatio * cropWidth / cropHeight }

    /// Width of the whole original on the page (fraction of the page width).
    var originalWidthFraction: Double { widthFraction / cropWidth }

    /// Changes the crop, keeping the photo's scale and the kept part exactly
    /// where it is on the page.
    func applyCrop(_ rect: CGRect) {
        let fullWidth = originalWidthFraction
        let fullAspect = originalAspectRatio
        let fullHeight = fullWidth * fullAspect   // in page widths, like `y`
        let originX = x - cropX * fullWidth
        let originY = y - cropY * fullHeight

        cropX = Double(rect.minX)
        cropY = Double(rect.minY)
        cropWidth = Double(rect.width)
        cropHeight = Double(rect.height)
        x = originX + cropX * fullWidth
        y = originY + cropY * fullHeight
        widthFraction = fullWidth * cropWidth
        aspectRatio = fullAspect * cropHeight / cropWidth
    }

    /// The part of `image` inside `rect` (unit coordinates).
    nonisolated static func cropped(_ image: UIImage, to rect: CGRect) -> UIImage {
        guard rect != CGRect(x: 0, y: 0, width: 1, height: 1), let cg = image.cgImage else { return image }
        let pixels = CGRect(x: rect.minX * CGFloat(cg.width), y: rect.minY * CGFloat(cg.height),
                            width: rect.width * CGFloat(cg.width), height: rect.height * CGFloat(cg.height))
            .integral
        guard let part = cg.cropping(to: pixels) else { return image }
        return UIImage(cgImage: part, scale: image.scale, orientation: image.imageOrientation)
    }
}
