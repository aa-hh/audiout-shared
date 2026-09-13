// Copyright (C) 2026 ahh and contributors.
// SPDX-License-Identifier: MIT

import Testing
@testable import AudioutField

/// Pins every slot of every stage look, so a value that drifts from the spec's
/// table — or a slot transposed with the one beside it — fails a build instead
/// of a screenshot nobody compares.
@Suite struct StageLookTests {
    @Test func everyStateHasALook() {
        #expect(AudioutField.stageLooks.count == 5)
        for state in StageLookState.allCases {
            #expect(AudioutField.stageLooks[state] != nil, "no look for \(state.rawValue)")
        }
    }

    @Test func measuring() {
        let look = AudioutField.stageLooks[.measuring]
        #expect(look?.haloDiameter == 198)
        #expect(look?.haloOpacity == 0.65)
        #expect(look?.coreRadius == 47)
        #expect(look?.wireOpacity == 0.66)
        #expect(look?.tickHalfHeight == 4.75)
        #expect(look?.tickOpacity == 0.48)
        #expect(look?.spanOpacity == 0.22)
        #expect(look?.spanHeight == 1.5)
        #expect(look?.spanShadowRadius == 3)
        #expect(look?.windowSpanMs == nil)
        #expect(look?.tickStepMs == 250)
        #expect(look?.breathePeriod == 1.3)
        #expect(look?.breatheAmplitude == 1.055)
        #expect(look?.rulerFill == 0.78)
    }

    @Test func snapped() {
        let look = AudioutField.stageLooks[.snapped]
        #expect(look?.haloDiameter == 88)
        #expect(look?.haloOpacity == 1.0)
        #expect(look?.coreRadius == 23)
        #expect(look?.wireOpacity == 1.0)
        #expect(look?.tickHalfHeight == 7)
        #expect(look?.tickOpacity == 0.85)
        #expect(look?.spanOpacity == 0)
        #expect(look?.spanHeight == 3.5)
        #expect(look?.spanShadowRadius == 5)
        #expect(look?.windowSpanMs == 64)
        #expect(look?.tickStepMs == 10)
        #expect(look?.breathePeriod == 2.7)
        #expect(look?.breatheAmplitude == 1.021)
        #expect(look?.rulerFill == 1)
    }

    @Test func locked() {
        let look = AudioutField.stageLooks[.locked]
        #expect(look?.haloDiameter == 190)
        #expect(look?.haloOpacity == 1.0)
        #expect(look?.coreRadius == 29)
        #expect(look?.wireOpacity == 1.0)
        #expect(look?.tickHalfHeight == 7)
        #expect(look?.tickOpacity == 0.85)
        #expect(look?.spanOpacity == 0)
        #expect(look?.spanHeight == 3.5)
        #expect(look?.spanShadowRadius == 5)
        #expect(look?.windowSpanMs == 64)
        #expect(look?.tickStepMs == 10)
        #expect(look?.breathePeriod == nil)
        #expect(look?.breatheAmplitude == 1.0)
        #expect(look?.rulerFill == 1)
    }

    @Test func byEar() {
        let look = AudioutField.stageLooks[.byEar]
        #expect(look?.haloDiameter == 78)
        #expect(look?.haloOpacity == 1.0)
        #expect(look?.coreRadius == 23)
        #expect(look?.wireOpacity == 1.0)
        #expect(look?.tickHalfHeight == 7)
        #expect(look?.tickOpacity == 0.85)
        #expect(look?.spanOpacity == 1.0)
        #expect(look?.spanHeight == 3.5)
        #expect(look?.spanShadowRadius == 5)
        #expect(look?.windowSpanMs == 64)
        #expect(look?.tickStepMs == 10)
        #expect(look?.breathePeriod == 2.0)
        #expect(look?.breatheAmplitude == 1.021)
        #expect(look?.rulerFill == 1)
    }

    @Test func dormant() {
        let look = AudioutField.stageLooks[.dormant]
        #expect(look?.haloDiameter == 0)
        #expect(look?.haloOpacity == 0)
        #expect(look?.coreRadius == 26)
        #expect(look?.wireOpacity == 0.55)
        #expect(look?.tickHalfHeight == 4)
        #expect(look?.tickOpacity == 0.35)
        #expect(look?.spanOpacity == 0)
        #expect(look?.spanHeight == 1.5)
        #expect(look?.spanShadowRadius == 3)
        #expect(look?.windowSpanMs == nil)
        #expect(look?.tickStepMs == 250)
        #expect(look?.breathePeriod == nil)
        #expect(look?.breatheAmplitude == 1.0)
        #expect(look?.rulerFill == 1)
    }
}
