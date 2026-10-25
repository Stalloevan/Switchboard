import SwiftUI
import Matter

struct Bulb: Identifiable, Codable, Hashable {
    var nodeID: UInt64
    var name: String
    var id: UInt64 { nodeID }
}

struct BulbState {
    var reachable = false
    var isOn = false

    var hasLevel = false
    var level: Double = 1          // 0...1

    var hasColorTemp = false
    var mireds: Double = 300
    var minMireds: Double = 153
    var maxMireds: Double = 500

    var hasHueSat = false
    var hue: Double = 0            // 0...1
    var saturation: Double = 0     // 0...1
}

private struct PendingBulb {
    var nodeID: UInt64
    var name: String
    var ssid: String
    var password: String
}

private enum SetupError: LocalizedError {
    case noKey

    var errorDescription: String? {
        switch self {
        case .noKey: return "Couldn't create the fabric signing key."
        }
    }
}

/// Owns the Matter controller (this app is its own Matter fabric, so no hub or HomeKit is needed)
/// and exposes the bulbs and their state to SwiftUI.
final class MatterManager: NSObject, ObservableObject {
    @Published private(set) var bulbs: [Bulb] = []
    @Published private(set) var states: [UInt64: BulbState] = [:]
    @Published private(set) var isReady = false
    @Published private(set) var isCommissioning = false
    @Published private(set) var status = ""
    @Published private(set) var pairingFinished = false
    @Published private(set) var pairingError: String?
    @Published private(set) var pairingLog: [String] = []
    @Published var errorMessage: String?
    /// Recent fade / music / diagnostic messages, newest last. Shown in the Scenes screen.
    @Published private(set) var activity: [String] = []

    private let storage = MatterStorage()
    private var rootKeypair: RootKeypair?
    private var controller: MTRDeviceController?
    var devices: [UInt64: MTRDevice] = [:]
    private var nodeIDs: [ObjectIdentifier: UInt64] = [:]
    private var pending: PendingBulb?
    private var pairingTimeout: DispatchWorkItem?
    private var bluetoothProbe: BluetoothProbe?

    private var debounced: [String: DispatchWorkItem] = [:]
    private var localEdits: [String: Date] = [:]

    let endpoint = NSNumber(value: 1)

    /// Bumped to cancel a running fade on a bulb (used by fades, manual controls and the Stop button).
    var effectGeneration: [UInt64: Int] = [:]
    /// Number of running effects that need the screen to stay on.
    var awakeCount = 0
    private static let bulbsKey = "switchboard.bulbs"
    private static let nextNodeKey = "switchboard.nextNodeID"

    /// One shared controller for the app and for Shortcuts actions that run without the UI.
    static let shared = MatterManager()

    override init() {
        super.init()
        bulbs = Self.loadBulbs()
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    func logActivity(_ text: String) {
        activity.append("\(Self.timeFormatter.string(from: Date()))  \(text)")
        if activity.count > 150 { activity.removeFirst(activity.count - 150) }
    }

    func clearActivity() {
        activity = []
    }

    // MARK: Startup

    func start() {
        guard controller == nil else { return }
        do {
            let factory = MTRDeviceControllerFactory.sharedInstance()
            if !factory.isRunning {
                let factoryParams = MTRDeviceControllerFactoryParams(storage: storage)
                try factory.start(factoryParams)
            }

            guard let keypair = RootKeypair(tag: Identity.rootKeyTag) else { throw SetupError.noKey }
            rootKeypair = keypair

            let params = MTRDeviceControllerStartupParams(ipk: Identity.ipk(),
                                                          fabricID: Identity.fabricID,
                                                          nocSigner: keypair)
            params.vendorID = Identity.vendorID
            params.nodeID = Identity.controllerNodeID

            let newController: MTRDeviceController
            do {
                newController = try factory.createController(onNewFabric: params)
            } catch {
                newController = try factory.createController(onExistingFabric: params)
            }
            newController.setDeviceControllerDelegate(self, queue: .main)
            controller = newController
            isReady = true

            for bulb in bulbs { attach(bulb) }
        } catch {
            errorMessage = "Couldn't start the Matter controller: \(error.localizedDescription)"
        }
    }

    private func attach(_ bulb: Bulb) {
        guard let controller, devices[bulb.nodeID] == nil else { return }
        let device = MTRDevice(nodeID: NSNumber(value: bulb.nodeID), controller: controller)
        device.add(self, queue: .main)
        devices[bulb.nodeID] = device
        nodeIDs[ObjectIdentifier(device)] = bulb.nodeID
        states[bulb.nodeID] = BulbState()
        refresh(bulb.nodeID)
    }

    func refreshAll() {
        for bulb in bulbs { refresh(bulb.nodeID) }
    }

    // MARK: Reading state

    private static func number(_ attribute: [String: Any]?) -> NSNumber? {
        attribute?[MTRValueKey] as? NSNumber
    }

    private func recentlyEdited(_ key: String) -> Bool {
        guard let date = localEdits[key] else { return false }
        return Date().timeIntervalSince(date) < 1.0
    }

    func refresh(_ nodeID: UInt64) {
        guard let device = devices[nodeID] else { return }
        var s = states[nodeID] ?? BulbState()
        s.reachable = (device.state == .reachable)

        if let onOff = MTRClusterOnOff(device: device, endpointID: endpoint, queue: .main),
           let value = Self.number(onOff.readAttributeOnOff(with: nil)) {
            s.isOn = value.boolValue
        }

        if let levelControl = MTRClusterLevelControl(device: device, endpointID: endpoint, queue: .main),
           let value = Self.number(levelControl.readAttributeCurrentLevel(with: nil)) {
            s.hasLevel = true
            if !recentlyEdited("level-\(nodeID)") {
                let clamped = min(max(value.intValue, 1), 254)
                s.level = Double(clamped - 1) / 253.0
            }
        }

        if let color = MTRClusterColorControl(device: device, endpointID: endpoint, queue: .main),
           let caps = Self.number(color.readAttributeColorCapabilities(with: nil)) {
            let bits = caps.intValue
            s.hasHueSat = (bits & 0x01) != 0
            s.hasColorTemp = (bits & 0x10) != 0

            if s.hasColorTemp {
                if let lo = Self.number(color.readAttributeColorTempPhysicalMinMireds(with: nil)) {
                    s.minMireds = lo.doubleValue
                }
                if let hi = Self.number(color.readAttributeColorTempPhysicalMaxMireds(with: nil)) {
                    s.maxMireds = hi.doubleValue
                }
                if s.maxMireds <= s.minMireds {
                    s.minMireds = 153
                    s.maxMireds = 500
                }
                if !recentlyEdited("temp-\(nodeID)"),
                   let cur = Self.number(color.readAttributeColorTemperatureMireds(with: nil)) {
                    s.mireds = min(max(cur.doubleValue, s.minMireds), s.maxMireds)
                } else {
                    s.mireds = min(max(s.mireds, s.minMireds), s.maxMireds)
                }
            }

            if s.hasHueSat, !recentlyEdited("color-\(nodeID)") {
                if let h = Self.number(color.readAttributeCurrentHue(with: nil)) {
                    s.hue = min(max(h.doubleValue / 254.0, 0), 1)
                }
                if let sat = Self.number(color.readAttributeCurrentSaturation(with: nil)) {
                    s.saturation = min(max(sat.doubleValue / 254.0, 0), 1)
                }
            }
        }

        states[nodeID] = s
    }

    // MARK: Controlling bulbs

    private func debounce(_ key: String, delay: TimeInterval = 0.12, _ work: @escaping () -> Void) {
        localEdits[key] = Date()
        debounced[key]?.cancel()
        let item = DispatchWorkItem(block: work)
        debounced[key] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func log(_ text: String) {
        pairingLog.append(text)
        if pairingLog.count > 200 { pairingLog.removeFirst(pairingLog.count - 200) }
    }

    private func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) code \(ns.code): \(ns.localizedDescription)"
    }

    private func report(_ error: Error, action: String) {
        errorMessage = "Couldn't \(action): \(error.localizedDescription)"
    }

    func setPower(_ nodeID: UInt64, on: Bool) {
        stopEffects([nodeID])
        guard let device = devices[nodeID],
              let cluster = MTRClusterOnOff(device: device, endpointID: endpoint, queue: .main) else { return }
        states[nodeID, default: BulbState()].isOn = on

        let handler: ((any Error)?) -> Void = { [weak self] error in
            if let error {
                self?.report(error, action: on ? "turn the bulb on" : "turn the bulb off")
                self?.refresh(nodeID)
            }
        }
        if on {
            cluster.on(withExpectedValues: nil, expectedValueInterval: nil, completion: handler)
        } else {
            cluster.off(withExpectedValues: nil, expectedValueInterval: nil, completion: handler)
        }
    }

    func setLevel(_ nodeID: UInt64, fraction: Double) {
        stopEffects([nodeID])
        states[nodeID, default: BulbState()].level = fraction
        debounce("level-\(nodeID)") { [weak self] in
            guard let self,
                  let device = self.devices[nodeID],
                  let cluster = MTRClusterLevelControl(device: device, endpointID: self.endpoint, queue: .main) else { return }
            let params = MTRLevelControlClusterMoveToLevelParams()
            params.level = NSNumber(value: 1 + Int((fraction * 253).rounded()))
            params.transitionTime = NSNumber(value: 2)
            params.optionsMask = NSNumber(value: 0)
            params.optionsOverride = NSNumber(value: 0)
            cluster.moveToLevel(with: params, expectedValues: nil, expectedValueInterval: nil, completion: { [weak self] error in
                if let error {
                    self?.report(error, action: "change brightness")
                    self?.refresh(nodeID)
                }
            })
        }
    }

    func setColorTemp(_ nodeID: UInt64, mireds: Double) {
        stopEffects([nodeID])
        states[nodeID, default: BulbState()].mireds = mireds
        debounce("temp-\(nodeID)") { [weak self] in
            guard let self,
                  let device = self.devices[nodeID],
                  let cluster = MTRClusterColorControl(device: device, endpointID: self.endpoint, queue: .main) else { return }
            let params = MTRColorControlClusterMoveToColorTemperatureParams()
            params.colorTemperatureMireds = NSNumber(value: Int(mireds.rounded()))
            params.transitionTime = NSNumber(value: 2)
            params.optionsMask = NSNumber(value: 0)
            params.optionsOverride = NSNumber(value: 0)
            cluster.moveToColorTemperature(with: params, expectedValues: nil, expectedValueInterval: nil, completion: { [weak self] error in
                if let error {
                    self?.report(error, action: "change color temperature")
                    self?.refresh(nodeID)
                }
            })
        }
    }

    func setColor(_ nodeID: UInt64, hue: Double, saturation: Double) {
        stopEffects([nodeID])
        states[nodeID, default: BulbState()].hue = hue
        states[nodeID, default: BulbState()].saturation = saturation
        debounce("color-\(nodeID)") { [weak self] in
            guard let self,
                  let device = self.devices[nodeID],
                  let cluster = MTRClusterColorControl(device: device, endpointID: self.endpoint, queue: .main) else { return }
            let params = MTRColorControlClusterMoveToHueAndSaturationParams()
            params.hue = NSNumber(value: Int((hue * 254).rounded()))
            params.saturation = NSNumber(value: Int((saturation * 254).rounded()))
            params.transitionTime = NSNumber(value: 2)
            params.optionsMask = NSNumber(value: 0)
            params.optionsOverride = NSNumber(value: 0)
            cluster.moveToHueAndSaturation(with: params, expectedValues: nil, expectedValueInterval: nil, completion: { [weak self] error in
                if let error {
                    self?.report(error, action: "change color")
                    self?.refresh(nodeID)
                }
            })
        }
    }

    // MARK: Adding and removing bulbs

    func addBulb(name: String, code: String, ssid: String, password: String) {
        guard let controller else {
            errorMessage = "The Matter controller isn't running yet."
            return
        }
        guard !isCommissioning else { return }

        var cleaned = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.uppercased().hasPrefix("MT:") {
            cleaned = cleaned.filter { $0.isNumber }
        }

        do {
            pairingLog = []
            pairingError = nil
            log("Parsing setup code (\(cleaned.count) characters)")
            let payload = try MTRSetupPayload(onboardingPayload: cleaned)
            log("Code OK: vendor \(payload.vendorID), product \(payload.productID), discriminator \(payload.discriminator), short discriminator \(payload.hasShortDiscriminator), discovery \(payload.discoveryCapabilities.rawValue)")
            let nodeID = Self.takeNextNodeID()
            let displayName = name.trimmingCharacters(in: .whitespaces)
            pending = PendingBulb(nodeID: nodeID,
                                  name: displayName.isEmpty ? "Bulb \(bulbs.count + 1)" : displayName,
                                  ssid: ssid,
                                  password: password)
            pairingFinished = false
            isCommissioning = true
            status = "Looking for the bulb…"
            startPairingTimeout(nodeID: nodeID)

            status = "Checking Bluetooth…"
            let probe = BluetoothProbe(
                shortDiscriminator: payload.hasShortDiscriminator ? payload.discriminator.intValue : nil,
                log: { [weak self] text in self?.log(text) },
                completion: { [weak self] in
                    guard let self, let pending = self.pending, pending.nodeID == nodeID else { return }
                    self.bluetoothProbe = nil
                    self.status = "Looking for the bulb…"
                    self.log("Starting session for node \(nodeID), Wi-Fi details \(ssid.isEmpty ? "not given" : "given")")
                    do {
                        try controller.setupCommissioningSession(with: payload, newNodeID: NSNumber(value: nodeID))
                    } catch {
                        self.finishPairing(error: error)
                    }
                })
            bluetoothProbe = probe
            probe.start()
        } catch {
            finishPairing(error: error)
        }
    }

    func acknowledgePairing() {
        pairingFinished = false
        status = ""
    }

    func remove(_ bulb: Bulb) {
        controller?.forgetDevice(withNodeID: NSNumber(value: bulb.nodeID))
        if let device = devices.removeValue(forKey: bulb.nodeID) {
            device.remove(self)
            nodeIDs.removeValue(forKey: ObjectIdentifier(device))
        }
        states.removeValue(forKey: bulb.nodeID)
        bulbs.removeAll { $0.nodeID == bulb.nodeID }
        Self.saveBulbs(bulbs)
    }

    private func startPairingTimeout(nodeID: UInt64) {
        pairingTimeout?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let pending = self.pending, pending.nodeID == nodeID else { return }
            _ = try? self.controller?.cancelCommissioning(forNodeID: NSNumber(value: nodeID))
            self.finishPairing(error: PairingError.timedOut)
        }
        pairingTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 150, execute: item)
    }

    private func finishPairing(error: Error?) {
        pairingTimeout?.cancel()
        pairingTimeout = nil
        bluetoothProbe = nil
        isCommissioning = false

        if let error {
            status = ""
            pending = nil
            let text = describe(error)
            log("FAILED: \(text)")
            pairingError = text
        }
    }

    private func completePairing(nodeID: UInt64) {
        guard let pending, pending.nodeID == nodeID else { return }
        let bulb = Bulb(nodeID: nodeID, name: pending.name)
        bulbs.append(bulb)
        Self.saveBulbs(bulbs)
        attach(bulb)

        self.pending = nil
        pairingTimeout?.cancel()
        pairingTimeout = nil
        isCommissioning = false
        status = "Paired"
        pairingFinished = true
    }

    // MARK: Persistence

    static func loadBulbs() -> [Bulb] {
        guard let data = UserDefaults.standard.data(forKey: bulbsKey),
              let decoded = try? JSONDecoder().decode([Bulb].self, from: data) else { return [] }
        return decoded
    }

    private static func saveBulbs(_ bulbs: [Bulb]) {
        if let data = try? JSONEncoder().encode(bulbs) {
            UserDefaults.standard.set(data, forKey: bulbsKey)
        }
    }

    private static func takeNextNodeID() -> UInt64 {
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: nextNodeKey) as? NSNumber
        let next = stored?.uint64Value ?? 100
        defaults.set(NSNumber(value: next + 1), forKey: nextNodeKey)
        return next
    }
}

private enum PairingError: LocalizedError {
    case timedOut
    case sessionFailed
    case attestation

    var errorDescription: String? {
        switch self {
        case .timedOut:
            return "Timed out. Make sure the bulb is in pairing mode (factory reset it) and close to your phone."
        case .sessionFailed:
            return "Couldn't connect to the bulb. Check the pairing code and that the bulb is in pairing mode."
        case .attestation:
            return "The bulb's certificate check failed."
        }
    }
}

// MARK: - Commissioning callbacks

extension MatterManager: MTRDeviceControllerDelegate {
    func controller(_ controller: MTRDeviceController, commissioningSessionEstablishmentDone error: Error?) {
        guard let pending else { return }
        if let error {
            finishPairing(error: error)
            return
        }

        status = "Pairing…"
        log("Secure session established, starting commissioning")
        let params = MTRCommissioningParameters()
        params.deviceAttestationDelegate = self
        if !pending.ssid.isEmpty {
            params.wifiSSID = Data(pending.ssid.utf8)
            params.wifiCredentials = Data(pending.password.utf8)
        }

        do {
            try controller.commissionNode(withID: NSNumber(value: pending.nodeID), commissioningParams: params)
        } catch {
            finishPairing(error: error)
        }
    }

    func controller(_ controller: MTRDeviceController, statusUpdate status: MTRCommissioningStatus) {
        log("Status update: \(status.rawValue)")
    }

    func controller(_ controller: MTRDeviceController, commissioneeHasReceivedNetworkCredentials nodeID: NSNumber) {
        log("Bulb received the Wi-Fi details and is joining the network")
    }

    func controller(_ controller: MTRDeviceController, commissioningComplete error: Error?, nodeID: NSNumber?) {
        log("Commissioning finished: \(error.map { describe($0) } ?? "no error")")
        if let error {
            finishPairing(error: error)
            return
        }
        guard let nodeID else {
            finishPairing(error: PairingError.sessionFailed)
            return
        }
        completePairing(nodeID: nodeID.uint64Value)
    }
}

// MARK: - Attestation

/// Most home bulbs carry certificates that a personal controller can't verify without the
/// full Matter PAA trust store, so attestation failures are tolerated here. This is a
/// deliberate trade-off for a personal app that only pairs bulbs you own.
extension MatterManager: MTRDeviceAttestationDelegate {
    func deviceAttestationCompleted(for controller: MTRDeviceController,
                                    opaqueDeviceHandle: UnsafeMutableRawPointer,
                                    attestationDeviceInfo: MTRDeviceAttestationDeviceInfo,
                                    error: Error?) {
        log("Attestation check: \(error.map { describe($0) } ?? "passed")\(error != nil ? " (continuing anyway)" : "")")
        do {
            try controller.continueCommissioningDevice(opaqueDeviceHandle, ignoreAttestationFailure: error != nil)
        } catch {
            finishPairing(error: error)
        }
    }

    func deviceAttestationFailed(for controller: MTRDeviceController,
                                 opaqueDeviceHandle: UnsafeMutableRawPointer,
                                 error: Error) {
        log("Attestation failed: \(describe(error)) (continuing anyway)")
        do {
            try controller.continueCommissioningDevice(opaqueDeviceHandle, ignoreAttestationFailure: true)
        } catch {
            finishPairing(error: error)
        }
    }
}

// MARK: - Device updates

extension MatterManager: MTRDeviceDelegate {
    func device(_ device: MTRDevice, stateChanged state: MTRDeviceState) {
        if let nodeID = nodeIDs[ObjectIdentifier(device)] { refresh(nodeID) }
    }

    func device(_ device: MTRDevice, receivedAttributeReport attributeReport: [[String: Any]]) {
        if let nodeID = nodeIDs[ObjectIdentifier(device)] { refresh(nodeID) }
    }

    func device(_ device: MTRDevice, receivedEventReport eventReport: [[String: Any]]) {}
}
