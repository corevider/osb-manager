import CoreGraphics
import Foundation

public enum WindowPlacementPolicy {
    public static let minimumWidth = 400
    public static let minimumHeight = 300
    public static let defaultSize = CGSize(width: 1280, height: 800)

    public static func restoredFrame(for placement: WindowPlacement?, screens: [CGRect]) -> CGRect? {
        guard let placement, placement.width >= minimumWidth, placement.height >= minimumHeight else { return nil }
        let frame = CGRect(x: placement.x, y: placement.y, width: placement.width, height: placement.height)
        return screens.contains { $0.intersects(frame) } ? frame : nil
    }

    public static func placement(frame: CGRect, maximized: Bool) -> WindowPlacement {
        WindowPlacement(
            x: Int(frame.origin.x.rounded()),
            y: Int(frame.origin.y.rounded()),
            width: Int(frame.size.width.rounded()),
            height: Int(frame.size.height.rounded()),
            maximized: maximized
        )
    }
}
