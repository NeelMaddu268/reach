import CoreImage
import ImageIO

enum FrameEncoder {
    private static let context = CIContext()

    /// Upright (portrait) JPEG of a landscape camera frame, at most `width` pixels wide, for Gemini or Claude.
    static func jpeg(_ buffer: CVPixelBuffer, width: CGFloat = 1080, quality: CGFloat = 0.7) -> Data? {
        var image = CIImage(cvPixelBuffer: buffer).oriented(.right)
        let scale = width / image.extent.width
        if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        return context.jpegRepresentation(of: image,
                                          colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality])
    }

    /// The part of an upright JPEG inside `box` (normalized, origin top-left), plus a margin, as a JPEG.
    static func crop(_ jpeg: Data, to box: CGRect, margin: CGFloat = 0.15) -> Data? {
        guard let image = CIImage(data: jpeg) else { return nil }
        let unit = box.insetBy(dx: -box.width * margin, dy: -box.height * margin)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !unit.isNull else { return nil }
        let size = image.extent.size  // Core Image's origin is bottom-left
        let rect = CGRect(x: unit.minX * size.width, y: (1 - unit.maxY) * size.height,
                          width: unit.width * size.width, height: unit.height * size.height)
        return context.jpegRepresentation(of: image.cropped(to: rect), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8])
    }
}
