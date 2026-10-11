import ARKit

/// One frame's 3D view of the table: turns portrait image points into world points using LiDAR depth
/// or a horizontal plane. World y is up (gravity).
struct FrameGeometry {
    let camera: ARCamera
    /// This frame's LiDAR depth (for the moving hand) and the temporally smoothed one (for still objects and the table).
    private let rawDepth: ARDepthData?
    private let smoothDepth: ARDepthData?
    /// Portrait-normalized → landscape-normalized (the depth map's orientation).
    private let toLandscape: CGAffineTransform
    /// Portrait frame size in pixels: the viewport for ARKit's projection calls.
    private let viewport: CGSize

    init(frame: ARFrame) {
        camera = frame.camera
        rawDepth = frame.sceneDepth ?? frame.smoothedSceneDepth
        smoothDepth = frame.smoothedSceneDepth ?? frame.sceneDepth
        viewport = CGSize(width: frame.camera.imageResolution.height, height: frame.camera.imageResolution.width)
        toLandscape = frame.displayTransform(for: .portrait, viewportSize: viewport).inverted()
    }

    var hasDepth: Bool { smoothDepth != nil }

    /// A portrait image point in the camera's native landscape coordinates (also used for focus points).
    func landscapePoint(_ p: CGPoint) -> CGPoint {
        p.applying(toLandscape)
    }

    /// The still surface (table or object) at image point `p`: the median of the confident smoothed LiDAR readings
    /// in a 5×5 patch. Nil without enough of them.
    func surfacePoint(at p: CGPoint) -> simd_float3? {
        let values = samples(smoothDepth, at: p, radius: 2, minimum: .medium).sorted()
        guard values.count >= 5 else { return nil }
        return point(at: p, distance: values[values.count / 2])
    }

    /// How far the finger is from the camera along its axis (meters): the median of this frame's high-confidence
    /// LiDAR readings along the finger, from the tip back to the pad. Nil unless enough of them agree to trust.
    /// (A fingertip covers only a pixel or two of the depth map, so single readings land on the table or knuckles.)
    func fingerDepth(tip: CGPoint, pad: CGPoint) -> Float? {
        var values: [Float] = []
        for step in 0...4 {
            let t = CGFloat(step) / 4
            values += samples(rawDepth, at: CGPoint(x: tip.x + (pad.x - tip.x) * t, y: tip.y + (pad.y - tip.y) * t),
                              radius: 1, minimum: .high)
        }
        guard values.count >= 6 else { return nil }
        values.sort()
        return values[values.count / 2]
    }

    /// Camera-axis depth of where the line of sight through `p` meets the horizontal plane at height `y`.
    func depthOnPlane(at p: CGPoint, y: Float) -> Float? {
        guard let world = point(at: p, onPlaneAt: y) else { return nil }
        return -(camera.transform.inverse * simd_float4(world, 1)).z  // the camera looks down -z
    }

    /// Where the line of sight through image point `p` meets the horizontal plane at height `y`.
    func point(at p: CGPoint, onPlaneAt y: Float) -> simd_float3? {
        unproject(p, onto: Self.translation(0, y, 0))
    }

    /// The user's right and forward directions on the table (horizontal, unit length), taken from the image:
    /// up the middle of the frame is forward.
    func axes(onPlaneAt y: Float) -> (right: simd_float3, forward: simd_float3)? {
        guard let near = point(at: CGPoint(x: 0.5, y: 0.6), onPlaneAt: y),
              let far = point(at: CGPoint(x: 0.5, y: 0.4), onPlaneAt: y) else { return nil }
        var forward = far - near
        forward.y = 0
        guard simd_length(forward) > 1e-4 else { return nil }
        forward = simd_normalize(forward)
        return (simd_cross(forward, simd_float3(0, 1, 0)), forward)
    }

    /// The point at image point `p`, `distance` meters along the camera axis.
    private func point(at p: CGPoint, distance: Float) -> simd_float3? {
        // A plane facing the camera at that distance: its normal (the transform's y axis) along the view axis.
        unproject(p, onto: camera.transform * Self.translation(0, 0, -distance) * Self.quarterTurnX)
    }

    private func unproject(_ p: CGPoint, onto plane: simd_float4x4) -> simd_float3? {
        camera.unprojectPoint(CGPoint(x: p.x * viewport.width, y: p.y * viewport.height), ontoPlane: plane,
                              orientation: .portrait, viewportSize: viewport)
    }

    /// Depth readings (meters) in a (2·radius+1)² patch around a portrait image point, at or above `minimum` confidence.
    private func samples(_ depth: ARDepthData?, at p: CGPoint, radius: Int, minimum: ARConfidenceLevel) -> [Float] {
        guard let depth else { return [] }
        let map = depth.depthMap
        let q = landscapePoint(p)
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        let cx = Int(q.x * CGFloat(width)), cy = Int(q.y * CGFloat(height))
        guard (0..<width).contains(cx), (0..<height).contains(cy), let base = CVPixelBufferGetBaseAddress(map) else { return [] }
        let rowBytes = CVPixelBufferGetBytesPerRow(map)

        var confidence: (base: UnsafeMutableRawPointer, rowBytes: Int)?
        if let map = depth.confidenceMap {
            CVPixelBufferLockBaseAddress(map, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(map) { confidence = (base, CVPixelBufferGetBytesPerRow(map)) }
        }
        defer { if let map = depth.confidenceMap { CVPixelBufferUnlockBaseAddress(map, .readOnly) } }

        var values: [Float] = []
        for y in max(0, cy - radius)...min(height - 1, cy + radius) {
            for x in max(0, cx - radius)...min(width - 1, cx + radius) {
                if let confidence, confidence.base.load(fromByteOffset: y * confidence.rowBytes + x, as: UInt8.self) < UInt8(minimum.rawValue) {
                    continue
                }
                let value = base.load(fromByteOffset: y * rowBytes + x * MemoryLayout<Float32>.size, as: Float32.self)
                if value > 0 { values.append(value) }
            }
        }
        return values
    }

    static func translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        var transform = matrix_identity_float4x4
        transform.columns.3 = simd_float4(x, y, z, 1)
        return transform
    }

    /// Rotates a transform's y axis onto its z axis.
    private static let quarterTurnX = simd_float4x4(simd_quatf(angle: .pi / 2, axis: simd_float3(1, 0, 0)))
}
