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

    /// Hue and saturation (0...1) for blending. White temperatures are approximated with their RGB color.
    var hueSaturation: (hue: Double, saturation: Double) {
        switch self {
        case .hueSat(let hue, let saturation):
            return (hue, saturation)
        case .kelvin(let kelvin):
            let rgb = LightColor.rgb(forKelvin: kelvin)
            var h: CGFloat = 0
            var s: CGFloat = 0
            var b: CGFloat = 0
            var a: CGFloat = 0
            UIColor(red: CGFloat(rgb.0), green: CGFloat(rgb.1), blue: CGFloat(rgb.2), alpha: 1)
                .getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return (Double(h), Double(s))
        }
    }

    /// Approximate RGB (0...1) of a black-body white, good enough for blending.
    static func rgb(forKelvin kelvin: Double) -> (Double, Double, Double) {
        let t = min(max(kelvin, 1000), 40000) / 100
        let red = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
        let green = t <= 66
            ? 99.4708025861 * log(t) - 161.1195681661
            : 288.1221695283 * pow(t - 60, -0.0755148492)
        let blue: Double
        if t >= 66 {
            blue = 255
        } else if t <= 19 {
            blue = 0
        } else {
            blue = 138.5177312231 * log(t - 10) - 305.0447927307
        }
        func unit(_ v: Double) -> Double { min(max(v, 0), 255) / 255 }
        return (unit(red), unit(green), unit(blue))
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
    func applyLevel(_ nodeID: UInt64, percent: Double, seconds: Double = 0, withOnOff: Bool = false) async throws {
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

    // MARK: Effect bookkeeping

    /// Cancels any fade running on these bulbs.
    func stopEffects(_ nodeIDs: [UInt64]) {
        for id in nodeIDs {
            effectGeneration[id, default: 0] += 1
        }
    }

    func beginEffect(_ nodeID: UInt64) -> Int {
        let next = (effectGeneration[nodeID] ?? 0) + 1
        effectGeneration[nodeID] = next
        return next
    }

    func holdScreenAwake() {
        awakeCount += 1
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func releaseScreenAwake() {
        awakeCount = max(0, awakeCount - 1)
        if awakeCount == 0 {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    // MARK: Effects

    /// Sets brightness instantly (0 turns the bulb off).
    @MainActor
    func setBrightness(_ nodeID: UInt64, percent: Double) async throws {
        stopEffects([nodeID])
        if percent <= 0 {
            try await applyPower(nodeID, on: false)
        } else {
            try await applyLevel(nodeID, percent: percent, seconds: 0, withOnOff: false)
            try await applyPower(nodeID, on: true)
        }
    }

    @MainActor
    func setColor(_ nodeID: UInt64, color: LightColor) async throws {
        stopEffects([nodeID])
        try await applyColor(nodeID, color, seconds: 0)
        try await applyPower(nodeID, on: true)
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
    }

    // MARK: Fade engine

    func latency(_ nodeID: UInt64, kind: String) -> Double {
        commandLatency["\(nodeID).\(kind)"] ?? (kind == "level" ? 0.10 : 0.045)
    }

    func recordLatency(_ nodeID: UInt64, kind: String, seconds: Double) {
        let key = "\(nodeID).\(kind)"
        let old = commandLatency[key] ?? seconds
        commandLatency[key] = old * 0.8 + seconds * 0.2
    }

    func colorSupportsXY(_ nodeID: UInt64) -> Bool {
        guard let device = devices[nodeID],
              let cluster = MTRClusterColorControl(device: device, endpointID: endpoint, queue: .main),
              let caps = Self.valueOf(cluster.readAttributeColorCapabilities(with: nil)) else { return false }
        return (caps.intValue & 0x08) != 0
    }

    func lightXY(_ nodeID: UInt64,
                 x: Double,
                 y: Double,
                 seconds: Double,
                 completion: @escaping ((any Error)?) -> Void) {
        guard let device = devices[nodeID],
              let cluster = MTRClusterColorControl(device: device, endpointID: endpoint, queue: .main) else {
            completion(LightError.unknownBulb)
            return
        }
        let params = MTRColorControlClusterMoveToColorParams()
        params.colorX = NSNumber(value: min(max(Int((x * 65536).rounded()), 0), 65279))
        params.colorY = NSNumber(value: min(max(Int((y * 65536).rounded()), 0), 65279))
        params.transitionTime = Self.deciseconds(seconds)
        params.optionsMask = NSNumber(value: 1)
        params.optionsOverride = NSNumber(value: 1)
        cluster.moveToColor(with: params, expectedValues: nil, expectedValueInterval: nil, completion: completion)
    }

    /// Drives one fade on a clock. Each tick it works out where the fade will be by the time the command
    /// has reached the bulb (half the measured round trip) plus the bulb's own glide, sends that, and
    /// never waits for the answer, so slow replies can't stall the motion. At most two commands per bulb
    /// are in flight; ticks beyond that are skipped and the next one carries the newest value.
    /// `send(time, done)` returns false when the new value is identical to the last one (nothing sent).
    @MainActor
    private func runFade(_ nodeID: UInt64,
                         generation: Int,
                         duration: Double,
                         tick: Double,
                         kind: String,
                         counters: FadeCounters,
                         send: (_ time: Double, _ done: @escaping ((any Error)?) -> Void) -> Bool) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        var nextTick = start
        var lastPublish = -1.0
        defer { fadeProgress[nodeID] = nil }
        while true {
            guard effectGeneration[nodeID] == generation else { throw CancellationError() }
            let elapsed = Self.seconds(start.duration(to: clock.now))
            if elapsed >= duration { break }
            if counters.consecutiveFailures >= 5, let error = counters.lastError { throw error }
            if elapsed - lastPublish >= 0.2 {
                lastPublish = elapsed
                fadeProgress[nodeID] = elapsed / duration
            }
            if counters.inFlight < 2 {
                let began = clock.now
                let lead = latency(nodeID, kind: kind) / 2
                counters.inFlight += 1
                let issued = send(elapsed + lead) { [self] error in
                    counters.inFlight -= 1
                    if let error {
                        counters.failed += 1
                        counters.consecutiveFailures += 1
                        counters.lastError = error
                        if counters.failed <= 3 {
                            logActivity("  command failed: \(Self.describe(error))")
                        }
                    } else {
                        counters.succeeded += 1
                        counters.consecutiveFailures = 0
                        let rtt = Self.seconds(began.duration(to: clock.now))
                        counters.totalRTT += rtt
                        recordLatency(nodeID, kind: kind, seconds: rtt)
                    }
                }
                if issued {
                    counters.sent += 1
                } else {
                    counters.inFlight -= 1
                }
            } else {
                counters.skipped += 1
            }
            nextTick = nextTick.advanced(by: .seconds(tick))
            let now = clock.now
            if nextTick < now { nextTick = now }
            try await clock.sleep(until: nextTick)
        }
    }

    private func logFadeSummary(_ name: String, _ counters: FadeCounters, nodeID: UInt64, kind: String) {
        let average = counters.succeeded > 0 ? Int(counters.totalRTT / Double(counters.succeeded) * 1000) : 0
        logActivity("\(name) finished: \(counters.sent) commands, \(counters.failed) failed, \(counters.skipped) ticks skipped while waiting, average reply \(average) ms, learned delay \(Int(latency(nodeID, kind: kind) * 1000)) ms")
    }

    /// Fades brightness through every level the bulb has (about 2.5 per percent, so finer than 1% steps).
    /// Each command glides for about the time until the next level change, and is sent early by the bulb's
    /// measured delay so the motion lands on time.
    @MainActor
    func fadeBrightness(_ nodeID: UInt64, from: Double, to: Double, seconds: Double) async throws {
        let startPercent = min(max(from, 1), 100)
        let endPercent = min(max(to, 1), 100)
        let duration = min(max(seconds, 0.5), 7200)
        let generation = beginEffect(nodeID)
        holdScreenAwake()
        defer { releaseScreenAwake() }

        let span = endPercent - startPercent
        let levels = max(1, Int((abs(span) / 100 * 253).rounded()))
        let glide = min(max(duration / Double(levels), 0.1), 3.0)
        let tick = 0.06
        logActivity("Brightness fade \(Int(startPercent))% to \(Int(endPercent))% over \(Int(duration)) s: \(levels) level changes, glide \(String(format: "%.1f", glide)) s, aiming \(Int(latency(nodeID, kind: "level") * 500)) ms ahead")

        try await applyLevel(nodeID, percent: startPercent, seconds: 0, withOnOff: startPercent > 1)
        if startPercent <= 1 { try await applyPower(nodeID, on: true) }
        guard abs(span) >= 0.5 else { return }

        let counters = FadeCounters()
        var lastRaw = Self.levelValue(startPercent).intValue
        try await runFade(nodeID, generation: generation, duration: duration, tick: tick, kind: "level", counters: counters) { time, done in
            let t = min(duration, time + glide)
            let value = startPercent + span * t / duration
            let raw = MatterManager.levelValue(value).intValue
            if raw == lastRaw { return false }
            lastRaw = raw
            self.lightLevel(nodeID, percent: value, seconds: glide, withOnOff: value > 1, completion: done)
            return true
        }

        // Land exactly on the target, retrying once if that last command is dropped.
        do {
            try await applyLevel(nodeID, percent: endPercent, seconds: 0, withOnOff: endPercent > 1)
        } catch {
            try await applyLevel(nodeID, percent: endPercent, seconds: 0, withOnOff: endPercent > 1)
        }
        logFadeSummary("Brightness fade", counters, nodeID: nodeID, kind: "level")
    }

    /// Fades between two colors with up to about 20 tiny steps per second. Where the bulb supports CIE xy
    /// color it uses that (65,000 values per axis instead of 254, so no visible banding); otherwise it
    /// falls back to hue and saturation. The path follows the shortest way round the color wheel.
    @MainActor
    func fadeColor(_ nodeID: UInt64, from: LightColor, to: LightColor, seconds: Double) async throws {
        let duration = min(max(seconds, 0.5), 7200)
        let generation = beginEffect(nodeID)
        holdScreenAwake()
        defer { releaseScreenAwake() }

        var a = from.hueSaturation
        var b = to.hueSaturation
        // A white has no real hue, so borrow the other end's hue and only change saturation.
        if a.saturation < 0.05 { a.hue = b.hue }
        if b.saturation < 0.05 { b.hue = a.hue }
        var hueDelta = b.hue - a.hue
        if hueDelta > 0.5 { hueDelta -= 1 }
        if hueDelta < -0.5 { hueDelta += 1 }
        let saturationDelta = b.saturation - a.saturation
        let startHue = a.hue
        let startSaturation = a.saturation

        let state = ColorFadeState()
        state.xy = colorSupportsXY(nodeID)
        let glide = 0.1
        let tick = 0.05
        logActivity("Color fade over \(Int(duration)) s: \(state.xy ? "fine xy color" : "hue and saturation") steps, hue change \(Int(abs(hueDelta) * 360))°, aiming \(Int(latency(nodeID, kind: "color") * 500)) ms ahead")

        try await applyColor(nodeID, from, seconds: 0)
        try await applyPower(nodeID, on: true)

        let counters = FadeCounters()
        try await runFade(nodeID, generation: generation, duration: duration, tick: tick, kind: "color", counters: counters) { time, done in
            let t = min(duration, time + glide)
            let progress = t / duration
            var hue = (startHue + hueDelta * progress).truncatingRemainder(dividingBy: 1)
            if hue < 0 { hue += 1 }
            let saturation = min(max(startSaturation + saturationDelta * progress, 0), 1)

            // If the very first xy commands are refused, switch to hue/saturation for the rest of the fade.
            if state.xy && counters.succeeded == 0 && counters.consecutiveFailures >= 3 {
                state.xy = false
                state.lastA = -1
                state.lastB = -1
                counters.consecutiveFailures = 0
                self.logActivity("  xy color refused, switching to hue and saturation")
            }
            if state.xy {
                let (x, y) = MatterManager.xy(hue: hue, saturation: saturation)
                let kx = Int((x * 65536).rounded())
                let ky = Int((y * 65536).rounded())
                if kx == state.lastA && ky == state.lastB { return false }
                state.lastA = kx
                state.lastB = ky
                self.lightXY(nodeID, x: x, y: y, seconds: glide, completion: done)
            } else {
                let kh = Int((hue * 254).rounded())
                let ks = Int((saturation * 254).rounded())
                if kh == state.lastA && ks == state.lastB { return false }
                state.lastA = kh
                state.lastB = ks
                self.lightHueSat(nodeID, hue: hue, saturation: saturation, seconds: glide, completion: done)
            }
            return true
        }

        // Finish on the exact target; a white ends on the bulb's real white LEDs.
        do {
            try await applyColor(nodeID, to, seconds: 0)
        } catch {
            try await applyColor(nodeID, to, seconds: 0)
        }
        logFadeSummary("Color fade", counters, nodeID: nodeID, kind: "color")
    }

    // MARK: Bulb report

    private static func listOfNumbers(_ attribute: [String: Any]?) -> [Int]? {
        guard let items = attribute?[MTRValueKey] as? [[String: Any]] else { return nil }
        return items.compactMap { item in
            (item[MTRDataKey] as? [String: Any])?[MTRValueKey] as? NSNumber
        }.map { $0.intValue }
    }

    /// Reads what the bulb itself says it can do, so we know which built-in transitions it offers.
    func bulbReport(_ nodeID: UInt64) -> [String] {
        guard let device = devices[nodeID] else { return ["Unknown bulb."] }
        var lines = ["Bulb report (node \(nodeID), \(device.state == .reachable ? "reachable" : "not reachable"), cache \(device.deviceCachePrimed ? "ready" : "not ready")):"]

        if let level = MTRClusterLevelControl(device: device, endpointID: endpoint, queue: .main) {
            lines.append("Brightness (Level Control):")
            if let v = Self.valueOf(level.readAttributeFeatureMap(with: nil)) { lines.append("  features: \(v.intValue) (on/off \(v.intValue & 1 != 0), lighting \(v.intValue & 2 != 0))") }
            if let v = Self.valueOf(level.readAttributeCurrentLevel(with: nil)) { lines.append("  current level: \(v.intValue) of 254") }
            if let v = Self.valueOf(level.readAttributeMinLevel(with: nil)) { lines.append("  minimum level: \(v.intValue)") }
            if let v = Self.valueOf(level.readAttributeOnOffTransitionTime(with: nil)) { lines.append("  built-in on/off transition: \(Double(v.intValue) / 10) s") }
            if let ids = Self.listOfNumbers(level.readAttributeAcceptedCommandList(with: nil)) {
                let names: [Int: String] = [0: "MoveToLevel", 1: "Move", 2: "Step", 3: "Stop", 4: "MoveToLevelWithOnOff", 5: "MoveWithOnOff", 6: "StepWithOnOff", 7: "StopWithOnOff"]
                lines.append("  commands: " + ids.sorted().map { names[$0] ?? String($0) }.joined(separator: ", "))
            } else {
                lines.append("  commands: not available yet")
            }
        }

        if let color = MTRClusterColorControl(device: device, endpointID: endpoint, queue: .main) {
            lines.append("Color (Color Control):")
            if let v = Self.valueOf(color.readAttributeColorCapabilities(with: nil)) {
                let bits = v.intValue
                lines.append("  supports: hue/saturation \(bits & 1 != 0), XY \(bits & 8 != 0), color temperature \(bits & 16 != 0), color loop \(bits & 4 != 0)")
            } else {
                lines.append("  capabilities: not available yet")
            }
            if let v = Self.valueOf(color.readAttributeColorMode(with: nil)) { lines.append("  current mode: \(["hue/saturation", "XY", "color temperature"][min(max(v.intValue, 0), 2)])") }
            if let lo = Self.valueOf(color.readAttributeColorTempPhysicalMinMireds(with: nil)),
               let hi = Self.valueOf(color.readAttributeColorTempPhysicalMaxMireds(with: nil)) {
                lines.append("  white range: \(1_000_000 / max(hi.intValue, 1)) K to \(1_000_000 / max(lo.intValue, 1)) K")
            }
            if let ids = Self.listOfNumbers(color.readAttributeAcceptedCommandList(with: nil)) {
                let names: [Int: String] = [0: "MoveToHue", 1: "MoveHue", 2: "StepHue", 3: "MoveToSaturation", 4: "MoveSaturation", 5: "StepSaturation", 6: "MoveToHueAndSaturation", 7: "MoveToColor", 8: "MoveColor", 9: "StepColor", 10: "MoveToColorTemperature", 0x40: "EnhancedMoveToHue", 0x41: "EnhancedMoveHue", 0x42: "EnhancedStepHue", 0x43: "EnhancedMoveToHueAndSaturation", 0x44: "ColorLoopSet", 0x47: "StopMoveStep", 0x4B: "MoveColorTemperature", 0x4C: "StepColorTemperature"]
                lines.append("  commands: " + ids.sorted().map { names[$0] ?? String($0) }.joined(separator: ", "))
            } else {
                lines.append("  commands: not available yet")
            }
        } else {
            lines.append("Color: this bulb has no Color Control cluster (brightness only).")
        }
        return lines
    }
}

/// Bookkeeping for one running fade (a class so completion handlers can update it).
final class FadeCounters {
    var inFlight = 0
    var sent = 0
    var succeeded = 0
    var failed = 0
    var consecutiveFailures = 0
    var skipped = 0
    var totalRTT = 0.0
    var lastError: Error?
}

final class ColorFadeState {
    var xy = false
    var lastA = -1
    var lastB = -1
}
