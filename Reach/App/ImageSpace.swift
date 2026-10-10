import CoreGraphics

/// Image space: normalized [0, 1], origin top-left, in the portrait 720×1280 camera frame.
enum ImageSpace {
    /// Width / height of the portrait frame.
    static let aspect: CGFloat = 720.0 / 1280.0

    /// Where the aspect-fit preview draws the frame inside a view of `size`.
    static func fitRect(in size: CGSize) -> CGRect {
        var width = size.width, height = size.width / aspect
        if height > size.height {
            height = size.height
            width = height * aspect
        }
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
}

extension CGRect {
    func point(atNormalized p: CGPoint) -> CGPoint {
        CGPoint(x: minX + p.x * width, y: minY + p.y * height)
    }

    func rect(atNormalized r: CGRect) -> CGRect {
        CGRect(x: minX + r.minX * width, y: minY + r.minY * height, width: r.width * width, height: r.height * height)
    }

    /// Converts between our top-left origin and Vision's bottom-left origin (its own inverse).
    var flippedVertically: CGRect {
        CGRect(x: minX, y: 1 - maxY, width: width, height: height)
    }
}
