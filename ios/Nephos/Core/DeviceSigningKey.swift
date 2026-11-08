import CryptoKit
import Foundation
import Security

struct DeviceSigningKey: Sendable {
    private struct EnclaveRecord: Codable {
        let version: Int
        let encryptedKey: Data
    }

    let persisted: Data

    static func generate() throws -> Self {
        #if targetEnvironment(simulator) || os(macOS)
            // Simulator and SwiftPM tests use software keys, never simulated hardware protection.
            return Self(persisted: P256.Signing.PrivateKey().rawRepresentation)
        #else
            guard SecureEnclave.isAvailable else {
                throw ClientError.invalid("Secure device signing is unavailable. Your saved session has been kept.")
            }
            var error: Unmanaged<CFError>?
            guard
                let access = SecAccessControlCreateWithFlags(
                    nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, [.privateKeyUsage], &error)
            else {
                if let error { throw error.takeRetainedValue() }
                throw ClientError.invalid("Unable to configure secure device signing.")
            }
            let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
            return Self(
                persisted: try JSONEncoder().encode(EnclaveRecord(version: 1, encryptedKey: key.dataRepresentation)))
        #endif
    }

    var publicKey: P256.Signing.PublicKey {
        get throws {
            if persisted.count == 32 {
                return try P256.Signing.PrivateKey(rawRepresentation: persisted).publicKey
            }
            return try enclaveKey().publicKey
        }
    }

    func signature(for data: Data) throws -> P256.Signing.ECDSASignature {
        if persisted.count == 32 {
            return try P256.Signing.PrivateKey(rawRepresentation: persisted).signature(for: data)
        }
        return try enclaveKey().signature(for: data)
    }

    private func enclaveKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
        let record = try JSONDecoder().decode(EnclaveRecord.self, from: persisted)
        guard record.version == 1, !record.encryptedKey.isEmpty else {
            throw ClientError.invalid("The saved device key is unsupported. Your session has been kept.")
        }
        return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: record.encryptedKey)
    }
}
