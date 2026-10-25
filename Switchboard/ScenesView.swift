import SwiftUI
import UIKit

private enum FadeKind: String, CaseIterable, Identifiable {
    case brightness = "Brightness"
    case color = "Color"

    var id: String { rawValue }
}

struct ScenesView: View {
    @EnvironmentObject private var matter: MatterManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var music = MusicSync()

    @State private var target: UInt64?
    @State private var sunriseMinutes = 15

    @State private var fadeKind = FadeKind.brightness
    @State private var fromPercent = 100.0
    @State private var toPercent = 10.0
    @State private var fromColor = Color.red
    @State private var toColor = Color.blue
    @State private var fadeSeconds = 60

    @State private var musicMode = MusicSync.Mode.pulse
    @State private var sensitivity = 1.0

    @State private var message: String?
    @State private var busy = false

    private let sunriseOptions = [1, 5, 10, 15, 20, 30, 45, 60, 90]
    private let fadeOptions: [(seconds: Int, label: String)] = [
        (5, "5 seconds"), (10, "10 seconds"), (30, "30 seconds"), (60, "1 minute"),
        (120, "2 minutes"), (300, "5 minutes"), (600, "10 minutes"), (1800, "30 minutes"), (3600, "1 hour")
    ]

    private var targetIDs: [UInt64] {
        if let target { return [target] }
        return matter.bulbs.map { $0.nodeID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Bulbs") {
                    Picker("Apply to", selection: $target) {
                        Text("All bulbs").tag(UInt64?.none)
                        ForEach(matter.bulbs) { bulb in
                            Text(bulb.name).tag(UInt64?.some(bulb.nodeID))
                        }
                    }
                }

                Section {
                    Picker("Duration", selection: $sunriseMinutes) {
                        ForEach(sunriseOptions, id: \.self) { minutes in
                            Text("\(minutes) min").tag(minutes)
                        }
                    }
                    Button("Start sunrise") { startSunrise() }
                        .disabled(busy)
                } header: {
                    Text("Sunrise")
                } footer: {
                    Text("Starts very dim and warm, then slowly brightens. The bulb runs the whole ramp itself, so it continues even if you close the app. For a wake-up light, use the Sunrise action in a Shortcuts time-of-day automation.")
                }

                Section {
                    Picker("Fade", selection: $fadeKind) {
                        ForEach(FadeKind.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)

                    if fadeKind == .brightness {
                        VStack(alignment: .leading) {
                            Text("From \(Int(fromPercent))%")
                            Slider(value: $fromPercent, in: 1...100, step: 1)
                        }
                        VStack(alignment: .leading) {
                            Text("To \(Int(toPercent))%")
                            Slider(value: $toPercent, in: 1...100, step: 1)
                        }
                    } else {
                        ColorPicker("From", selection: $fromColor, supportsOpacity: false)
                        ColorPicker("To", selection: $toColor, supportsOpacity: false)
                    }

                    Picker("Duration", selection: $fadeSeconds) {
                        ForEach(fadeOptions, id: \.seconds) { option in
                            Text(option.label).tag(option.seconds)
                        }
                    }
                    Button("Start fade") { startFade() }
                        .disabled(busy)
                } header: {
                    Text("Fade between two settings")
                } footer: {
                    Text("Jumps to the first setting, then moves smoothly to the second. The same actions are in Shortcuts.")
                }

                Section {
                    Picker("Mode", selection: $musicMode) {
                        ForEach(MusicSync.Mode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading) {
                        Text("Sensitivity")
                        Slider(value: $sensitivity, in: 0.5...2)
                    }

                    Button(music.isRunning ? "Stop music sync" : "Start music sync") {
                        if music.isRunning {
                            music.stop()
                        } else {
                            music.start(matter: matter, targets: targetIDs, mode: musicMode, sensitivity: sensitivity)
                        }
                    }

                    if music.isRunning {
                        ProgressView(value: music.meter)
                    }
                    if !music.note.isEmpty {
                        Text(music.note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Music sync")
                } footer: {
                    Text("Listens through the microphone, so the phone must hear the music from a speaker. iOS doesn't let apps capture another app's audio directly. Audio is analyzed on the phone and never recorded. Lights can lag the beat slightly, and flashing lights can affect people with photosensitive epilepsy.")
                }

                if let message {
                    Section {
                        Text(message)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Scenes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: sensitivity) { _, value in music.sensitivity = value }
            .onChange(of: musicMode) { _, value in music.mode = value }
            .onDisappear { music.stop() }
        }
    }

    // MARK: Actions

    private func run(_ success: String, _ work: @escaping @MainActor ([UInt64]) async throws -> Void) {
        let ids = targetIDs
        guard !ids.isEmpty else {
            message = "Add a bulb first."
            return
        }
        busy = true
        message = nil
        Task { @MainActor in
            do {
                try await work(ids)
                message = success
            } catch {
                message = "Failed: \(error.localizedDescription)"
            }
            busy = false
        }
    }

    private func startSunrise() {
        let minutes = Double(sunriseMinutes)
        let manager = matter
        run("Sunrise started. It will reach full brightness in \(sunriseMinutes) min.") { ids in
            try await manager.forEachBulb(ids) { id in
                try await manager.sunrise(id, minutes: minutes)
            }
        }
    }

    private func startFade() {
        let seconds = Double(fadeSeconds)
        let manager = matter
        switch fadeKind {
        case .brightness:
            let from = fromPercent
            let to = toPercent
            run("Fading from \(Int(from))% to \(Int(to))%.") { ids in
                try await manager.forEachBulb(ids) { id in
                    try await manager.fadeBrightness(id, from: from, to: to, seconds: seconds)
                }
            }
        case .color:
            let from = LightColor.from(UIColor(fromColor))
            let to = LightColor.from(UIColor(toColor))
            run("Fading between the two colors.") { ids in
                try await manager.forEachBulb(ids) { id in
                    try await manager.fadeColor(id, from: from, to: to, seconds: seconds)
                }
            }
        }
    }
}
