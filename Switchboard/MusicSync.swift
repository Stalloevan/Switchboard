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
    private var sink: AVAudioSinkNode?
    private weak var matter: MatterManager?
    private var targets: [UInt64] = []

    // Audio-thread state (only touched from the sink callback).
    private var sampleRate: Double = 44100
    private var lowPass: Float = 0
    private var sumFull: Float = 0
    private var sumBass: Float = 0
    private var accumulated = 0
    private var floorLevel: Double = 0
    private var peakLevel: Double = 0.003
    private var fastAverage: Double = 0
    private var slowAverage: Double = 0
    private var lastBeat: CFTimeInterval = 0

    // Main-thread state.
    private var envelope: Double = 0
    private var flash: Double = 0
    private var lastFrame: CFTimeInterval = 0
    private var hue: Double = 0
    private var busy = Set<UInt64>()
    private var desiredPercent: [UInt64: Double] = [:]
    private var lastPercent: [UInt64: Double] = [:]
    private var pendingHue: [UInt64: Double] = [:]

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
        isRunning = false
        engine.stop()
        if let sink {
            engine.detach(sink)
            self.sink = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        matter?.releaseScreenAwake()
        meter = 0
        note = "Stopped."
    }

    private func begin() throws {
        // Keep other apps' music playing at full volume: mix with it, use the speaker (or a Bluetooth
        // speaker's normal high-quality route), and avoid the voice-call modes that turn playback down.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord,
                                mode: .default,
                                options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        try? session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            note = "No microphone input is available."
            return
        }
        sampleRate = format.sampleRate
        let stride = format.isInterleaved ? Int(format.channelCount) : 1

        lowPass = 0
        sumFull = 0
        sumBass = 0
        accumulated = 0
        floorLevel = 0
        peakLevel = 0.003
        fastAverage = 0
        slowAverage = 0
        lastBeat = 0
        envelope = 0
        flash = 0
        lastFrame = 0
        busy = []
        desiredPercent = [:]
        lastPercent = [:]
        pendingHue = [:]

        // A sink node receives audio in the hardware's small buffers, which keeps latency low.
        let sinkNode = AVAudioSinkNode { [weak self] _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
            if let first = buffers.first, let raw = first.mData {
                let samples = raw.assumingMemoryBound(to: Float.self)
                self?.analyze(samples, count: Int(frameCount), stride: stride)
            }
            return noErr
        }
        sink = sinkNode
        engine.attach(sinkNode)
        engine.connect(input, to: sinkNode, format: format)
        engine.prepare()
        try engine.start()

        matter?.stopEffects(targets)
        for id in targets {
            matter?.lightPower(id, on: true) { _ in }
        }
        matter?.holdScreenAwake()
        isRunning = true
        note = "Listening. Play some music near the phone."
    }

    // MARK: Audio analysis (audio thread)

    private func analyze(_ samples: UnsafeMutablePointer<Float>, count: Int, stride: Int) {
        // One-pole low-pass at about 150 Hz isolates kick drums and bass.
        let alpha = Float(1 - exp(-2 * Double.pi * 150 / sampleRate))
        var low = lowPass
        var full: Float = 0
        var bass: Float = 0
        var index = 0
        for _ in 0..<count {
            let x = samples[index]
            index += stride
            low += alpha * (x - low)
            full += x * x
            bass += low * low
        }
        lowPass = low
        sumFull += full
        sumBass += bass
        accumulated += count

        // Analyze in windows of about 10 ms.
        guard accumulated >= 480 else { return }
        let n = Float(accumulated)
        let rmsFull = (sumFull / n).squareRoot()
        let rmsBass = (sumBass / n).squareRoot()
        let dt = Double(accumulated) / sampleRate
        sumFull = 0
        sumBass = 0
        accumulated = 0

        let energy = Double(rmsBass * 0.75 + rmsFull * 0.25)

        // Follow the quietest and loudest recent levels so any room volume fills the whole range.
        let floorRise = 1 - exp(-dt / 8)
        floorLevel = energy < floorLevel ? energy : floorLevel + (energy - floorLevel) * floorRise
        let peakFall = 1 - exp(-dt / 5)
        peakLevel = energy > peakLevel ? energy : max(0.003, peakLevel + (energy - peakLevel) * peakFall)
        let span = max(peakLevel - floorLevel, 0.002)
        let normalized = min(max((energy - floorLevel) / span, 0), 1)

        // A beat is a quick rise above the recent average.
        fastAverage += (energy - fastAverage) * (1 - exp(-dt / 0.03))
        slowAverage += (energy - slowAverage) * (1 - exp(-dt / 0.4))
        let now = CACurrentMediaTime()
        let factor = max(1.08, 1.5 - 0.25 * sensitivity)
        var beat = false
        if fastAverage > slowAverage * factor
            && fastAverage > floorLevel + span * 0.3
            && now - lastBeat > 0.14 {
            beat = true
            lastBeat = now
        }

        DispatchQueue.main.async { [weak self] in
            self?.handle(level: normalized, beat: beat)
        }
    }

    // MARK: Driving the bulbs (main thread)

    private func handle(level: Double, beat: Bool) {
        guard isRunning else { return }

        let now = CACurrentMediaTime()
        let dt = lastFrame == 0 ? 0.01 : min(max(now - lastFrame, 0.001), 0.1)
        lastFrame = now

        // Loudness follows the music instantly on the way up and falls over about 0.1 s.
        // Each beat adds a bright flash that fades over about 0.15 s.
        envelope = max(min(1, level * sensitivity), envelope * exp(-dt / 0.1))
        flash = beat ? 1 : flash * exp(-dt / 0.15)
        let out = max(envelope * 0.8, flash)
        meter = out
        let percent = 2 + out * 98

        if mode == .colorBeat && beat {
            hue = (hue + 0.17 + Double.random(in: 0...0.12)).truncatingRemainder(dividingBy: 1)
            for id in targets { pendingHue[id] = hue }
        }
        for id in targets {
            desiredPercent[id] = percent
            pump(id)
        }
    }

    /// Sends the newest wanted value to a bulb as soon as its previous command is acknowledged,
    /// so the lights run as fast as each bulb allows without queueing up stale commands.
    private func pump(_ id: UInt64) {
        guard isRunning, !busy.contains(id), let matter else { return }

        if let wantedHue = pendingHue.removeValue(forKey: id) {
            busy.insert(id)
            matter.lightHueSat(id, hue: wantedHue, saturation: 1, seconds: 0) { [weak self] _ in
                self?.busy.remove(id)
                self?.pump(id)
            }
            return
        }

        guard let wanted = desiredPercent[id] else { return }
        if let last = lastPercent[id], abs(wanted - last) < 1.5 { return }
        lastPercent[id] = wanted
        busy.insert(id)
        matter.lightLevel(id, percent: wanted, seconds: 0, withOnOff: false) { [weak self] _ in
            self?.busy.remove(id)
            self?.pump(id)
        }
    }
}
