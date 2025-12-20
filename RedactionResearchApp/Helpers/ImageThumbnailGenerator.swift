import AppKit
import Foundation

enum ImageThumbnailGenerator {
    static func thumbnail(for url: URL, maxPixel: CGFloat = 512) -> NSImage? {
        guard let img = NSImage(contentsOf: url) else { return nil }
        let target = CGSize(width: maxPixel, height: maxPixel)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(target.width),
                                   pixelsHigh: Int(target.height),
                                   bitsPerSample: 8,
                                   samplesPerPixel: 4,
                                   hasAlpha: true,
                                   isPlanar: false,
                                   colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0,
                                   bitsPerPixel: 0)
        guard let rep else { return img }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: CGRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: target)
        out.addRepresentation(rep)
        return out
    }
}
