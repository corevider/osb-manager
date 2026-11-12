import AppKit

@MainActor
enum ShotCamera {
    static func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    }

    static func png(of window: NSWindow, scale: Double, crop: ShotCrop?) throws -> Data {
        guard let content = window.contentView, let view = content.superview else { throw ShotFixtureError("The main window has no content.") }
        view.layoutSubtreeIfNeeded()
        let tabControls = descendants(of: content).compactMap { $0 as? NSTabView }.flatMap { $0.subviews.compactMap { $0 as? NSSegmentedControl } }
        let strips = try tabControls.map { (image: try render(copyOf: $0, appearance: window.appearance, scale: scale), rect: $0.convert($0.bounds, to: nil)) }
        tabControls.forEach { $0.isHidden = true }
        view.displayIfNeeded()
        let bounds = view.bounds
        let rep = try bitmap(size: bounds.size, scale: scale)
        view.cacheDisplay(in: bounds, to: rep)
        tabControls.forEach { $0.isHidden = false }
        try draw(strips, onto: rep, appearance: window.appearance ?? view.effectiveAppearance)
        let frame = content.convert(content.bounds, to: view)
        let contentRect = CGRect(
            x: (frame.minX * scale).rounded(),
            y: ((bounds.height - frame.maxY) * scale).rounded(),
            width: (frame.width * scale).rounded(),
            height: (frame.height * scale).rounded()
        )
        guard let drawn = rep.cgImage, var image = drawn.cropping(to: contentRect) else { throw ShotFixtureError("The window could not be drawn.") }
        if let crop {
            let rect = CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height)
            guard CGRect(x: 0, y: 0, width: image.width, height: image.height).contains(rect), let cropped = image.cropping(to: rect) else {
                throw ShotFixtureError("The crop \(rect) is outside the \(image.width) x \(image.height) image.")
            }
            image = cropped
        }
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ShotFixtureError("The image could not be encoded as PNG.")
        }
        return data
    }

    private static func bitmap(size: NSSize, scale: Double) throws -> NSBitmapImageRep {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * scale).rounded()),
            pixelsHigh: Int((size.height * scale).rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { throw ShotFixtureError("Could not create a \(size.width) x \(size.height) bitmap.") }
        rep.size = size
        return rep
    }

    private static func draw(_ strips: [(image: NSImage, rect: NSRect)], onto rep: NSBitmapImageRep, appearance: NSAppearance) throws {
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { throw ShotFixtureError("The tab strip could not be drawn.") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        for strip in strips {
            appearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                strip.rect.fill()
            }
            strip.image.draw(in: strip.rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func render(copyOf original: NSSegmentedControl, appearance: NSAppearance?, scale: Double) throws -> NSImage {
        let labels = (0..<original.segmentCount).map { original.label(forSegment: $0) ?? "" }
        let copy = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: nil, action: nil)
        copy.selectedSegment = original.selectedSegment
        copy.frame = NSRect(origin: .zero, size: original.bounds.size)
        let holder = NSWindow(contentRect: copy.frame, styleMask: [.titled], backing: .buffered, defer: false)
        holder.appearance = appearance
        let root = NSView(frame: copy.frame)
        root.addSubview(copy)
        holder.contentView = root
        settle()
        let rep = try bitmap(size: copy.bounds.size, scale: scale)
        copy.cacheDisplay(in: copy.bounds, to: rep)
        holder.close()
        let image = NSImage(size: copy.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }
}
