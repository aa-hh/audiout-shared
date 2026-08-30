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
    let ramps: [String: FieldRamp]
}

/// DATA ONLY. This carries no drawing code — each surface draws the field in
/// its own technology (WebGL on the site, SVG for the static card, Metal in
/// the Mac app). A port reads these numbers; it never retypes them.
public enum AudioutField {
    public static let defaults: FieldDefaults = file.defaults
    public static let ramps: [String: FieldRamp] = file.ramps

    private static let file: FieldFile = {
        guard let url = Bundle.module.url(forResource: "field", withExtension: "json") else {
            fatalError("AudioutField: field.json is missing from Bundle.module — the package is broken.")
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(FieldFile.self, from: data)
        } catch {
            fatalError("AudioutField: field.json failed to decode (\(error)) — the package is broken.")
        }
    }()
}
