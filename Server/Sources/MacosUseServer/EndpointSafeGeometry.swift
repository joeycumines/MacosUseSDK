import CoreGraphics

enum EndpointSafeGeometry {
    static func containsValidEndpoints(
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        requiresPositiveSize: Bool,
    ) -> Bool {
        guard x.isFinite,
              y.isFinite,
              width.isFinite,
              height.isFinite,
              requiresPositiveSize ? width > 0 : width >= 0,
              requiresPositiveSize ? height > 0 : height >= 0
        else {
            return false
        }
        let maxX = x + width
        let maxY = y + height
        guard maxX.isFinite, maxY.isFinite else {
            return false
        }
        if requiresPositiveSize {
            return maxX > x && maxY > y
        }
        return maxX >= x && maxY >= y
    }

    static func containsValidEndpoints(
        _ rectangle: CGRect,
        requiresPositiveSize: Bool,
    ) -> Bool {
        containsValidEndpoints(
            x: rectangle.origin.x,
            y: rectangle.origin.y,
            width: rectangle.size.width,
            height: rectangle.size.height,
            requiresPositiveSize: requiresPositiveSize,
        )
    }
}
