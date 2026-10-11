import ARKit

/// An object pinned to the table in world space. ARKit tracks how the phone moves, so projecting the pin
/// into each new frame keeps the box on the object. (A 2D image tracker drifts whenever the phone moves.)
struct ObjectAnchor {
    /// The box's corners, cast onto the table plane (world space).
    let corners: [simd_float3]
    /// Height of the table surface (world y).
    let tableY: Float
    /// Height of the object's top (world y), refined from LiDAR depth while the hand is away from it.
    var topY: Float

    /// Middle of the object's footprint on the table.
    var center: simd_float3 { corners.reduce(.zero, +) / Float(corners.count) }

    /// Half the footprint's size along the user's right and forward directions (meters).
    func halfExtents(right: simd_float3, forward: simd_float3) -> (right: Double, forward: Double) {
        let offsets = corners.map { $0 - center }
        return (Double(offsets.map { abs(simd_dot($0, right)) }.max() ?? 0),
                Double(offsets.map { abs(simd_dot($0, forward)) }.max() ?? 0))
    }

    /// Pins `box` (normalized portrait image coordinates) as seen in `geometry`'s frame, which may be an earlier one,
    /// e.g. the photo Gemini looked at. The table's height comes from LiDAR just around the box (falling back to an
    /// ARKit raycast), the object's top from LiDAR at its middle. Nil if neither can place the table yet.
    init?(box: CGRect, seenIn geometry: FrameGeometry, session: ARSession) {
        let camera = geometry.camera
        var table: Float?
        var top: Float?
        if geometry.hasDepth {
            // A ring just outside the box is the table the object stands on; the median shrugs off a neighbor or the edge.
            let ring = (0..<12).compactMap { step -> Float? in
                let angle = Double(step) / 12 * 2 * .pi
                let p = CGPoint(x: box.midX + cos(angle) * box.width * 0.65, y: box.midY + sin(angle) * box.height * 0.65)
                return geometry.surfacePoint(at: p)?.y
            }.sorted()
            if ring.count >= 4 { table = ring[ring.count / 2] }
            top = geometry.surfacePoint(at: CGPoint(x: box.midX, y: box.midY))?.y
        }
        guard let tableY = table ?? Self.raycastTable(under: box, camera: camera, session: session) else { return nil }

        let size = Self.viewport(camera)
        let plane = Self.horizontalPlane(at: tableY)
        let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                       CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)].compactMap {
            camera.unprojectPoint(CGPoint(x: $0.x * size.width, y: $0.y * size.height), ontoPlane: plane,
                                  orientation: .portrait, viewportSize: size)
        }
        guard corners.count == 4 else { return nil }
        self.corners = corners
        self.tableY = tableY
        topY = min(max(top ?? tableY + 0.01, tableY), tableY + 0.4)  // objects on a table: 0–40 cm tall
    }

    /// Without depth: an ARKit raycast along the line of sight through the box center, from `camera`'s pose.
    private static func raycastTable(under box: CGRect, camera: ARCamera, session: ARSession) -> Float? {
        let size = viewport(camera)
        let origin = simd_make_float3(camera.transform.columns.3)
        let center = CGPoint(x: box.midX * size.width, y: box.midY * size.height)
        guard let below = camera.unprojectPoint(center, ontoPlane: horizontalPlane(at: origin.y - 1),
                                                orientation: .portrait, viewportSize: size) else { return nil }
        let direction = simd_normalize(below - origin)
        for target in [ARRaycastQuery.Target.estimatedPlane, .existingPlaneInfinite] {
            let query = ARRaycastQuery(origin: origin, direction: direction, allowing: target, alignment: .horizontal)
            if let hit = session.raycast(query).first { return hit.worldTransform.columns.3.y }
        }
        return nil
    }

    /// The pinned box in the frame `camera` sees (normalized portrait image coordinates), or nil if it's behind the camera.
    func box(in camera: ARCamera) -> CGRect? {
        let size = Self.viewport(camera)
        let worldToCamera = camera.transform.inverse
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for corner in corners {
            guard (worldToCamera * simd_float4(corner, 1)).z < 0 else { return nil }  // the camera looks down -z
            let p = camera.projectPoint(corner, orientation: .portrait, viewportSize: size)
            minX = min(minX, p.x / size.width)
            maxX = max(maxX, p.x / size.width)
            minY = min(minY, p.y / size.height)
            maxY = max(maxY, p.y / size.height)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The portrait frame size in pixels (camera frames are landscape).
    private static func viewport(_ camera: ARCamera) -> CGSize {
        CGSize(width: camera.imageResolution.height, height: camera.imageResolution.width)
    }

    /// A horizontal plane at height `y`: unprojectPoint uses the transform's x-z plane.
    private static func horizontalPlane(at y: Float) -> simd_float4x4 {
        var transform = matrix_identity_float4x4
        transform.columns.3.y = y
        return transform
    }
}
