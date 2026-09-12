// Copyright (C) 2026 ahh and contributors.
// SPDX-License-Identifier: MIT
//
// LICENSE-CLEAN by design, like the files under test: MIT, not GPL.

import Foundation
import Testing
@testable import ProbeKit

/// Correlating a mic capture against retained program audio: does it recover
/// the delays of several speakers playing the same music, and does it refuse a
/// slice of music that cannot carry a timing measurement?
///
/// The reference here is deliberately NOT a sweep — a sweep would pass every
/// suitability check and hide the whole point of this path.
@Suite struct PassiveDriftCorrelatorTests {

    /// SplitMix64 — a seed pins a whole synthetic scene, so a failure is
    /// reproducible rather than a mood.
    private struct SeededRNG: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private static let rate = 24_000.0

    /// Music-like program: 384 inharmonic lines spread over 200 Hz–9 kHz,
    /// four of them amplitude-modulated at slow rates so the material has a
    /// changing envelope rather than a steady hiss.
    ///
    /// Sinusoids rather than sampled noise, because a sinusoid survives a
    /// FRACTIONAL time shift exactly — a delayed arrival is the same line with
    /// a different starting phase, so the expected answer stays exact by
    /// construction and no resampler of the test's own sits between the
    /// fixture and the claim. Enough lines, irregularly spaced, that the sum's
    /// autocorrelation dies within a millisecond the way real broadband
    /// program material does.
    private static let lines: [(hz: Double, gain: Double, phase: Double, modHz: Double)] =
        (0..<384).map { k in
            let ratio = Double(k) / 383
            let hz = 200 * pow(45, ratio) + 13.7 * sin(Double(k) * 2.399)
            return (hz: hz, gain: 0.035, phase: Double(k) * 1.7,
                    modHz: k % 96 == 0 ? 2.3 + Double(k) / 96 : 0)
        }

    /// The program as heard `delaySeconds` late, summed into `buffer`.
    ///
    /// Each line advances by a fixed phase step per sample (one complex
    /// multiply), so a two-second scene costs a few million multiplies instead
    /// of 20 million `sin` calls.
    private static func addProgram(to buffer: inout [Double], rate: Double,
                                   delaySeconds: Double, gain: Double) {
        for line in lines {
            let step = 2 * .pi * line.hz / rate
            let start = line.phase - 2 * .pi * line.hz * delaySeconds
            let stepCos = cos(step), stepSin = sin(step)
            var re = cos(start), im = sin(start)
            let modStep = 2 * .pi * line.modHz / rate
            for i in 0..<buffer.count {
                var amplitude = gain * line.gain
                if line.modHz > 0 {
                    amplitude *= 0.6 + 0.4 * sin(modStep * Double(i) + line.phase)
                }
                buffer[i] += amplitude * im
                let nextRe = re * stepCos - im * stepSin
                im = re * stepSin + im * stepCos
                re = nextRe
            }
        }
    }

    private static func programSlice(seconds: Double, rate: Double, gain: Double = 1) -> [Float] {
        var buffer = [Double](repeating: 0, count: Int(seconds * rate))
        addProgram(to: &buffer, rate: rate, delaySeconds: 0, gain: gain)
        return buffer.map(Float.init)
    }

    /// A capture of one or more speakers playing the same program at given
    /// fractional delays, plus mic noise at `snrDB`.
    private static func capture(seconds: Double, rate: Double,
                                arrivals: [(delayMs: Double, gain: Double)],
                                snrDB: Double, seed: UInt64 = 7) -> [Float] {
        let count = Int(seconds * rate)
        var clean = [Double](repeating: 0, count: count)
        for arrival in arrivals {
            addProgram(to: &clean, rate: rate,
                       delaySeconds: arrival.delayMs / 1000, gain: arrival.gain)
        }
        let signalRMS = (clean.reduce(0) { $0 + $1 * $1 } / Double(count)).squareRoot()
        let noiseRMS = signalRMS / pow(10, snrDB / 20)
        var rng = SeededRNG(seed: seed)
        return (0..<count).map { i in
            // Sum of four uniforms — near enough Gaussian for a noise floor.
            var u = 0.0
            for _ in 0..<4 { u += Double.random(in: -1...1, using: &rng) }
            return Float(clean[i] + noiseRMS * u * 0.866)
        }
    }

    /// Two speakers playing one program, both delays recovered within ±1 ms.
    /// Red if the correlator reports a single arrival per capture, or if the
    /// windowed search collapses both windows onto the same peak.
    @Test func recoversTwoSpeakerDelays() {
        let rate = Self.rate
        let reference = Self.programSlice(seconds: 1.0, rate: rate)
        let tape = Self.capture(seconds: 2.0, rate: rate,
                                arrivals: [(37.4, 0.5), (205.9, 0.35)], snrDB: 15)

        let outcome = PassiveDriftCorrelator().analyze(
            reference: reference, referenceRate: rate,
            capture: tape, captureRate: rate,
            expectedDelaysMs: [40, 200], searchHalfWidthMs: 120)

        guard case .usable(let peaks) = outcome else {
            Issue.record("expected two arrivals, got \(outcome)")
            return
        }
        #expect(peaks.count == 2)
        let delays = peaks.map(\.delayMs).sorted()
        #expect(abs(delays[0] - 37.4) < 1)
        #expect(abs(delays[1] - 205.9) < 1)
        #expect(peaks.allSatisfy { $0.confidence >= 3 })
    }

    /// The Mac retains at 44.1 kHz and a microphone commonly captures at
    /// 48 kHz. Red if the reference is correlated at its own rate, which would
    /// scale every delay by 48/44.1 — a 9% error reported confidently.
    @Test func reconcilesMismatchedSampleRates() {
        let reference = Self.programSlice(seconds: 0.5, rate: 44_100)
        let tape = Self.capture(seconds: 1.0, rate: 48_000,
                                arrivals: [(120.3, 0.5)], snrDB: 20)

        let outcome = PassiveDriftCorrelator().analyze(
            reference: reference, referenceRate: 44_100,
            capture: tape, captureRate: 48_000,
            expectedDelaysMs: [120], searchHalfWidthMs: 120)

        guard case .usable(let peaks) = outcome, let first = peaks.first else {
            Issue.record("expected one arrival, got \(outcome)")
            return
        }
        #expect(abs(first.delayMs - 120.3) < 1)
    }

    /// A near-silent passage must be refused, not measured. Red if the
    /// suitability check is dropped: noise correlated against noise still
    /// produces a best lag, and it would be reported as a delay.
    @Test func refusesAQuietSlice() {
        let rate = Self.rate
        let reference = Self.programSlice(seconds: 1.0, rate: rate, gain: 0.000_5)
        let tape = Self.capture(seconds: 2.0, rate: rate,
                                arrivals: [(50, 0.000_5)], snrDB: 15)

        let outcome = PassiveDriftCorrelator().analyze(
            reference: reference, referenceRate: rate,
            capture: tape, captureRate: rate,
            expectedDelaysMs: [50], searchHalfWidthMs: 120)

        #expect(outcome == .unusable(.referenceTooQuiet))
    }

    /// A program that repeats inside the search window is refused: every
    /// repeat matches as well as the true arrival, so the best lag is a coin
    /// toss. Red if the periodicity check goes away.
    @Test func refusesAStronglyPeriodicSlice() {
        let rate = Self.rate
        let period = Int(0.1 * rate)
        var rng = SeededRNG(seed: 3)
        let burst = (0..<Int(0.005 * rate)).map { _ in Float(Double.random(in: -0.5...0.5, using: &rng)) }
        var reference = [Float](repeating: 0, count: Int(1.0 * rate))
        for start in stride(from: 0, to: reference.count - burst.count, by: period) {
            for (i, sample) in burst.enumerated() { reference[start + i] = sample }
        }

        let outcome = PassiveDriftCorrelator().analyze(
            reference: reference, referenceRate: rate,
            capture: reference + reference, captureRate: rate,
            expectedDelaysMs: [50], searchHalfWidthMs: 120)

        #expect(outcome == .unusable(.referenceTooPeriodic))
    }

    /// A held tone carries no timing information whatever its level: the
    /// matched filter's resolution is set by bandwidth. Red if the bandwidth
    /// check is removed, or moved after the periodicity check — a tone trips
    /// both, and the bandwidth reason is the actionable one for logging.
    @Test func refusesANarrowbandSlice() {
        let rate = Self.rate
        let count = Int(1.0 * rate)
        let reference = (0..<count).map { Float(0.4 * sin(2 * .pi * 500 * Double($0) / rate)) }

        let outcome = PassiveDriftCorrelator().analyze(
            reference: reference, referenceRate: rate,
            capture: reference + reference, captureRate: rate,
            expectedDelaysMs: [50], searchHalfWidthMs: 120)

        #expect(outcome == .unusable(.referenceTooNarrowband))
    }

    /// The lag search stays inside the caller's window. Red if the search runs
    /// over the whole tape: the real arrival at 205 ms would then be reported
    /// as the 600 ms speaker's delay — a confident wrong attribution, which is
    /// exactly what music self-similarity would otherwise produce.
    @Test func searchStaysInsideTheWindow() {
        let rate = Self.rate
        let reference = Self.programSlice(seconds: 1.0, rate: rate)
        let tape = Self.capture(seconds: 2.0, rate: rate,
                                arrivals: [(205.9, 0.5)], snrDB: 15)

        let outcome = PassiveDriftCorrelator().analyze(
            reference: reference, referenceRate: rate,
            capture: tape, captureRate: rate,
            expectedDelaysMs: [600], searchHalfWidthMs: 120)

        #expect(outcome == .unusable(.noConvincingPeak))
    }
}
