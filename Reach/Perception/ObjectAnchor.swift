import ARKit

/// An object pinned to the table in world space. ARKit tracks how the phone moves, so projecting the pin
/// into each new frame keeps the box on the object. (A 2D image tracker drifts whenever the phone moves.)
struct ObjectAnchor {
    /// The box's corners, cast onto the table plane (world space).
    private let corners: [simd_float3]

    /// Pins `box` (normalized portrait image coordinates) as seen by `camera`, which may be from an earlier
    /// frame, e.g. the photo Gemini looked at. Nil if ARKit can't find the table under the box yet.
    init?(box: CGRect, seenBy camera: ARCamera, session: ARSession) {
        let size = Self.viewport(camera)
        let origin = simd_make_float3(camera.transform.columns.3)
        // The ray through the box center: unproject onto a plane 1 m below the camera to get its direction.
        let center = CGPoint(x: box.midX * size.width, y: box.midY * size.height)
        guard let below = camera.unprojectPoint(center, ontoPlane: Self.horizontalPlane(at: origin.y - 1),
                                                orientation: .portrait, viewportSize: size) else { return nil }
        let direction = simd_normalize(below - origin)

        var hit: ARRaycastResult?
        for target in [ARRaycastQuery.Target.estimatedPlane, .existingPlaneInfinite] where hit == nil {
            let query = ARRaycastQuery(origin: origin, direction: direction, allowing: target, alignment: .horizontal)
            hit = session.raycast(query).first
        }
        guard let hit else { return nil }

        let table = Self.horizontalPlane(at: hit.worldTransform.columns.3.y)
        let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                       CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)].compactMap {
            camera.unprojectPoint(CGPoint(x: $0.x * size.width, y: $0.y * size.height), ontoPlane: table,
                                  orientation: .portrait, viewportSize: size)
        }
        guard corners.count == 4 else { return nil }
        self.corners = corners
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
