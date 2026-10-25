import AVFoundation
import UIKit

/// Listens through the microphone and drives the bulbs from the loudness and bass beats of whatever is playing.
/// iOS doesn't let apps capture other apps' audio, so the phone has to hear the music from a speaker.
final class MusicSync: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case pulse = "Pulse"
        case colorBeat = "Color on beat"

        var id: String { rawValue }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var meter: Double = 0
    @Published private(set) var note = ""

    /// Adjustable while running (0.5 = calmer, 2 = more reactive).
    var sensitivity: Double = 1
    var mode: Mode = .pulse

    private let engine = AVAudioEngine()
    private weak var matter: MatterManager?
    private var targets: [UInt64] = []

    // Audio-thread state (only touched from the tap callback).
    private var lowPass: Float = 0
    private var peak: Double = 0.003
    private var average: Double = 0
    private var lastBeat: CFTimeInterval = 0
    private var sampleRate: Double = 44100

    // Main-thread state.
    private var smoothed: Double = 0
    private var lastSend: CFTimeInterval = 0
    private var hue: Double = 0
    private var inflight: [UInt64: Int] = [:]

    func start(matter: MatterManager, targets: [UInt64], mode: Mode, sensitivity: Double) {
        guard !isRunning else { return }
        guard !targets.isEmpty else {
            note = "Add a bulb first."
            return
        }
        self.matter = matter
        self.targets = targets
        self.mode = mode
        self.sensitivity = sensitivity
        note = "Starting…"

        Task { @MainActor in
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else {
                self.note = "Microphone access is off. Turn it on in Settings > Switchboard."
                return
            }
            do {
                try self.begin()
            } catch {
                self.note = "Couldn't start listening: \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        UIApplication.shared.isIdleTimerDisabled = false
        isRunning = false
        meter = 0
        note = "Stopped."
    }

    private func begin() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            note = "No microphone input is available."
            return
        }
        sampleRate = format.sampleRate
        lowPass = 0
        peak = 0.003
        average = 0
        lastBeat = 0
        smoothed = 0
        lastSend = 0
        inflight = [:]

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.analyze(buffer)
        }
        engine.prepare()
        try engine.start()

        // Make sure the bulbs are on, then keep the screen awake so the phone keeps listening.
        for id in targets {
            matter?.lightPower(id, on: true) { _ in }
        }
        UIApplication.shared.isIdleTimerDisabled = true
        isRunning = true
        note = "Listening. Play some music near the phone."
    }

    // MARK: Audio analysis (audio thread)

    private func analyze(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        // One-pole low-pass at about 150 Hz isolates kick drums and bass.
        let alpha = Float(1 - exp(-2 * Double.pi * 150 / sampleRate))
        var low = lowPass
        var sumFull: Float = 0
        var sumBass: Float = 0
        for i in 0..<count {
            let x = channel[i]
            low += alpha * (x - low)
            sumFull += x * x
            sumBass += low * low
        }
        lowPass = low

        let n = Float(count)
        let rmsFull = (sumFull / n).squareRoot()
        let rmsBass = (sumBass / n).squareRoot()
        let energy = Double(rmsBass * 0.7 + rmsFull * 0.3)

        // Automatic gain: the "loud" reference slowly follows the music, so quiet and loud rooms both work.
        peak = max(peak * 0.9985, energy, 0.003)
        let normalized = min(energy / peak, 1)
        let sens = sensitivity
        let level = min(1, pow(normalized, 1.5) * sens)

        let now = CACurrentMediaTime()
        let factor = max(1.1, 1.6 - 0.25 * sens)
        var beat = false
        if energy > average * factor && energy > peak * 0.3 && now - lastBeat > 0.25 {
            beat = true
            lastBeat = now
        }
        average += 0.05 * (energy - average)

        DispatchQueue.main.async { [weak self] in
            self?.handle(level: level, beat: beat)
        }
    }

    // MARK: Driving the bulbs (main thread)

    private func handle(level: Double, beat: Bool) {
        guard isRunning else { return }

        // Rise instantly, fall gently, so the light breathes with the music instead of flickering.
        smoothed = level > smoothed ? level : smoothed * 0.85 + level * 0.15
        meter = smoothed

        let now = CACurrentMediaTime()
        let gap = now - lastSend
        guard gap >= 0.14 || (beat && gap >= 0.08) else { return }
        lastSend = now

        let percent = 5 + smoothed * 95
        guard let matter else { return }

        if mode == .colorBeat && beat {
            hue = (hue + 0.17 + Double.random(in: 0...0.12)).truncatingRemainder(dividingBy: 1)
            for id in targets where (inflight[id] ?? 0) < 2 {
                inflight[id, default: 0] += 1
                matter.lightHueSat(id, hue: hue, saturation: 1, seconds: 0) { [weak self] _ in
                    self?.inflight[id, default: 0] -= 1
                }
            }
        }

        for id in targets where (inflight[id] ?? 0) < 2 {
            inflight[id, default: 0] += 1
            matter.lightLevel(id, percent: percent, seconds: 0.1, withOnOff: false) { [weak self] _ in
                self?.inflight[id, default: 0] -= 1
            }
        }
    }
}
