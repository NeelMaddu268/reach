import ARKit

/// An object pinned to the table in world space. ARKit tracks how the phone moves, so projecting the pin
/// into each new frame keeps the box on the object. (A 2D image tracker drifts whenever the phone moves.)
struct ObjectAnchor {
    /// The box's corners (world space): the bottom two cast onto the table, the top two (the far rim of the object's
    /// top) at its top as measured when pinned.
    let corners: [simd_float3]
    /// Height of the table surface (world y).
    let tableY: Float
    /// Height of the object's top (world y), refined from LiDAR depth while the hand is away from it.
    var topY: Float
    /// The top as LiDAR measured it when pinned; nil without a reading. Careful guidance keeps refinement near it.
    let measuredTopY: Float?

    /// Middle of the object's footprint, seen from above (its x and z; the corners sit at two heights).
    var center: simd_float3 { corners.reduce(.zero, +) / Float(corners.count) }

    /// Half the footprint's size along the user's right and forward directions (meters).
    func halfExtents(right: simd_float3, forward: simd_float3) -> (right: Double, forward: Double) {
        let offsets = corners.map { $0 - center }
        return (Double(offsets.map { abs(simd_dot($0, right)) }.max() ?? 0),
                Double(offsets.map { abs(simd_dot($0, forward)) }.max() ?? 0))
    }

    /// Pins `box` (normalized portrait image coordinates) as seen in `geometry`'s frame, which may be an earlier one,
    /// e.g. the photo Gemini looked at. The table's height comes from LiDAR just around the box (falling back to an
    /// ARKit raycast), the object's top from LiDAR down the upper half of its middle. Nil if neither can place the
    /// table yet.
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
            top = geometry.topPoint(in: box)?.y
        }
        guard let tableY = table ?? Self.raycastTable(under: box, camera: camera, session: session) else { return nil }
        let topY = min(max(top ?? tableY + 0.01, tableY), tableY + 0.4)  // objects on a table: 0–40 cm tall

        // The box's bottom edge is where the object stands on the table. Its top edge is the far rim of the object's top,
        // so those corners are cast at the top's height: on the table they'd land far behind anything tall. A rim that
        // can't be cast, or lands nearer than the bottom edge (the top read high: a hand over the box), goes on the table.
        let size = Self.viewport(camera)
        func cast(_ x: CGFloat, _ y: CGFloat, at height: Float) -> simd_float3? {
            camera.unprojectPoint(CGPoint(x: x * size.width, y: y * size.height),
                                  ontoPlane: Self.horizontalPlane(at: height), orientation: .portrait, viewportSize: size)
        }
        let sides = [box.minX, box.maxX].compactMap { x -> (rim: simd_float3, bottom: simd_float3)? in
            guard let bottom = cast(x, box.maxY, at: tableY), let behind = cast(x, box.minY, at: tableY) else { return nil }
            guard let rim = cast(x, box.minY, at: topY), simd_dot(rim - bottom, behind - bottom) >= 0 else {
                return (behind, bottom)
            }
            return (rim, bottom)
        }
        guard sides.count == 2 else { return nil }
        corners = [sides[0].rim, sides[1].rim, sides[1].bottom, sides[0].bottom]
        self.tableY = tableY
        self.topY = topY
        measuredTopY = top.map { min(max($0, tableY), tableY + 0.4) }
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
