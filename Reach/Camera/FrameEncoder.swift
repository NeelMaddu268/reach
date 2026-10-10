import CoreImage
import ImageIO

enum FrameEncoder {
    private static let context = CIContext()

    /// JPEG of a (portrait) camera frame, for sending to Gemini or Claude.
    static func jpeg(_ buffer: CVPixelBuffer, quality: CGFloat = 0.7) -> Data? {
        context.jpegRepresentation(of: CIImage(cvPixelBuffer: buffer),
                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality])
    }
}
