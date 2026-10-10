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
}
