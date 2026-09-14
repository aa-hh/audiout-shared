// Copyright (C) 2026 ahh and contributors.
// SPDX-License-Identifier: MIT
//
// LICENSE-CLEAN by design, like the files under test: MIT, not GPL.

import Foundation
import Testing
@testable import ProbeKit

/// Summing several windows' correlation so a lag that no single window can
/// stand behind is still recoverable when the windows quietly agree on it.
///
/// Every scene here forces the refusal path — `minPeakToSidelobe = 50` is far
/// above what these captures score — so each window contributes a slice and a
/// candidate, and nothing is accepted on its own. That is the situation the
/// accumulator exists for.
@Suite struct PassiveDriftAccumulatorTests {

    private static let rate = PassiveDriftCorrelatorTests.rate

    /// One refused window's slice: an arrival at `arrivalMs` heard by a
    /// correlator whose baseline sits at `baselineMs`.
    private static func slice(arrivalMs: Double, baselineMs: Double,
                              halfWidthMs: Double, seed: UInt64 = 7) -> DriftSlice {
        let rate = Self.rate
        let reference = PassiveDriftCorrelatorTests.programSlice(seconds: 1.0, rate: rate)
        let tape = PassiveDriftCorrelatorTests.capture(seconds: 2.0, rate: rate,
                                                       arrivals: [(arrivalMs, 0.5)],
                                                       snrDB: 15, seed: seed)
        var correlator = PassiveDriftCorrelator()
        correlator.minPeakToSidelobe = 50
        let result = correlator.analyzeWithCandidates(
            reference: reference, referenceRate: rate,
            capture: tape, captureRate: rate,
            expectedDelaysMs: [baselineMs], searchHalfWidthMs: halfWidthMs)
        return result.slices[0]
    }

    /// Two windows searched around different baselines cover different lag
    /// ranges, so they only add up if each value is placed by the lag it
    /// stands for.
    ///
    /// Red if slices are summed by array index rather than absolute lag, so
    /// windows searched around different baselines add unrelated lags.
    ///
    /// The half-width is 60 ms rather than the app's 120 so the two windows
    /// really do start at different lags — at ±120 ms around 120 and 110 both
    /// windows would be clamped to lag 0 and the defect could not show.
    @Test func sumsWindowsByAbsoluteLagNotByIndex() {
        var accumulator = PassiveDriftAccumulator()
        accumulator.add(Self.slice(arrivalMs: 118.2, baselineMs: 120, halfWidthMs: 60),
                        forKey: "speaker")
        accumulator.add(Self.slice(arrivalMs: 118.2, baselineMs: 110, halfWidthMs: 60, seed: 11),
                        forKey: "speaker")

        guard let answer = accumulator.consensus(forKey: "speaker") else {
            Issue.record("two windows that both heard 118.2 ms should reach a consensus")
            return
        }
        #expect(abs(answer.lagMs - 118.2) < 1)
        #expect(answer.agreeingWindows == 2)
        #expect(answer.windowCount == 2)
    }

    /// Red if a lag only one window's own candidate supports is accepted.
    @Test func refusesALagOnlyOneWindowHeard() {
        var accumulator = PassiveDriftAccumulator()
        accumulator.add(Self.slice(arrivalMs: 118.2, baselineMs: 120, halfWidthMs: 120),
                        forKey: "speaker")
        accumulator.add(Self.slice(arrivalMs: 60.0, baselineMs: 120, halfWidthMs: 120, seed: 11),
                        forKey: "speaker")

        #expect(accumulator.consensus(forKey: "speaker") == nil)
    }

    /// Red if two old windows keep confirming a lag the newest window does not
    /// see, so a verify window can confirm the guess it was meant to check.
    @Test func refusesWhenTheNewestWindowDoesNotAgree() {
        var accumulator = PassiveDriftAccumulator()
        accumulator.add(Self.slice(arrivalMs: 118.2, baselineMs: 120, halfWidthMs: 120),
                        forKey: "speaker")
        accumulator.add(Self.slice(arrivalMs: 118.2, baselineMs: 120, halfWidthMs: 120, seed: 11),
                        forKey: "speaker")
        // The two old windows on their own do reach an answer, so what the
        // third window changes below is the newest-window rule and nothing else.
        #expect(accumulator.consensus(forKey: "speaker")?.agreeingWindows == 2)

        accumulator.add(Self.slice(arrivalMs: 60.0, baselineMs: 120, halfWidthMs: 120, seed: 13),
                        forKey: "speaker")
        #expect(accumulator.consensus(forKey: "speaker") == nil)
    }
}
