import CoreGraphics

/// Image space: normalized [0, 1], origin top-left, in the upright (portrait) camera frame.
enum ImageSpace {
    /// Width / height of the portrait frame. Set from the camera format before the UI first draws.
    static var aspect: CGFloat = 3.0 / 4.0

    /// Where the whole frame fits inside a view of `size`: the preview's frame, and the overlay's mapping.
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
}
