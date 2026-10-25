import Foundation
import UIKit
import Matter

/// A color a bulb can be told to show: a hue/saturation pair, or a white color temperature.
enum LightColor {
    case hueSat(hue: Double, saturation: Double)   // both 0...1
    case kelvin(Double)

    static func from(_ color: UIColor) -> LightColor {
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return .hueSat(hue: Double(h), saturation: Double(s))
    }

    /// Parses "#RRGGBB" or "RRGGBB".
    static func hex(_ text: String) -> LightColor? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("#") { t.removeFirst() }
        guard t.count == 6, let value = UInt32(t, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        return from(UIColor(red: r, green: g, blue: b, alpha: 1))
    }
}

enum LightError: LocalizedError {
    case unknownBulb
    case noBulbs
    case notRunning

    var errorDescription: String? {
        switch self {
        case .unknownBulb: return "That bulb isn't set up in Switchboard."
        case .noBulbs: return "No bulbs are paired in Switchboard yet."
        case .notRunning: return "The Matter controller couldn't start."
        }
    }
}

// MARK: - Low-level commands (completion based, safe to call from the main thread)

extension MatterManager {
    /// Matter transition times are in tenths of a second, up to 65534 (about 109 minutes).
    static func deciseconds(_ seconds: Double) -> NSNumber {
        NSNumber(value: min(max(Int((seconds * 10).rounded()), 0), 65534))
    }

    /// Matter level runs 1...254; 0% maps to the dimmest level, not off.
    static func levelValue(_ percent: Double) -> NSNumber {
        let clamped = min(max(percent, 0), 100)
        return NSNumber(value: 1 + Int((clamped / 100 * 253).rounded()))
    }

    private static func valueOf(_ attribute: [String: Any]?) -> NSNumber? {
        attribute?[MTRValueKey] as? NSNumber
    }

    /// sRGB hue/saturation at full brightness converted to CIE xy, for bulbs that only do XY color.
    private static func xy(hue: Double, saturation: Double) -> (Double, Double) {
        let color = UIColor(hue: CGFloat(hue), saturation: CGFloat(saturation), brightness: 1, alpha: 1)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func linear(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v > 0.04045 ? pow((v + 0.055) / 1.055, 2.4) : v / 12.92
        }
        let lr = linear(r)
        let lg = linear(g)
        let lb = linear(b)
        let x = lr * 0.4124 + lg * 0.3576 + lb * 0.1805
        let y = lr * 0.2126 + lg * 0.7152 + lb * 0.0722
        let z = lr * 0.0193 + lg * 0.1192 + lb * 0.9505
        let sum = x + y + z
        return sum > 0 ? (x / sum, y / sum) : (0.3127, 0.3290)
    }

    func lightPower(_ nodeID: UInt64, on: Bool, completion: @escaping ((any Error)?) -> Void) {
        guard let device = devices[nodeID],
              let cluster = MTRClusterOnOff(device: device, endpointID: endpoint, queue: .main) else {
            completion(LightError.unknownBulb)
            return
        }
        if on {
            cluster.on(withExpectedValues: nil, expectedValueInterval: nil, completion: completion)
        } else {
            cluster.off(withExpectedValues: nil, expectedValueInterval: nil, completion: completion)
        }
    }

    /// Moves brightness to `percent` over `seconds`. The bulb runs the whole transition by itself.
    func lightLevel(_ nodeID: UInt64,
                    percent: Double,
                    seconds: Double,
                    withOnOff: Bool,
                    completion: @escaping ((any Error)?) -> Void) {
        guard let device = devices[nodeID],
              let cluster = MTRClusterLevelControl(device: device, endpointID: endpoint, queue: .main) else {
            completion(LightError.unknownBulb)
            return
        }
        if withOnOff {
            let params = MTRLevelControlClusterMoveToLevelWithOnOffParams()
            params.level = Self.levelValue(percent)
            params.transitionTime = Self.deciseconds(seconds)
            params.optionsMask = NSNumber(value: 1)
            params.optionsOverride = NSNumber(value: 1)
            cluster.moveToLevelWithOnOff(with: params, expectedValues: nil, expectedValueInterval: nil, completion: completion)
        } else {
            let params = MTRLevelControlClusterMoveToLevelParams()
            params.level = Self.levelValue(percent)
            params.transitionTime = Self.deciseconds(seconds)
            params.optionsMask = NSNumber(value: 1)
            params.optionsOverride = NSNumber(value: 1)
            cluster.moveToLevel(with: params, expectedValues: nil, expectedValueInterval: nil, completion: completion)
        }
    }

    func lightHueSat(_ nodeID: UInt64,
                     hue: Double,
                     saturation: Double,
                     seconds: Double,
                     completion: @escaping ((any Error)?) -> Void) {
        guard let device = devices[nodeID],
              let cluster = MTRClusterColorControl(device: device, endpointID: endpoint, queue: .main) else {
            completion(LightError.unknownBulb)
            return
        }

        // Bit 0 = hue/saturation, bit 3 = XY. Prefer hue/saturation unless the bulb only offers XY.
        var onlyXY = false
        if let caps = Self.valueOf(cluster.readAttributeColorCapabilities(with: nil)) {
            let bits = caps.intValue
            onlyXY = (bits & 0x01) == 0 && (bits & 0x08) != 0
        }

        if onlyXY {
            let (x, y) = Self.xy(hue: hue, saturation: saturation)
            let params = MTRColorControlClusterMoveToColorParams()
            params.colorX = NSNumber(value: min(max(Int((x * 65536).rounded()), 0), 65279))
            params.colorY = NSNumber(value: min(max(Int((y * 65536).rounded()), 0), 65279))
            params.transitionTime = Self.deciseconds(seconds)
            params.optionsMask = NSNumber(value: 1)
            params.optionsOverride = NSNumber(value: 1)
            cluster.moveToColor(with: params, expectedValues: nil, expectedValueInterval: nil, completion: completion)
        } else {
            let params = MTRColorControlClusterMoveToHueAndSaturationParams()
            params.hue = NSNumber(value: min(max(Int((hue * 254).rounded()), 0), 254))
            params.saturation = NSNumber(value: min(max(Int((saturation * 254).rounded()), 0), 254))
            params.transitionTime = Self.deciseconds(seconds)
            params.optionsMask = NSNumber(value: 1)
            params.optionsOverride = NSNumber(value: 1)
            cluster.moveToHueAndSaturation(with: params, expectedValues: nil, expectedValueInterval: nil, completion: completion)
        }
    }

    func lightTemperature(_ nodeID: UInt64,
                          kelvin: Double,
                          seconds: Double,
                          completion: @escaping ((any Error)?) -> Void) {
        guard let device = devices[nodeID],
              let cluster = MTRClusterColorControl(device: device, endpointID: endpoint, queue: .main) else {
            completion(LightError.unknownBulb)
            return
        }

        // Clamp to what this bulb can physically do, so "very warm" means "as warm as it goes".
        var lowest = 153.0
        var highest = 500.0
        if let v = Self.valueOf(cluster.readAttributeColorTempPhysicalMinMireds(with: nil)) { lowest = v.doubleValue }
        if let v = Self.valueOf(cluster.readAttributeColorTempPhysicalMaxMireds(with: nil)) { highest = v.doubleValue }
        if highest <= lowest {
            lowest = 153
            highest = 500
        }
        let mireds = 1_000_000 / max(kelvin, 1)

        let params = MTRColorControlClusterMoveToColorTemperatureParams()
        params.colorTemperatureMireds = NSNumber(value: Int(min(max(mireds, lowest), highest).rounded()))
        params.transitionTime = Self.deciseconds(seconds)
        params.optionsMask = NSNumber(value: 1)
        params.optionsOverride = NSNumber(value: 1)
        cluster.moveToColorTemperature(with: params, expectedValues: nil, expectedValueInterval: nil, completion: completion)
    }

    func lightColor(_ nodeID: UInt64,
                    _ color: LightColor,
                    seconds: Double,
                    completion: @escaping ((any Error)?) -> Void) {
        switch color {
        case .hueSat(let hue, let saturation):
            lightHueSat(nodeID, hue: hue, saturation: saturation, seconds: seconds, completion: completion)
        case .kelvin(let kelvin):
            lightTemperature(nodeID, kelvin: kelvin, seconds: seconds, completion: completion)
        }
    }
}

// MARK: - Async commands and effects (main actor)

extension MatterManager {
    @MainActor
    private func run(_ body: (@escaping ((any Error)?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            body { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    @MainActor
    func applyPower(_ nodeID: UInt64, on: Bool) async throws {
        try await run { done in self.lightPower(nodeID, on: on, completion: done) }
    }

    @MainActor
    func applyLevel(_ nodeID: UInt64, percent: Double, seconds: Double = 0, withOnOff: Bool = true) async throws {
        try await run { done in
            self.lightLevel(nodeID, percent: percent, seconds: seconds, withOnOff: withOnOff, completion: done)
        }
    }

    @MainActor
    func applyColor(_ nodeID: UInt64, _ color: LightColor, seconds: Double = 0) async throws {
        try await run { done in self.lightColor(nodeID, color, seconds: seconds, completion: done) }
    }

    /// Gives freshly attached bulbs a few seconds to connect, so background Shortcuts runs don't fire too early.
    @MainActor
    func waitUntilReady(_ nodeIDs: [UInt64], timeout: Double = 8) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let ready = nodeIDs.allSatisfy { devices[$0]?.deviceCachePrimed ?? true }
            if ready { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// Runs `work` for every bulb at the same time and rethrows the first failure.
    @MainActor
    func forEachBulb(_ nodeIDs: [UInt64], _ work: @escaping @MainActor (UInt64) async throws -> Void) async throws {
        let tasks = nodeIDs.map { id in
            Task { @MainActor in try await work(id) }
        }
        var firstError: Error?
        for task in tasks {
            do {
                try await task.value
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    // MARK: Effects

    /// Starts very dim and warm, then brightens (and cools slightly) over `minutes`.
    /// The ramp is a single timed command, so it keeps running if the app is closed.
    @MainActor
    func sunrise(_ nodeID: UInt64, minutes: Double) async throws {
        let seconds = min(max(minutes * 60, 1), 6500)
        try await applyLevel(nodeID, percent: 1, seconds: 0, withOnOff: true)
        // Bulbs without adjustable white just skip the color part.
        _ = try? await applyColor(nodeID, .kelvin(1000), seconds: 0)
        _ = try? await applyColor(nodeID, .kelvin(4000), seconds: seconds)
        try await applyLevel(nodeID, percent: 100, seconds: seconds, withOnOff: true)
    }

    @MainActor
    func setBrightness(_ nodeID: UInt64, percent: Double, seconds: Double) async throws {
        if percent <= 0 {
            try await applyPower(nodeID, on: false)
        } else {
            try await applyLevel(nodeID, percent: percent, seconds: seconds, withOnOff: true)
        }
    }

    @MainActor
    func setColor(_ nodeID: UInt64, color: LightColor, seconds: Double) async throws {
        try await applyColor(nodeID, color, seconds: seconds)
        try await applyPower(nodeID, on: true)
    }

    @MainActor
    func fadeBrightness(_ nodeID: UInt64, from: Double, to: Double, seconds: Double) async throws {
        try await applyLevel(nodeID, percent: from, seconds: 0, withOnOff: true)
        try await applyLevel(nodeID, percent: to, seconds: seconds, withOnOff: true)
    }

    @MainActor
    func fadeColor(_ nodeID: UInt64, from: LightColor, to: LightColor, seconds: Double) async throws {
        try await applyColor(nodeID, from, seconds: 0)
        try await applyPower(nodeID, on: true)
        try await applyColor(nodeID, to, seconds: seconds)
    }
}
