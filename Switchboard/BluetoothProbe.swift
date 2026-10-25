import CoreBluetooth

/// Scans briefly for Matter bulbs in pairing mode and reports what it sees. It is a diagnostic,
/// but it also makes iOS show the Bluetooth permission prompt before pairing starts.
final class BluetoothProbe: NSObject, CBCentralManagerDelegate {
    private static let matterService = CBUUID(string: "FFF6")

    private let shortDiscriminator: Int?
    private let log: (String) -> Void
    private let completion: () -> Void
    private var central: CBCentralManager?
    private var seen = Set<UUID>()
    private var scanning = false
    private var finished = false

    init(shortDiscriminator: Int?, log: @escaping (String) -> Void, completion: @escaping () -> Void) {
        self.shortDiscriminator = shortDiscriminator
        self.log = log
        self.completion = completion
        super.init()
    }

    func start() {
        log("Checking Bluetooth…")
        central = CBCentralManager(delegate: self, queue: .main)
        // Upper bound in case the permission prompt is left unanswered.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, !self.finished else { return }
            self.log("Bluetooth didn't answer in time (permission prompt unanswered?).")
            self.finish()
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !finished else { return }
        switch central.state {
        case .poweredOn:
            guard !scanning else { return }
            scanning = true
            log("Bluetooth is on. Scanning for bulbs in pairing mode…")
            central.scanForPeripherals(withServices: [Self.matterService], options: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, !self.finished else { return }
                if self.seen.isEmpty {
                    self.log("No Matter bulb in pairing mode was seen over Bluetooth.")
                }
                self.finish()
            }
        case .unauthorized:
            log("Bluetooth is blocked for Switchboard. Allow it in Settings > Switchboard.")
            finish()
        case .poweredOff:
            log("Bluetooth is turned off.")
            finish()
        case .unsupported:
            log("Bluetooth isn't available on this device.")
            finish()
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard seen.insert(peripheral.identifier).inserted else { return }

        var detail = "signal \(RSSI) dBm"
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]
        if let data = serviceData?[Self.matterService], data.count >= 7 {
            let bytes = [UInt8](data)
            let discriminator = (((Int(bytes[2]) << 8) | Int(bytes[1])) & 0x0FFF)
            let vendor = (Int(bytes[4]) << 8) | Int(bytes[3])
            let product = (Int(bytes[6]) << 8) | Int(bytes[5])
            detail += ", discriminator \(discriminator), vendor \(vendor), product \(product)"
            if let short = shortDiscriminator {
                detail += (discriminator >> 8) == short ? " (matches your code)" : " (does NOT match your code)"
            }
        }
        log("Saw a Matter bulb in pairing mode: \(detail)")
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        central?.stopScan()
        completion()
    }
}
