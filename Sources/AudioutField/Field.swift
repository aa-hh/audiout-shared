// Copyright (C) 2026 ahh and contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The tunable numbers behind the brand's emitter field: emitter positions,
/// motion, and the scene ramps' colour stops.
public struct FieldDefaults: Decodable, Sendable {
    public let emitters: [[Double]]
    public let orbit: Double
    public let squash: Double
    public let speedBase: Double
    public let speedStep: Double
    public let densBase: Double
    public let densStep: Double
    public let sharp: Double
    public let fade: Double
    public let wobble: Double
    public let wobbleRate: Double
    public let breatheFloor: Double
    public let breatheDepth: Double
    public let breatheRate: Double
    public let breatheStep: Double
    public let sequence: Bool
    public let cycle: Double
    public let duty: Double
    public let rise: Double
    public let tail: Double
    public let reach: Double
    public let front: Double
    public let emerge: Double
    public let emergeFront: Double
    public let gain: Double
    public let paperLift: Double
}

/// The field's second state: fully emitted, nothing travels outward. Each
/// ring rolls over itself in place (a curl phase runs radially through every
/// crest) while an oval compression lobe slowly orbits the source. Everything
/// not listed here comes from `defaults` unchanged — except `speedBase` /
/// `speedStep`, which this state retires (there is no outward phase term),
/// and the three keys below that deliberately override their `defaults`
/// counterparts. Formula and rulings: `dev/notes/settled-emitter-state.md`
/// in the Mac repo (chosen 2026-09-13).
public struct FieldSettled: Decodable, Sendable {
    /// Multiply the port's time input by this once; every rate here and every
    /// hard-coded rate literal (orbit drift, breathing) then matches the look
    /// as tuned. Do NOT also fold it into individual rates.
    public let timeScale: Double
    /// Overrides `defaults.orbit` (0.1): settled means "moves slightly".
    public let orbit: Double
    /// Strength of the orbiting compression lobe (phase radians).
    public let rollAmp: Double
    /// How fast the lobe circles the source.
    public let rollRate: Double
    /// Radius inside which lobe and curl fade to zero, so the innermost ring
    /// cannot fold into itself. Load-bearing — do not remove.
    public let taper: Double
    /// How far each crest leans as it rolls over itself.
    public let curlAmp: Double
    /// How fast the crest churns over itself.
    public let curlRate: Double
    /// Overrides `defaults.breatheFloor` (0.4): brightness must hold steady.
    public let breatheFloor: Double
    /// Overrides `defaults.breatheDepth` (0.6): same ruling.
    public let breatheDepth: Double
}

/// One scene's colour ramp: low, mid, and peak-intensity stops, each an RGB
/// triple in 0...1.
public struct FieldRamp: Decodable, Sendable {
    public let lo: [Double]
    public let mid: [Double]
    public let peak: [Double]
}

private struct FieldFile: Decodable {
    let schema: Int
    let defaults: FieldDefaults
    let settled: FieldSettled
    let ramps: [String: FieldRamp]
}

/// DATA ONLY. This carries no drawing code — each surface draws the field in
/// its own technology (WebGL on the site, SVG for the static card, Metal in
/// the Mac app). A port reads these numbers; it never retypes them.
public enum AudioutField {
    public static let defaults: FieldDefaults = file.defaults
    public static let settled: FieldSettled = file.settled
    public static let ramps: [String: FieldRamp] = file.ramps

    /// SwiftPM's generated `Bundle.module` accessor checks exactly two places:
    /// the .app ROOT (where macOS codesign refuses to let a bundle live —
    /// "unsealed contents present in the bundle root") and the absolute
    /// build-directory path of the machine that compiled the binary. A
    /// distributed Mac app has neither — the resource bundle ships in
    /// Contents/Resources — so check there first. `Bundle.module` stays as the
    /// fallback for dev builds, tests, and iOS, where bundles do land at the
    /// .app root.
    private static let bundle: Bundle = {
        if let url = Bundle.main.resourceURL?
            .appendingPathComponent("AudioutShared_AudioutField.bundle"),
           let shipped = Bundle(url: url) {
            return shipped
        }
        return Bundle.module
    }()

    private static let file: FieldFile = {
        guard let url = bundle.url(forResource: "field", withExtension: "json") else {
            fatalError("AudioutField: field.json is missing from its resource bundle — the package is broken.")
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(FieldFile.self, from: data)
        } catch {
            fatalError("AudioutField: field.json failed to decode (\(error)) — the package is broken.")
        }
    }()
}
