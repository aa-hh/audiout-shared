// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// The bytes of the handshake (unchanged since protocol version 2). The Mac and the phone derive every
/// handshake value only through these functions — the client id, the input
/// the phone signs, the six-digit pairing code both screens show, and the
/// Bonjour instance name. Changing any of them is a protocol break: the two
/// ends would compute different bytes and every pairing would fail.
///
/// A public key here is the 64-byte raw form of a P-256 point (x‖y, CryptoKit's
/// `rawRepresentation`); a fingerprint is the 32-byte SHA-256 of the Mac's TLS
/// certificate DER.
public enum CompanionPairing {
    public static let authenticationContext = "audiout-companion-auth-v1"
    public static let pairingCodeContext = "audiout-companion-pair-v1"
    public static let nonceLength = 32
    public static let publicKeyLength = 64
    public static let signatureLength = 64
    public static let fingerprintLength = 32

    /// The phone's id on the Mac, which approvals are keyed on: uppercase hex
    /// of SHA-256 over the 64-byte raw public key.
    public static func clientID(forPublicKey raw: Data) -> String {
        hex(Data(SHA256.hash(data: raw)), uppercase: true)
    }

    /// What the phone signs (ECDSA P-256 SHA-256) and the Mac verifies:
    /// `authenticationContext` as UTF-8, then the server's nonce, then the
    /// certificate fingerprint, with no separators.
    public static func authenticationMessage(serverNonce: Data, serverCertificateSHA256: Data) -> Data {
        Data(authenticationContext.utf8) + serverNonce + serverCertificateSHA256
    }

    /// The six digits both screens show during a first pairing: the first
    /// 4 bytes of SHA-256 over `pairingCodeContext` + fingerprint + public
    /// key, read as a big-endian `UInt32`, modulo 1 000 000, zero-padded
    /// (`"042317"`). The UI inserts the space (`"042 317"`).
    public static func pairingCode(serverCertificateSHA256: Data, clientPublicKey: Data) -> String {
        let digest = Array(SHA256.hash(data: Data(pairingCodeContext.utf8) + serverCertificateSHA256 + clientPublicKey))
        let value = digest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let code = String(value % 1_000_000)
        return String(repeating: "0", count: 6 - code.count) + code
    }

    /// The Mac's Bonjour instance name: `"Audiout-"` and the first 8
    /// characters of the uppercase hex fingerprint. It never carries the
    /// computer's name.
    public static func instanceName(serverCertificateSHA256: Data) -> String {
        "Audiout-" + String(hex(serverCertificateSHA256, uppercase: true).prefix(8))
    }

    /// Lowercase hex of a fingerprint, as the TXT `fp` key carries it.
    public static func fingerprintHex(_ fp: Data) -> String {
        hex(fp, uppercase: false)
    }

    /// Parses a TXT `fp` value. `nil` unless it is exactly 64 hex characters.
    public static func fingerprint(fromHex text: String) -> Data? {
        let chars = Array(text.utf8)
        guard chars.count == fingerprintLength * 2 else { return nil }
        var bytes = Data(capacity: fingerprintLength)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
        }
        return bytes
    }

    private static func hex(_ data: Data, uppercase: Bool) -> String {
        data.map { String(format: uppercase ? "%02X" : "%02x", $0) }.joined()
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
