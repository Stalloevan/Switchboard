import SwiftUI
import UIKit

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func failure() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

/// A full-width button that visibly presses in and shows a busy or active state.
private struct ActionButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    var filled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(filled ? Color.white : tint)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(filled ? tint : tint.opacity(0.15))
            )
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

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

    private let fadeOptions: [(seconds: Int, label: String)] = [
        (5, "5 seconds"), (10, "10 seconds"), (30, "30 seconds"), (60, "1 minute"),
        (120, "2 minutes"), (300, "5 minutes"), (600, "10 minutes"), (1800, "30 minutes"), (3600, "1 hour")
    ]

    private var targetIDs: [UInt64] {
        if let target { return [target] }
        return matter.bulbs.map { $0.nodeID }
    }

    /// Average progress of the fades running on the selected bulbs, or nil when none is running.
    private var fadeProgress: Double? {
        let values = targetIDs.compactMap { matter.fadeProgress[$0] }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func timeText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var body: some View {
        NavigationStack {
            Form {
                if busy || music.isRunning {
                    Section("Running now") {
                        if busy {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: "waveform.path")
                                        .symbolEffect(.pulse)
                                    Text(fadeKind == .brightness ? "Brightness fade" : "Color fade")
                                        .font(.headline)
                                    Spacer()
                                    Text(fadeProgress.map { "\(Int($0 * 100))%" } ?? "Starting…")
                                        .monospacedDigit()
                                }
                                ProgressView(value: fadeProgress ?? 0)
                                if let progress = fadeProgress {
                                    Text("\(timeText(Double(fadeSeconds) * (1 - progress))) left")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                        }
                        if music.isRunning {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: "music.note")
                                        .symbolEffect(.pulse)
                                    Text("Music sync listening")
                                        .font(.headline)
                                }
                                ProgressView(value: music.meter)
                            }
                        }
                    }
                }

                Section("Bulbs") {
                    Picker("Apply to", selection: $target) {
                        Text("All bulbs").tag(UInt64?.none)
                        ForEach(matter.bulbs) { bulb in
                            Text(bulb.name).tag(UInt64?.some(bulb.nodeID))
                        }
                    }
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
                    Button {
                        Haptics.tap()
                        startFade()
                    } label: {
                        Label(busy ? "Fading…" : "Start fade", systemImage: busy ? "hourglass" : "play.fill")
                    }
                    .buttonStyle(ActionButtonStyle())
                    .disabled(busy)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    Button {
                        Haptics.warning()
                        matter.stopEffects(targetIDs)
                        message = "Stopping…"
                    } label: {
                        Label("Stop fades", systemImage: "stop.fill")
                    }
                    .buttonStyle(ActionButtonStyle(tint: .red, filled: false))
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                } header: {
                    Text("Fade between two settings")
                } footer: {
                    Text("Jumps to the first setting, then steps smoothly to the second: brightness in 1% steps, color in many tiny hue steps. Switchboard drives every step, so keep the app open; the screen stays on during a fade. Touching a bulb's controls cancels its fade.")
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

                    Button {
                        Haptics.tap()
                        if music.isRunning {
                            music.stop()
                            message = "Music sync stopped."
                        } else {
                            music.start(matter: matter, targets: targetIDs, mode: musicMode, sensitivity: sensitivity)
                            message = "Music sync starting…"
                        }
                    } label: {
                        Label(music.isRunning ? "Stop music sync" : "Start music sync",
                              systemImage: music.isRunning ? "stop.fill" : "music.note")
                    }
                    .buttonStyle(ActionButtonStyle(tint: music.isRunning ? .red : .accentColor))
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
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
                        Label(message, systemImage: message.hasPrefix("Failed") ? "exclamationmark.triangle.fill" : "info.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(message.hasPrefix("Failed") ? Color.red : Color.primary)
                    }
                }

                Section {
                    Button {
                        Haptics.tap()
                        for id in targetIDs {
                            for line in matter.bulbReport(id) { matter.logActivity(line) }
                        }
                        message = "Bulb report added to the log below."
                    } label: {
                        Label("Check bulb", systemImage: "stethoscope")
                    }
                    .buttonStyle(ActionButtonStyle(filled: false))
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    if !matter.activity.isEmpty {
                        Text(matter.activity.suffix(40).reversed().joined(separator: "\n"))
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Copy log") {
                            Haptics.success()
                            UIPasteboard.general.string = matter.activity.joined(separator: "\n")
                            message = "Log copied."
                        }
                        Button("Clear log", role: .destructive) {
                            Haptics.warning()
                            matter.clearActivity()
                            message = "Log cleared."
                        }
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("If something doesn't work, tap Check bulb, try it again, then copy the log and send it over.")
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
        message = "Fade running. You can leave this screen open; touching a bulb cancels it."
        Task { @MainActor in
            do {
                try await work(ids)
                message = success
                Haptics.success()
            } catch is CancellationError {
                message = "Stopped."
                Haptics.warning()
            } catch {
                message = "Failed: \(error.localizedDescription)"
                Haptics.failure()
            }
            busy = false
        }
    }

    private func startFade() {
        let seconds = Double(fadeSeconds)
        let manager = matter
        switch fadeKind {
        case .brightness:
            let from = fromPercent
            let to = toPercent
            run("Brightness fade finished.") { ids in
                try await manager.forEachBulb(ids) { id in
                    try await manager.fadeBrightness(id, from: from, to: to, seconds: seconds)
                }
            }
        case .color:
            let from = LightColor.from(UIColor(fromColor))
            let to = LightColor.from(UIColor(toColor))
            run("Color fade finished.") { ids in
                try await manager.forEachBulb(ids) { id in
                    try await manager.fadeColor(id, from: from, to: to, seconds: seconds)
                }
            }
        }
    }
}
