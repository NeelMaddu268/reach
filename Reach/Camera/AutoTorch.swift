import CoreGraphics
import Foundation

/// Turns the flashlight on in a dark room and off again once the room is bright. The torch itself brightens
/// ARKit's light estimate, so its contribution is measured once it's on and subtracted (otherwise it would flicker).
struct AutoTorch {
    /// ARKit ambient intensity (lumens; ~1000 is a well-lit room).
    static let dark: CGFloat = 250
    static let bright: CGFloat = 600

    private(set) var isOn = false
    /// When the current dark (or bright) reading started.
    private var since: TimeInterval?
    private var lightBefore: CGFloat = 0
    private var torchBoost: CGFloat?
    private var onAt: TimeInterval = 0

    /// Returns true / false when the torch should switch on / off, nil to leave it.
    mutating func update(light: CGFloat?, enabled: Bool, time: TimeInterval) -> Bool? {
        guard enabled, let light else {
            guard isOn else { return nil }
            isOn = false
            since = nil
            return false
        }
        if !isOn {
            guard light < Self.dark else {
                since = nil
                return nil
            }
            since = since ?? time
            guard time - since! > 1 else { return nil }
            isOn = true
            since = nil
            lightBefore = light
            torchBoost = nil
            onAt = time
            return true
        }
        if torchBoost == nil, time - onAt > 0.7 { torchBoost = max(0, light - lightBefore) }
        let room = light - (torchBoost ?? .infinity)  // until measured, assume it's all torch
        guard room > Self.bright else {
            since = nil
            return nil
        }
        since = since ?? time
        guard time - since! > 2 else { return nil }
        isOn = false
        since = nil
        return false
    }
}
