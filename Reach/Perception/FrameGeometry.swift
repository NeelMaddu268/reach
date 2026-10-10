import ARKit

/// One frame's 3D view of the table: turns portrait image points into world points using LiDAR depth
/// or the table plane. World y is up (gravity).
struct FrameGeometry {
    let camera: ARCamera
    private let depth: ARDepthData?
    /// Portrait-normalized → landscape-normalized (the depth map's orientation).
    private let toLandscape: CGAffineTransform
    /// Portrait frame size in pixels: the viewport for ARKit's projection calls.
    private let viewport: CGSize

    init(frame: ARFrame) {
        camera = frame.camera
        depth = frame.smoothedSceneDepth ?? frame.sceneDepth
        viewport = CGSize(width: frame.camera.imageResolution.height, height: frame.camera.imageResolution.width)
        toLandscape = frame.displayTransform(for: .portrait, viewportSize: viewport).inverted()
    }

    var hasDepth: Bool { depth != nil }

    /// A portrait image point in the camera's native landscape coordinates (also used for focus points).
    func landscapePoint(_ p: CGPoint) -> CGPoint {
        p.applying(toLandscape)
    }

    /// The 3D point at image point `p`, at the LiDAR depth read around `depthAt` (defaults to `p`).
    /// `percentile` picks from the depths around that point: low = nearest surface (a finger over the table).
    func point(at p: CGPoint, depthAt: CGPoint? = nil, percentile: Double = 0.25) -> simd_float3? {
        guard let distance = depth(at: depthAt ?? p, percentile: percentile) else { return nil }
        // A plane facing the camera at that distance: its normal (the transform's y axis) along the view axis.
        let plane = camera.transform * Self.translation(0, 0, -distance) * Self.quarterTurnX
        return unproject(p, onto: plane)
    }

    /// Where the ray through image point `p` meets the horizontal plane at height `y`.
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

    private func unproject(_ p: CGPoint, onto plane: simd_float4x4) -> simd_float3? {
        camera.unprojectPoint(CGPoint(x: p.x * viewport.width, y: p.y * viewport.height), ontoPlane: plane,
                              orientation: .portrait, viewportSize: viewport)
    }

    /// Depth in meters around a portrait image point: a percentile of the confident readings in a 5×5 patch.
    private func depth(at p: CGPoint, percentile: Double) -> Float? {
        guard let depth else { return nil }
        let map = depth.depthMap
        let q = landscapePoint(p)
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        let cx = Int(q.x * CGFloat(width)), cy = Int(q.y * CGFloat(height))
        guard (0..<width).contains(cx), (0..<height).contains(cy), let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(map)

        var confidence: (base: UnsafeMutableRawPointer, rowBytes: Int)?
        if let map = depth.confidenceMap {
            CVPixelBufferLockBaseAddress(map, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(map) { confidence = (base, CVPixelBufferGetBytesPerRow(map)) }
        }
        defer { if let map = depth.confidenceMap { CVPixelBufferUnlockBaseAddress(map, .readOnly) } }

        var values: [Float] = []
        for y in max(0, cy - 2)...min(height - 1, cy + 2) {
            for x in max(0, cx - 2)...min(width - 1, cx + 2) {
                if let confidence, confidence.base.load(fromByteOffset: y * confidence.rowBytes + x, as: UInt8.self) < UInt8(ARConfidenceLevel.medium.rawValue) {
                    continue
                }
                let value = base.load(fromByteOffset: y * rowBytes + x * MemoryLayout<Float32>.size, as: Float32.self)
                if value > 0 { values.append(value) }
            }
        }
        guard !values.isEmpty else { return nil }
        values.sort()
        return values[Int(Double(values.count - 1) * percentile)]
    }

    static func translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        var transform = matrix_identity_float4x4
        transform.columns.3 = simd_float4(x, y, z, 1)
        return transform
    }

    /// Rotates a transform's y axis onto its z axis.
    private static let quarterTurnX = simd_float4x4(simd_quatf(angle: .pi / 2, axis: simd_float3(1, 0, 0)))
}
