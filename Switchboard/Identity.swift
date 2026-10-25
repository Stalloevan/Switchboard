import Foundation
import Security
import Matter

/// Small Keychain helper for the few secrets Switchboard keeps (the fabric's IPK).
enum Keychain {
    private static let service = "com.stalloevan.switchboard"

    static func read(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func write(_ data: Data, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Fixed identity values for the personal Matter fabric this app owns.
enum Identity {
    static let fabricID = NSNumber(value: 1)
    static let controllerNodeID = NSNumber(value: 112233)
    /// 0xFFF1 is the Matter test vendor ID, fine for a personal controller.
    static let vendorID = NSNumber(value: 0xFFF1)
    static let rootKeyTag = "com.stalloevan.switchboard.root-key"

    /// The 16-byte Identity Protection Key. Created once, then kept in the Keychain.
    static func ipk() -> Data {
        if let existing = Keychain.read("ipk"), existing.count == 16 {
            return existing
        }
        let fresh = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        Keychain.write(fresh, account: "ipk")
        return fresh
    }
}

/// The fabric's root signing key: a P-256 key that lives in the Keychain.
final class RootKeypair: NSObject, MTRKeypair {
    private let privateKey: SecKey
    private let publicKeyRef: SecKey

    init?(tag: String) {
        let tagData = Data(tag.utf8)

        let lookup: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tagData,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: true
        ]

        var found: CFTypeRef?
        var key: SecKey?
        if SecItemCopyMatching(lookup as CFDictionary, &found) == errSecSuccess, let found = found {
            key = (found as! SecKey)
        } else {
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits as String: 256,
                kSecPrivateKeyAttrs as String: [
                    kSecAttrIsPermanent as String: true,
                    kSecAttrApplicationTag as String: tagData,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
                ] as [String: Any]
            ]
            var error: Unmanaged<CFError>?
            key = SecKeyCreateRandomKey(attributes as CFDictionary, &error)
            error?.release()
        }

        guard let priv = key, let pub = SecKeyCopyPublicKey(priv) else { return nil }
        privateKey = priv
        publicKeyRef = pub
        super.init()
    }

    private func sign(_ message: Data, algorithm: SecKeyAlgorithm) -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(privateKey, algorithm, message as CFData, &error) as Data? else {
            error?.release()
            return Data()
        }
        return signature
    }

    // MARK: MTRKeypair

    func signMessageECDSA_RAW(_ message: Data) -> Data {
        sign(message, algorithm: .ecdsaSignatureMessageRFC4754SHA256)
    }

    func signMessageECDSA_DER(_ message: Data) -> Data {
        sign(message, algorithm: .ecdsaSignatureMessageX962SHA256)
    }

    func publicKey() -> Unmanaged<SecKey> {
        Unmanaged.passUnretained(publicKeyRef)
    }

    func copyPublicKey() -> SecKey {
        publicKeyRef
    }
}
