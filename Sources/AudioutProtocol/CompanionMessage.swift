// SPDX-License-Identifier: MIT

import Foundation

/// One message on the WebSocket connection between the Mac (`CompanionServer`)
/// and the phone. Client→server: `hello`, `command`. Server→client: `challenge`,
/// `welcome`, `awaitingApproval`, `state`, `commandResult`, `goodbye`,
/// `appIcons`, `alignmentProbeStarted`, `alignmentProbeFinished`,
/// `alignmentApplied`.
/// `.unknown` is a
/// decode-only case: a message type neither side recognizes yet (e.g. a newer
/// peer's message type) decodes into it rather than throwing, so a version
/// skew never crashes the connection — the client ignores it, the server
/// answers a `command`-shaped unknown with a failed `commandResult`.
public enum CompanionMessage: Equatable, Sendable {
    // client -> server

    /// The phone's answer to `challenge`. `clientKey` is base64 of the
    /// phone's 64-byte raw P-256 public key, and `signature` is base64 of
    /// the 64-byte raw ECDSA P-256 SHA-256 signature over
    /// `CompanionPairing.authenticationMessage(serverNonce:serverCertificateSHA256:)`
    /// for this connection's nonce and the Mac's certificate. The Mac checks
    /// the signature before anything else, so only the holder of the private
    /// key can present that key; the approval id is then
    /// `CompanionPairing.clientID(forPublicKey:)`. Both fields are
    /// attacker-controlled input and are never shown to the user —
    /// `clientName` is the only human-facing string. A missing `clientKey`
    /// or `signature` key decodes as `""` (see `CompanionEnvelope`'s
    /// decoder) so the server can refuse it with a reason instead of
    /// dropping the frame as malformed.
    case hello(clientKey: String, clientName: String, protoVersion: Int, signature: String)
    case command(requestID: String, command: CompanionCommand)

    // server -> client
    /// Sent once per connection, before anything else, as soon as the TLS
    /// link is up. `nonce` is base64 of 32 random bytes; the phone signs
    /// `CompanionPairing.authenticationMessage` with it and answers with
    /// `hello`.
    case challenge(nonce: String)
    /// `companionToken` is the licence server's signed token for this Mac's
    /// key (Ed25519 over a JSON payload; the phone verifies it offline), or
    /// `nil` when the Mac has none — an unlicensed or never-checked-in Mac,
    /// or an older Mac whose `welcome` predates the field. It is absent from
    /// the wire when `nil`, so an older phone never sees the key at all.
    /// A `companionToken` that is not a string decodes as `nil` rather than
    /// failing the `welcome`.
    /// `serverID` is a random join id the Mac keeps in its own settings, sent
    /// so an analytics funnel can link this Mac's events to this phone's —
    /// it is never the Mac's analytics distinct id and never any identifier
    /// of the machine itself. `nil` when the Mac predates the field, or (like
    /// `companionToken`) absent from the wire entirely rather than `null`.
    case welcome(serverName: String, protoVersion: Int, snapshot: Snapshot, companionToken: String?, serverID: String? = nil)
    /// The hello was valid but this phone isn't approved yet: the Mac is
    /// showing its user an allow/deny prompt, and holds the connection open
    /// (generously — minutes, not the handshake deadline) until they answer.
    /// The phone should show "check your Mac", not an error. Resolves as a
    /// `welcome` (allowed) or a `goodbye` (`notApproved` / `approvalTimedOut`).
    ///
    /// `screenLocked` is true while the Mac's screen is locked, so the prompt
    /// is out of sight; the phone asks its user to unlock the Mac. The Mac
    /// sends this again, with the new value, whenever the lock changes while
    /// the prompt is up.
    case awaitingApproval(screenLocked: Bool)
    case state(snapshot: Snapshot)
    /// `refusalReason` is the sentence shown to the user. `refusalCode` is one
    /// of `CompanionRefusalCode`'s constants, sent only with `applied: false`
    /// for `activateLicenseKey`; `nil` (absent from the wire) otherwise and
    /// from a Mac that predates the field.
    case commandResult(requestID: String, applied: Bool, refusalReason: String?, autoSwappedCurrentDevice: Bool, refusalCode: String? = nil)
    /// `reason` is one of `CompanionGoodbyeReason`'s constants.
    /// `retryAfterSeconds` is how long until asking again can succeed, sent
    /// only with `pairingPaused`; `nil` (absent from the wire) otherwise.
    case goodbye(reason: String, retryAfterSeconds: Int? = nil)
    /// One page of the icons the phone requested via
    /// `CompanionCommand.requestAppIcons`, at most
    /// `CompanionAppIcons.pageSize` icons per page.
    case appIcons(page: Int, pageCount: Int, icons: [AppIconPayload])
    /// The two moments `ProbeSession` is built to be told about: sweeps
    /// entered the feed, and the last sweep frame entered it. Sent only to
    /// the client that staged the probe (`CompanionCommand.startAlignmentProbe`).
    /// `roomDelaySeconds` is the slowest participating speaker's output delay
    /// in seconds, how long the probe's sound lags the feed, so the phone can
    /// place each speaker's turn; absent from a Mac that predates the field.
    case alignmentProbeStarted(deviceID: String, roomDelaySeconds: Double? = nil)
    /// See `alignmentProbeStarted` — the matching "last sweep frame entered
    /// the feed" moment.
    case alignmentProbeFinished(deviceID: String)
    /// The Mac's own verdict on an alignment report, sent after it applies
    /// (or refuses) the measurement — only to the client that staged the run
    /// for `deviceID`, the same one `alignmentProbeStarted` goes to.
    /// `measuredMs` is the phone's raw report minus the run's own stagger
    /// (signed; positive means the target sounded late).
    /// `correctedMs` is the change the Mac made to the stored latency —
    /// `max(0, value) − applied` (signed; `0` when clamping or flooring left
    /// it where it was).
    /// `source` is the same ``AlignmentSource`` value ``DeviceState/AlignmentState/source``
    /// carries, sent here too so the verdict is labelled the moment it lands
    /// rather than waiting for the next snapshot. `nil` when the Mac predates
    /// the field; treat as `"measured"`.
    case alignmentApplied(deviceID: String, measuredMs: Double, correctedMs: Double, source: String? = nil)
    /// The Mac's licence came through while this phone was already
    /// connected: the same token `welcome` carries, sent to every welcomed
    /// client so a phone locked on a token-less welcome unlocks without
    /// reconnecting.
    case companionToken(String)

    case unknown(type: String)
}

/// Every `goodbye` reason the Mac server actually sends, so the phone can
/// switch on them without string drift. A reason the client doesn't
/// recognize (a newer server's) should be treated like `shutdown`: the
/// server closed deliberately.
public enum CompanionGoodbyeReason {
    /// The user unticked "Allow remote control" — don't redial until the
    /// service reappears in Bonjour.
    public static let disabled = "disabled"
    /// The Mac app is quitting (or the server restarted).
    public static let shutdown = "shutdown"
    /// The client's protocol version is outside what the server accepts:
    /// newer than `CompanionProto.version` or older than
    /// `CompanionProto.minimumPeerVersion`. The goodbye's envelope `v` is
    /// the Mac's own version, so the phone can tell which side needs the
    /// update: a `v` above its own version means update the phone.
    public static let protoMismatch = "protoMismatch"
    /// The server is at its client cap.
    public static let serverFull = "serverFull"
    /// The hello's `clientKey` was missing, not 64 bytes, or not a P-256
    /// point, or arrived before the server's challenge. Terminal for the
    /// phone.
    public static let invalidClientKey = "invalidClientKey"
    /// The signature did not verify over this connection's challenge and
    /// this Mac's certificate. Terminal.
    public static let authenticationFailed = "authenticationFailed"
    /// The Mac's user answered "Don't Allow" for this phone. The Mac keeps
    /// no record of it: asking again raises a new prompt. Don't redial on
    /// your own; wait for the user to ask again.
    public static let notApproved = "notApproved"
    /// The Mac turned this unknown phone away without asking, because its
    /// user said "Don't Allow" several times in a short spell. The goodbye's
    /// `retryAfterSeconds` says how long the pause has left. Phones the Mac
    /// already approved are never paused.
    public static let pairingPaused = "pairingPaused"
    /// The approval prompt sat unanswered past the Mac's deadline. Retryable:
    /// reconnecting asks again.
    public static let approvalTimedOut = "approvalTimedOut"
    /// The Mac's user removed this phone in Settings › Audiout Remote. Terminal: forget the Mac and pair again.
    public static let removed = "removed"
}

/// Every `commandResult` `refusalCode` the Mac sends for `activateLicenseKey`.
/// A code the phone doesn't recognise (a newer Mac's) is final: treat it like
/// `unrecognised`.
public enum CompanionRefusalCode {
    /// The Mac has its own active paid key, different from the phone's, and keeps it.
    public static let alreadyLicensed = "alreadyLicensed"
    /// The Mac is checking another key right now; retrying at once is fine.
    public static let busy = "busy"
    /// The Mac couldn't reach the licence server and restored its previous state.
    public static let serverUnreachable = "serverUnreachable"
    /// The phone's key is refunded or revoked.
    public static let revoked = "revoked"
    /// The licence server doesn't know the key.
    public static let unrecognised = "unrecognised"
    /// This Mac build has no licence server (a dev build).
    public static let cannotCheck = "cannotCheck"
}

/// The allowed values of ``DeviceState/AlignmentState/source`` and
/// `CompanionMessage.alignmentApplied`'s `source`, so neither peer types the
/// strings by hand. See the Mac's `docs/adr/0001-remembered-offset-on-reconnect.md`
/// for why a reconnect keeps the last offset instead of re-measuring, and
/// `dev/notes/bt-latency-stability-research-2026-09-05.md` for why a
/// measurement taken before the speaker settles still needs applying at once.
public enum AlignmentSource {
    /// A measurement taken after the Mac called the speaker settled.
    public static let measured = "measured"
    /// A measurement taken before the speaker settled: applied and labelled
    /// at once, re-checked once the clock reads steady.
    public static let firstPass = "firstPass"
    /// The offset this speaker had when last measured, applied again on
    /// reconnect until a new measurement replaces it.
    public static let fromLastTime = "fromLastTime"
    /// Found through the Mac-only paired-click fallback, no microphone.
    public static let byEar = "byEar"
}

/// The two numbers both peers read so the Mac's keep-or-replace decision and
/// the phone's verdict copy never disagree. See the Mac's
/// `docs/adr/0001-remembered-offset-on-reconnect.md` and
/// `dev/notes/bt-latency-stability-research-2026-09-05.md`.
public enum AlignmentThresholds {
    /// A re-measurement replaces the stored offset at this many milliseconds
    /// of difference or more; below it, the stored offset is kept.
    public static let replaceMs: Double = 10
    /// The phone tells the user only when the applied correction is at least
    /// this many milliseconds.
    public static let tellUserMs: Double = 40
}

/// The wire envelope every WebSocket text frame carries:
/// `{"v": Int, "type": String, "payload": {...}}`. `v` is the SENDER's
/// `CompanionProto.version` — check it (or `hello`/`welcome`'s own
/// `protoVersion` payload field, which duplicates it) with
/// `CompanionProto.isIncompatible(peerVersion:)` before trusting a peer's
/// snapshot/commands; a peer whose version is greater than ours is refused
/// (refuse-forward, mirroring `AppRouteStore.swift`'s
/// `envelope.schemaVersion <= currentSchemaVersion` guard and the Bonjour TXT
/// `proto` check `CompanionProto` itself performs before a connection even
/// opens). A peer older than `CompanionProto.minimumPeerVersion` is refused
/// too.
///
/// Unknown top-level JSON keys inside `payload` are ignored (default
/// `Codable` behavior — we only ever read the keys a given `type` defines).
/// An unrecognized `type` decodes to `CompanionMessage.unknown(type:)`
/// without touching `payload` at all, rather than throwing.
public struct CompanionEnvelope: Equatable, Sendable {
    public var v: Int
    public var message: CompanionMessage

    public init(message: CompanionMessage, v: Int = CompanionProto.version) {
        self.v = v
        self.message = message
    }
}

extension CompanionEnvelope: Codable {
    private enum CodingKeys: String, CodingKey {
        case v, type, payload
    }

    private enum PayloadKeys: String, CodingKey {
        case clientKey, clientName, protoVersion, signature
        case nonce
        case requestID, command
        case serverName, snapshot, companionToken, serverID
        case applied, refusalReason, refusalCode, autoSwappedCurrentDevice
        case screenLocked
        case reason, retryAfterSeconds
        case page, pageCount, icons
        case deviceID
        case measuredMs, correctedMs, source
        case roomDelaySeconds
    }

    private enum TypeName: String {
        case hello, command, challenge, welcome, awaitingApproval, state, commandResult, goodbye, appIcons
        case alignmentProbeStarted, alignmentProbeFinished, alignmentApplied, companionToken
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        let rawType = try c.decode(String.self, forKey: .type)
        guard let type = TypeName(rawValue: rawType) else {
            message = .unknown(type: rawType)
            return
        }
        let payload = try c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
        switch type {
        case .hello:
            message = .hello(
                // `""`, not a throw, for an absent clientKey or signature: the
                // server must refuse it with a REASON (`invalidClientKey` /
                // `authenticationFailed`), which it can only do if the frame
                // still decodes.
                clientKey: try payload.decodeIfPresent(String.self, forKey: .clientKey) ?? "",
                clientName: try payload.decode(String.self, forKey: .clientName),
                protoVersion: try payload.decode(Int.self, forKey: .protoVersion),
                signature: try payload.decodeIfPresent(String.self, forKey: .signature) ?? ""
            )
        case .command:
            message = .command(
                requestID: try payload.decode(String.self, forKey: .requestID),
                command: try payload.decode(CompanionCommand.self, forKey: .command)
            )
        case .challenge:
            message = .challenge(nonce: try payload.decode(String.self, forKey: .nonce))
        case .welcome:
            message = .welcome(
                serverName: try payload.decode(String.self, forKey: .serverName),
                protoVersion: try payload.decode(Int.self, forKey: .protoVersion),
                snapshot: try payload.decode(Snapshot.self, forKey: .snapshot),
                // A malformed token must cost the phone only the token, not the
                // connection; the phone treats nil as "no proof".
                companionToken: try? payload.decodeIfPresent(String.self, forKey: .companionToken),
                serverID: try payload.decodeIfPresent(String.self, forKey: .serverID)
            )
        case .awaitingApproval:
            message = .awaitingApproval(screenLocked: try payload.decode(Bool.self, forKey: .screenLocked))
        case .state:
            message = .state(snapshot: try payload.decode(Snapshot.self, forKey: .snapshot))
        case .commandResult:
            message = .commandResult(
                requestID: try payload.decode(String.self, forKey: .requestID),
                applied: try payload.decode(Bool.self, forKey: .applied),
                refusalReason: try payload.decodeIfPresent(String.self, forKey: .refusalReason),
                autoSwappedCurrentDevice: try payload.decode(Bool.self, forKey: .autoSwappedCurrentDevice),
                refusalCode: try payload.decodeIfPresent(String.self, forKey: .refusalCode)
            )
        case .goodbye:
            message = .goodbye(
                reason: try payload.decode(String.self, forKey: .reason),
                retryAfterSeconds: try payload.decodeIfPresent(Int.self, forKey: .retryAfterSeconds)
            )
        case .appIcons:
            message = .appIcons(
                page: try payload.decode(Int.self, forKey: .page),
                pageCount: try payload.decode(Int.self, forKey: .pageCount),
                icons: try payload.decode([AppIconPayload].self, forKey: .icons)
            )
        case .alignmentProbeStarted:
            message = .alignmentProbeStarted(
                deviceID: try payload.decode(String.self, forKey: .deviceID),
                roomDelaySeconds: try payload.decodeIfPresent(Double.self, forKey: .roomDelaySeconds)
            )
        case .alignmentProbeFinished:
            message = .alignmentProbeFinished(deviceID: try payload.decode(String.self, forKey: .deviceID))
        case .alignmentApplied:
            message = .alignmentApplied(
                deviceID: try payload.decode(String.self, forKey: .deviceID),
                measuredMs: try payload.decode(Double.self, forKey: .measuredMs),
                correctedMs: try payload.decode(Double.self, forKey: .correctedMs),
                source: try payload.decodeIfPresent(String.self, forKey: .source)
            )
        case .companionToken:
            message = .companionToken(try payload.decode(String.self, forKey: .companionToken))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        switch message {
        case .hello(let clientKey, let clientName, let protoVersion, let signature):
            try c.encode(TypeName.hello.rawValue, forKey: .type)
            var payload = c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(clientKey, forKey: .clientKey)
            try payload.encode(clientName, forKey: .clientName)
            try payload.encode(protoVersion, forKey: .protoVersion)
            try payload.encode(signature, forKey: .signature)
        case .command(let requestID, let command):
            try c.encode(TypeName.command.rawValue, forKey: .type)
            var payload = c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(requestID, forKey: .requestID)
            try payload.encode(command, forKey: .command)
        case .challenge(let nonce):
            try c.encode(TypeName.challenge.rawValue, forKey: .type)
            var payload = c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(nonce, forKey: .nonce)
        case .welcome(let serverName, let protoVersion, let snapshot, let companionToken, let serverID):
            try c.encode(TypeName.welcome.rawValue, forKey: .type)
            var payload = c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(serverName, forKey: .serverName)
            try payload.encode(protoVersion, forKey: .protoVersion)
            try payload.encode(snapshot, forKey: .snapshot)
            try payload.encodeIfPresent(companionToken, forKey: .companionToken)
            try payload.encodeIfPresent(serverID, forKey: .serverID)
        case .awaitingApproval(let screenLocked):
            try c.encode(TypeName.awaitingApproval.rawValue, forKey: .type)
            var payload = c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(screenLocked, forKey: .screenLocked)
        case .state(let snapshot):
            try c.encode(TypeName.state.rawValue, forKey: .type)
            var payload = c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(snapshot, forKey: .snapshot)
        case .commandResult(let requestID, let applied, let refusalReason, let autoSwappedCurrentDevice, let refusalCode):
            try c.encode(TypeName.commandResult.rawValue, forKey: .type)
            var payload = c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(requestID, forKey: .requestID)
            try payload.encode(applied, forKey: .applied)
            try payload.encodeIfPresent(refusalReason, forKey: .refusalReason)
            try payload.encode(autoSwappedCurrentDevice, forKey: .autoSwappedCurrentDevice)
            try payload.encodeIfPresent(refusalCode, forKey: .refusalCode)
        case .goodbye(let reason, let retryAfterSeconds):
            try c.encode(TypeName.goodbye.rawValue, forKey: .type)
            var payload = c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(reason, forKey: .reason)
            try payload.encodeIfPresent(retryAfterSeconds, forKey: .retryAfterSeconds)
        case .appIcons(let page, let pageCount, let icons):
            try c.encode(TypeName.appIcons.rawValue, forKey: .type)
            var payload = c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(page, forKey: .page)
            try payload.encode(pageCount, forKey: .pageCount)
            try payload.encode(icons, forKey: .icons)
        case .alignmentProbeStarted(let deviceID, let roomDelaySeconds):
            try c.encode(TypeName.alignmentProbeStarted.rawValue, forKey: .type)
            var payload = c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(deviceID, forKey: .deviceID)
            try payload.encodeIfPresent(roomDelaySeconds, forKey: .roomDelaySeconds)
        case .alignmentProbeFinished(let deviceID):
            try c.encode(TypeName.alignmentProbeFinished.rawValue, forKey: .type)
            var payload = c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(deviceID, forKey: .deviceID)
        case .alignmentApplied(let deviceID, let measuredMs, let correctedMs, let source):
            try c.encode(TypeName.alignmentApplied.rawValue, forKey: .type)
            var payload = c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(deviceID, forKey: .deviceID)
            try payload.encode(measuredMs, forKey: .measuredMs)
            try payload.encode(correctedMs, forKey: .correctedMs)
            try payload.encodeIfPresent(source, forKey: .source)
        case .companionToken(let token):
            try c.encode(TypeName.companionToken.rawValue, forKey: .type)
            var payload = c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(token, forKey: .companionToken)
        case .unknown(let type):
            // Round-trips as whatever it decoded from; there is no payload
            // to re-emit since we never understood its shape.
            try c.encode(type, forKey: .type)
            _ = c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
        }
    }
}

extension CompanionEnvelope {
    /// Top-level encode helper — the only place a `CompanionMessage` gets
    /// turned into wire bytes.
    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Top-level decode helper — the only place wire bytes get turned into a
    /// `CompanionEnvelope`. Never throws on an unrecognized `type` (see
    /// `CompanionMessage.unknown`); only throws on genuinely malformed JSON
    /// (missing `v`/`type`, wrong field types, etc.).
    public static func decode(_ data: Data) throws -> CompanionEnvelope {
        try JSONDecoder().decode(CompanionEnvelope.self, from: data)
    }
}
