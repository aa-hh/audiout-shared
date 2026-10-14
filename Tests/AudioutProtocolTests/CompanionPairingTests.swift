// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import AudioutProtocol

/// Known answers for the handshake bytes. Each expected value was computed
/// outside Swift with coreutils, by the command in the comment above it, so
/// the Mac and the phone are checked against the same independent numbers.
@Suite struct CompanionPairingTests {

    private static let nonce = Data(repeating: 0x01, count: 32)
    private static let fingerprint = Data(repeating: 0x02, count: 32)
    private static let publicKey = Data(repeating: 0x03, count: 64)

    // Turns red if `clientID(forPublicKey:)` stops being the uppercase hex
    // SHA-256 of the raw key.
    // `head -c 64 /dev/zero | sha256sum`
    // → f5a5fd42d16a20302798ef6ed309979b43003d2320d9f0e8ea9831a92759fb4b
    @Test func clientIDIsTheUppercaseKeyHash() {
        #expect(CompanionPairing.clientID(forPublicKey: Data(count: 64))
            == "F5A5FD42D16A20302798EF6ED309979B43003D2320D9F0E8EA9831A92759FB4B")
    }

    // Turns red if the signed input gains a separator, changes order, or its
    // context string changes.
    // `printf 'audiout-companion-auth-v1' | od -An -tu1`
    // → 97 117 100 105 111 117 116 45 99 111 109 112 97 110 105 111
    //   110 45 97 117 116 104 45 118 49
    @Test func authenticationMessageIsContextThenNonceThenFingerprint() {
        let message = CompanionPairing.authenticationMessage(
            serverNonce: Self.nonce, serverCertificateSHA256: Self.fingerprint)
        let context: [UInt8] = [
            97, 117, 100, 105, 111, 117, 116, 45, 99, 111, 109, 112, 97, 110, 105, 111,
            110, 45, 97, 117, 116, 104, 45, 118, 49,
        ]
        #expect(message.count == 25 + 32 + 32)
        #expect(Array(message.prefix(25)) == context)
        #expect(message.dropFirst(25).prefix(32) == Self.nonce)
        #expect(message.suffix(32) == Self.fingerprint)
    }

    // `{ printf 'audiout-companion-pair-v1'; head -c 32 /dev/zero | tr '\0' '\002'; head -c 64 /dev/zero | tr '\0' '\003'; } | sha256sum`
    // → d5b99dbec7a9b6d662c1dc876710e021c19d1b283e63637260dd4b1ad80940aa
    // `printf '%06d\n' $(( 0xd5b99dbe % 1000000 ))` → 711550
    // Turns red if the pairing code's hash input, byte order or modulus
    // changes, so the two screens would show different codes.
    @Test func pairingCodeIsTheFirstFourHashBytesModAMillion() {
        #expect(CompanionPairing.pairingCode(
            serverCertificateSHA256: Self.fingerprint, clientPublicKey: Self.publicKey) == "711550")
    }

    // Turns red if the instance name stops being "Audiout-" plus the first
    // 8 uppercase hex characters of the fingerprint.
    // `head -c 32 /dev/zero | tr '\0' '\002' | od -An -tx1 | tr -d ' \n' | cut -c1-8` → 02020202
    @Test func instanceNameCarriesTheFingerprintPrefix() {
        #expect(CompanionPairing.instanceName(serverCertificateSHA256: Self.fingerprint) == "Audiout-02020202")
    }

    // Turns red if `fingerprint(fromHex:)` accepts a value that is not
    // exactly 64 hex characters, or stops reading what `fingerprintHex` writes.
    @Test func fingerprintFromHexRefusesWrongLengthAndNonHex() {
        let hex = CompanionPairing.fingerprintHex(Self.fingerprint)
        #expect(hex == String(repeating: "02", count: 32))
        #expect(CompanionPairing.fingerprint(fromHex: hex) == Self.fingerprint)
        #expect(CompanionPairing.fingerprint(fromHex: String(hex.dropLast())) == nil)
        #expect(CompanionPairing.fingerprint(fromHex: String(hex.dropLast()) + "g") == nil)
    }
}
