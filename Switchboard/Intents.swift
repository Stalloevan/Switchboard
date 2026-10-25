import AppIntents
import Foundation

// MARK: - Bulb picker for Shortcuts

struct BulbEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Bulb"
    static let defaultQuery = BulbQuery()

    var id: String
    var name: String

    init(_ bulb: Bulb) {
        id = String(bulb.nodeID)
        name = bulb.name
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct BulbQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [BulbEntity] {
        MatterManager.loadBulbs()
            .filter { identifiers.contains(String($0.nodeID)) }
            .map { BulbEntity($0) }
    }

    func suggestedEntities() async throws -> [BulbEntity] {
        MatterManager.loadBulbs().map { BulbEntity($0) }
    }
}

// MARK: - Colors

enum ColorChoice: String, AppEnum {
    case red, orange, yellow, green, cyan, blue, purple, pink
    case warmWhite, neutralWhite, coolWhite

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Color"
    static let caseDisplayRepresentations: [ColorChoice: DisplayRepresentation] = [
        .red: "Red",
        .orange: "Orange",
        .yellow: "Yellow",
        .green: "Green",
        .cyan: "Cyan",
        .blue: "Blue",
        .purple: "Purple",
        .pink: "Pink",
        .warmWhite: "Warm white",
        .neutralWhite: "Neutral white",
        .coolWhite: "Cool white"
    ]

    var lightColor: LightColor {
        switch self {
        case .red: return .hueSat(hue: 0.0, saturation: 1)
        case .orange: return .hueSat(hue: 0.07, saturation: 1)
        case .yellow: return .hueSat(hue: 0.15, saturation: 1)
        case .green: return .hueSat(hue: 0.33, saturation: 1)
        case .cyan: return .hueSat(hue: 0.5, saturation: 1)
        case .blue: return .hueSat(hue: 0.66, saturation: 1)
        case .purple: return .hueSat(hue: 0.78, saturation: 1)
        case .pink: return .hueSat(hue: 0.92, saturation: 0.6)
        case .warmWhite: return .kelvin(2700)
        case .neutralWhite: return .kelvin(4000)
        case .coolWhite: return .kelvin(6500)
        }
    }
}

/// A named color, or a custom hex value (for example "#FF8800") which takes priority when given.
private func resolveColor(_ choice: ColorChoice, hex: String?) throws -> LightColor {
    if let hex, !hex.trimmingCharacters(in: .whitespaces).isEmpty {
        guard let parsed = LightColor.hex(hex) else {
            throw IntentError.message("“\(hex)” isn't a valid hex color. Use six digits like #FF8800.")
        }
        return parsed
    }
    return choice.lightColor
}

// MARK: - Shared setup

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case message(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .message(let text): return "\(text)"
        }
    }
}

/// Starts the controller if the app was launched in the background just to run this action,
/// works out which bulbs to use (all of them when none is chosen), and waits briefly for them.
@MainActor
private func prepareBulbs(_ bulb: BulbEntity?) async throws -> [UInt64] {
    let manager = MatterManager.shared
    manager.start()
    guard manager.isReady else { throw IntentError.message(LightError.notRunning.errorDescription ?? "Couldn't start.") }

    let ids: [UInt64]
    if let bulb {
        guard let id = UInt64(bulb.id) else { throw IntentError.message(LightError.unknownBulb.errorDescription ?? "Unknown bulb.") }
        ids = [id]
    } else {
        ids = manager.bulbs.map { $0.nodeID }
    }
    guard !ids.isEmpty else { throw IntentError.message(LightError.noBulbs.errorDescription ?? "No bulbs.") }

    await manager.waitUntilReady(ids)
    return ids
}

// MARK: - Actions

struct TurnBulbIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Bulb On or Off"
    static let description = IntentDescription("Turns a Switchboard bulb on or off. Leave the bulb empty to use all bulbs.")

    @Parameter(title: "Bulb") var bulb: BulbEntity?
    @Parameter(title: "On", default: true) var on: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        let ids = try await prepareBulbs(bulb)
        let turnOn = on
        MatterManager.shared.stopEffects(ids)
        try await MatterManager.shared.forEachBulb(ids) { id in
            try await MatterManager.shared.applyPower(id, on: turnOn)
        }
        return .result()
    }
}

struct SetBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Brightness"
    static let description = IntentDescription("Sets a bulb's brightness from 1 to 100 percent. 0 turns it off.")

    @Parameter(title: "Bulb") var bulb: BulbEntity?
    @Parameter(title: "Brightness (%)", default: 100) var percent: Int

    @MainActor
    func perform() async throws -> some IntentResult {
        let ids = try await prepareBulbs(bulb)
        let level = Double(percent)
        try await MatterManager.shared.forEachBulb(ids) { id in
            try await MatterManager.shared.setBrightness(id, percent: level)
        }
        return .result()
    }
}

struct SetColorIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Color"
    static let description = IntentDescription("Sets a bulb to a named color or white, or to a custom hex color.")

    @Parameter(title: "Bulb") var bulb: BulbEntity?
    @Parameter(title: "Color", default: .warmWhite) var color: ColorChoice
    @Parameter(title: "Custom hex color (overrides Color)") var hex: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        let target = try resolveColor(color, hex: hex)
        let ids = try await prepareBulbs(bulb)
        try await MatterManager.shared.forEachBulb(ids) { id in
            try await MatterManager.shared.setColor(id, color: target)
        }
        return .result()
    }
}

struct FadeBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Fade Between Brightness Levels"
    static let openAppWhenRun: Bool = true
    static let description = IntentDescription("Jumps to the first brightness, then changes to the second in 1% steps over the chosen time. Switchboard opens and stays on screen until the fade finishes.")

    @Parameter(title: "Bulb") var bulb: BulbEntity?
    @Parameter(title: "From brightness (%)", default: 100) var fromPercent: Int
    @Parameter(title: "To brightness (%)", default: 10) var toPercent: Int
    @Parameter(title: "Duration (seconds)", default: 60) var seconds: Int

    @MainActor
    func perform() async throws -> some IntentResult {
        let ids = try await prepareBulbs(bulb)
        let from = Double(fromPercent)
        let to = Double(toPercent)
        let duration = Double(seconds)
        try await MatterManager.shared.forEachBulb(ids) { id in
            try await MatterManager.shared.fadeBrightness(id, from: from, to: to, seconds: duration)
        }
        return .result()
    }
}

struct FadeColorIntent: AppIntent {
    static let title: LocalizedStringResource = "Fade Between Two Colors"
    static let openAppWhenRun: Bool = true
    static let description = IntentDescription("Jumps to the first color, then blends to the second in many small steps over the chosen time. Switchboard opens and stays on screen until the fade finishes.")

    @Parameter(title: "Bulb") var bulb: BulbEntity?
    @Parameter(title: "From color", default: .red) var fromColor: ColorChoice
    @Parameter(title: "From custom hex (overrides)") var fromHex: String?
    @Parameter(title: "To color", default: .blue) var toColor: ColorChoice
    @Parameter(title: "To custom hex (overrides)") var toHex: String?
    @Parameter(title: "Duration (seconds)", default: 60) var seconds: Int

    @MainActor
    func perform() async throws -> some IntentResult {
        let from = try resolveColor(fromColor, hex: fromHex)
        let to = try resolveColor(toColor, hex: toHex)
        let ids = try await prepareBulbs(bulb)
        let duration = Double(seconds)
        try await MatterManager.shared.forEachBulb(ids) { id in
            try await MatterManager.shared.fadeColor(id, from: from, to: to, seconds: duration)
        }
        return .result()
    }
}
