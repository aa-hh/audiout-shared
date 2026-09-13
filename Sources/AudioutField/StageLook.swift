// Copyright (C) 2026 ahh and contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The five things the alignment stage can be showing.
public enum StageLookState: String, CaseIterable, Sendable {
    case measuring
    case snapped
    case locked
    case byEar
    case dormant
}

/// Every number one stage state draws with: the halo's size and strength, the
/// core, the wire, the ticks and their spacing in milliseconds, the span and
/// its shadow, the visible window, the breath, and how much of the ruler is
/// filled. `windowSpanMs` is absent when the state shows no bounded window;
/// `breathePeriod` is absent when the state does not breathe, and its
/// amplitude is then 1.
public struct StageLook: Decodable, Equatable, Sendable {
    public let haloDiameter: Double
    public let haloOpacity: Double
    public let coreRadius: Double
    public let wireOpacity: Double
    public let tickHalfHeight: Double
    public let tickOpacity: Double
    public let spanOpacity: Double
    public let spanHeight: Double
    public let spanShadowRadius: Double
    public let windowSpanMs: Double?
    public let tickStepMs: Double
    public let breathePeriod: Double?
    public let breatheAmplitude: Double
    public let rulerFill: Double
}

private struct StageLookFile: Decodable {
    let schema: Int
    let looks: [String: StageLook]
}

extension AudioutField {
    /// DATA ONLY, like the rest of this target: no drawing code, no animation,
    /// no view types. The phone reads this table and draws the stage in
    /// SwiftUI; the Mac keeps its own copy of these numbers until it adopts
    /// this one, at which point the two ends stop being able to drift apart.
    public static let stageLooks: [StageLookState: StageLook] = {
        guard let url = bundle.url(forResource: "stage-look", withExtension: "json") else {
            fatalError("AudioutField: stage-look.json is missing from its resource bundle — the package is broken.")
        }
        let file: StageLookFile
        do {
            let data = try Data(contentsOf: url)
            file = try JSONDecoder().decode(StageLookFile.self, from: data)
        } catch {
            fatalError("AudioutField: stage-look.json failed to decode (\(error)) — the package is broken.")
        }
        var looks: [StageLookState: StageLook] = [:]
        for (key, look) in file.looks {
            guard let state = StageLookState(rawValue: key) else {
                fatalError("AudioutField: stage-look.json names an unknown stage state '\(key)' — the package is broken.")
            }
            looks[state] = look
        }
        for state in StageLookState.allCases where looks[state] == nil {
            fatalError("AudioutField: stage-look.json has no look for '\(state.rawValue)' — the package is broken.")
        }
        return looks
    }()
}
