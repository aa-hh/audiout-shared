// SPDX-License-Identifier: MIT

/// Bonjour + protocol-version constants shared by the Mac's `CompanionServer`
/// and the iOS app's discovery/connection code. Kept in one place so both
/// sides can never drift on the service type or TXT record keys.
public enum CompanionProto {
    /// Bonjour service type the Mac advertises and the phone browses for.
    public static let serviceType = "_audiout._tcp"

    /// Wire protocol version. Bump only when message/command *semantics*
    /// change in a way an older peer couldn't handle — adding a new command
    /// or message case does not require a bump (an older peer will treat the
    /// unrecognized name as unknown; see `CompanionMessage`'s `.unknown`
    /// case). Changing the *encoding* of an existing case is a protocol
    /// break and must not happen silently — see AudioutProtocol/AGENTS.md.
    /// Version 2 runs the link over TLS and identifies the phone by a signed
    /// public key (`CompanionPairing`), so a version 1 peer cannot complete
    /// a handshake at all. Version 3 drops the Mac's pairing window: any
    /// unknown phone's hello raises the Mac's Allow prompt, the phone no
    /// longer confirms the code itself (`hello` lost `checksPairingCode`),
    /// `awaitingApproval` says whether the Mac's screen is locked, and an
    /// unknown phone may be turned away with `pairingPaused`.
    public static let version = 3

    /// The oldest peer version this side will talk to. A version 2 peer
    /// expects the pairing window and the phone-side code check that
    /// version 3 removed.
    public static let minimumPeerVersion = 3

    /// Bonjour TXT record keys.
    public enum TXTKey {
        /// This peer's `CompanionProto.version`, as a decimal string.
        public static let proto = "proto"
        /// The lowercase hex SHA-256 of the Mac's TLS certificate DER
        /// (`CompanionPairing.fingerprintHex`). The phone dials only a Mac
        /// whose certificate hashes to this value.
        public static let fingerprint = "fp"
        /// The Mac's hardware model code (`hw.model`, for example
        /// `MacBookPro17,1`). Optional; the phone shows
        /// `MacModel.friendlyName(forCode:)` until `welcome` brings the
        /// computer's own name. Never the computer's name itself.
        public static let model = "model"
    }

    /// Version check, run on the Bonjour TXT `proto` key before a socket
    /// opens and again on `hello`/`welcome`'s `protoVersion`. A peer newer
    /// than ours is refused because we don't know what it means; a peer
    /// older than `minimumPeerVersion` is refused because it expects a pairing
    /// flow this version no longer runs. Anything in between is fine to talk to.
    public static func isIncompatible(peerVersion: Int) -> Bool {
        peerVersion > version || peerVersion < minimumPeerVersion
    }
}
