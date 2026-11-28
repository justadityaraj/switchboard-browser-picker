import CoreGraphics

public enum PickerPlacement {
    public static func origin(cursor: CGPoint, size: CGSize, in bounds: CGRect) -> CGPoint {
        let inset: CGFloat = 4
        let right = cursor.x - inset
        let x = right + size.width <= bounds.maxX ? right : cursor.x + inset - size.width
        let below = cursor.y + inset - size.height
        let y = below >= bounds.minY ? below : cursor.y - inset
        return CGPoint(
            x: min(max(x, bounds.minX), bounds.maxX - size.width),
            y: min(max(y, bounds.minY), bounds.maxY - size.height)
        )
    }
}
