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

    static let rate = 24_000.0

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
    static func addProgram(to buffer: inout [Double], rate: Double,
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

    static func programSlice(seconds: Double, rate: Double, gain: Double = 1) -> [Float] {
        var buffer = [Double](repeating: 0, count: Int(seconds * rate))
        addProgram(to: &buffer, rate: rate, delaySeconds: 0, gain: gain)
        return buffer.map(Float.init)
    }

    /// A capture of one or more speakers playing the same program at given
    /// fractional delays, plus mic noise at `snrDB`.
    static func capture(seconds: Double, rate: Double,
                                arrivals: [(delayMs: Double, gain: Double)],
                                snrDB: Double, seed: UInt64 = 7,
                                program: (inout [Double], Double, Double, Double) -> Void
                                    = { addProgram(to: &$0, rate: $1, delaySeconds: $2, gain: $3) }) -> [Float] {
        let count = Int(seconds * rate)
        var clean = [Double](repeating: 0, count: count)
        for arrival in arrivals {
            program(&clean, rate, arrival.delayMs / 1000, arrival.gain)
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

    /// Pop-mix-like program whose power sits mostly in the bass, the way a
    /// real vocal pop mix does: a bass line (50–120 Hz plus a second
    /// harmonic) changing note every 0.5 s, a held three-note chord in the
    /// low mids, and plucked transients — sixteen inharmonic partials across
    /// 700 Hz–7.7 kHz decaying over ~40 ms — on an irregular seeded rhythm.
    ///
    /// Everything is a closed-form function of time, so a fractional delay is
    /// exact by construction, for the same reason as ``lines``.
    private static let bassNotesHz: [Double] = [55, 82.4, 73.4, 98, 61.7, 110, 65.4, 87.3]
    private static let chordsHz: [[Double]] = [[220, 277.2, 329.6], [246.9, 311.1, 370],
                                               [196, 246.9, 293.7], [261.6, 329.6, 392]]
    private static let onsets: [Double] = {
        var rng = SeededRNG(seed: 11)
        var times: [Double] = []
        var t = -1.0
        while t < 4 { times.append(t); t += Double.random(in: 0.09...0.33, using: &rng) }
        return times
    }()
    private static let noteSeconds = 0.5

    private static func addPopMix(to buffer: inout [Double], rate: Double,
                                  delaySeconds: Double, gain: Double,
                                  bass: Bool = true, rest: Bool = true) {
        for i in 0..<buffer.count {
            let t = Double(i) / rate - delaySeconds
            let note = Int((t / noteSeconds).rounded(.down))
            let into = t - Double(note) * noteSeconds
            let envelope = max(0, min(1, into / 0.01, (noteSeconds - into) / 0.01))
            var sample = 0.0
            if bass {
                let hz = bassNotesHz[((note % bassNotesHz.count) + bassNotesHz.count) % bassNotesHz.count]
                sample += 0.3 * sin(2 * .pi * hz * t) + 0.09 * sin(4 * .pi * hz * t)
            }
            if rest {
                for hz in chordsHz[((note % chordsHz.count) + chordsHz.count) % chordsHz.count] {
                    sample += 0.08 * sin(2 * .pi * hz * t)
                }
            }
            buffer[i] += gain * envelope * sample
        }
        guard rest else { return }
        let ring = 0.2
        for (n, onset) in onsets.enumerated() {
            let first = max(0, Int(((onset + delaySeconds) * rate).rounded(.up)))
            let last = min(buffer.count, Int(((onset + ring + delaySeconds) * rate).rounded(.down)))
            guard first < last else { continue }
            for i in first..<last {
                let age = Double(i) / rate - delaySeconds - onset
                let decay = exp(-age / 0.04)
                var sample = 0.0
                for k in 0..<16 {
                    let hz = 700 * pow(11, Double(k) / 15) + 23.1 * sin(Double(k * 7 + n))
                    sample += 0.1 * sin(2 * .pi * hz * age + Double(n * 3 + k))
                }
                buffer[i] += gain * decay * sample
            }
        }
    }

    private static func power(_ x: [Double]) -> Double { x.reduce(0) { $0 + $1 * $1 } / Double(x.count) }

    /// Real vocal pop through two speakers was refused as `referenceTooPeriodic`
    /// in every window (live, 2026-09-13): a bass note repeats every 5–25 ms,
    /// so the energy-weighted self-correlation sits near ±1 at one bass period.
    /// Red if the suitability checks and the matched filter judge the full-band
    /// signal instead of the band the timing lives in — remove the band-limit
    /// in `PassiveDriftCorrelator.analyze` and this fails that way again.
    @Test func recoversDelaysThroughBassHeavyMusic() {
        let rate = Self.rate
        var reference = [Double](repeating: 0, count: Int(1.0 * rate))
        Self.addPopMix(to: &reference, rate: rate, delaySeconds: 0, gain: 1)
        var bassOnly = [Double](repeating: 0, count: reference.count)
        Self.addPopMix(to: &bassOnly, rate: rate, delaySeconds: 0, gain: 1, rest: false)
        let bassShare = Self.power(bassOnly) / Self.power(reference)
        #expect(bassShare > 0.6, "fixture must be bass-dominated, got \(bassShare)")

        let tape = Self.capture(seconds: 2.0, rate: rate,
                                arrivals: [(37.4, 0.5), (205.9, 0.35)], snrDB: 15,
                                program: { Self.addPopMix(to: &$0, rate: $1, delaySeconds: $2, gain: $3) })

        let outcome = PassiveDriftCorrelator().analyze(
            reference: reference.map(Float.init), referenceRate: rate,
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

    /// A window refused as `.noConvincingPeak` still names its best candidate,
    /// so a live refusal tells "scored just under the threshold" apart from
    /// "arrival outside the window". Red if candidates come from the thresholded
    /// search (then empty here), or are dropped whenever the outcome is unusable.
    @Test func refusedWindowStillReportsItsBestCandidate() {
        let rate = Self.rate
        let reference = Self.programSlice(seconds: 1.0, rate: rate)
        let tape = Self.capture(seconds: 2.0, rate: rate, arrivals: [(118.2, 0.5)], snrDB: 15)
        var correlator = PassiveDriftCorrelator()
        correlator.minPeakToSidelobe = 50  // well above what this scene's true arrival scores

        let result = correlator.analyzeWithCandidates(
            reference: reference, referenceRate: rate,
            capture: tape, captureRate: rate,
            expectedDelaysMs: [120], searchHalfWidthMs: 120)

        #expect(result.outcome == .unusable(.noConvincingPeak))
        #expect(result.candidates.count == 1)
        if let candidate = result.candidates.first {
            #expect(abs(candidate.delayMs - 118.2) < 1)
            #expect(candidate.confidence < 50)
        }
    }

    /// The correlation slice a refused window hands back, so a later stage can
    /// sum several windows' evidence instead of throwing each one away.
    ///
    /// Red if slices come back offset from `firstLagMs` or not one per
    /// expected delay, so anything summing them adds unrelated lags.
    @Test func reportsOneCorrelationSlicePerExpectedDelay() {
        let rate = Self.rate
        let reference = Self.programSlice(seconds: 1.0, rate: rate)
        let tape = Self.capture(seconds: 2.0, rate: rate, arrivals: [(118.2, 0.5)], snrDB: 15)
        var correlator = PassiveDriftCorrelator()
        correlator.minPeakToSidelobe = 50  // well above what this scene's true arrival scores

        let result = correlator.analyzeWithCandidates(
            reference: reference, referenceRate: rate,
            capture: tape, captureRate: rate,
            expectedDelaysMs: [120], searchHalfWidthMs: 120)

        #expect(result.slices.count == 1)
        guard let slice = result.slices.first else { return }
        #expect(slice.firstLagMs == 0)
        #expect(slice.lagStepMs == 1000 / rate)
        // The window is centred on 120 ms and reaches 120 ms either side, so
        // it starts at lag 0 and holds one sample per lag up to 240 ms.
        #expect(slice.values.count == 2 * Int((0.120 * rate).rounded()) + 1)
        #expect(slice.bestLagMs.map { abs($0 - 118.2) < 1 } == true)

        let argmax = slice.values.indices.max(by: { slice.values[$0] < slice.values[$1] }) ?? 0
        let peakLagMs: Double = slice.firstLagMs + Double(argmax) * slice.lagStepMs
        #expect(abs(peakLagMs - 118.2) < 1)
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
    /// Two speakers 40 ms apart, searched with the ±120 ms windows the Mac
    /// actually uses, are two arrivals.
    ///
    /// Both windows hold both arrivals, so both baselines pick the same global
    /// maximum and the second speaker is lost — that is what the live code
    /// did, and it is what made a forced +40 ms trim unreadable. The baseline
    /// nearest the shared peak keeps it now and the other looks again with
    /// that lag ruled out. Red if that resolution is removed: one peak comes
    /// back, and the `peaks.count == 2` line fails.
    @Test func resolvesTwoSpeakersWhoseSearchWindowsOverlap() {
        let rate = Self.rate
        let reference = Self.programSlice(seconds: 1.0, rate: rate)
        let tape = Self.capture(seconds: 2.0, rate: rate,
                                arrivals: [(120.0, 0.5), (160.0, 0.42)], snrDB: 15)

        let outcome = PassiveDriftCorrelator().analyze(
            reference: reference, referenceRate: rate,
            capture: tape, captureRate: rate,
            expectedDelaysMs: [160, 120], searchHalfWidthMs: 120)

        guard case .usable(let peaks) = outcome else {
            Issue.record("expected both speakers, got \(outcome)")
            return
        }
        #expect(peaks.count == 2)
        let delays = peaks.map(\.delayMs).sorted()
        #expect(abs(delays[0] - 120.0) < 1)
        #expect(abs(delays[1] - 160.0) < 1)
    }

    /// One arrival inside two overlapping windows stays ONE arrival.
    ///
    /// The caller reads a peak that is the only peak in two speakers' windows
    /// as those speakers having arrived together, and acts by leaving them
    /// alone. The second look that the test above relies on must therefore
    /// offer a candidate, not invent an arrival: with nothing else in the
    /// capture, what it finds is background and the gates and the band vote
    /// refuse it.
    @Test func oneArrivalInTwoWindowsStaysOneArrival() {
        let rate = Self.rate
        let reference = Self.programSlice(seconds: 1.0, rate: rate)
        let tape = Self.capture(seconds: 2.0, rate: rate, arrivals: [(140.0, 0.5)], snrDB: 15)

        let outcome = PassiveDriftCorrelator().analyze(
            reference: reference, referenceRate: rate,
            capture: tape, captureRate: rate,
            expectedDelaysMs: [137, 143], searchHalfWidthMs: 120)

        guard case .usable(let peaks) = outcome else {
            Issue.record("expected the one arrival, got \(outcome)")
            return
        }
        #expect(peaks.count == 1)
        #expect(abs(peaks[0].delayMs - 140.0) < 1)
    }

    /// Two speakers a millisecond and a half apart are two arrivals; half a
    /// millisecond apart they are one. `peakSeparationSeconds` draws that line
    /// at 1 ms, where a plain matched filter's 5 ms merged a resolved pair
    /// back into a single reported arrival — and a merged arrival means
    /// something to the caller: one peak alone in two speakers' windows is how
    /// it decides those speakers are in sync. Red at the old 5 ms, which
    /// reports the 1.5 ms pair as one.
    ///
    /// The search windows here are narrow, one per arrival, because that is
    /// the only arrangement in which the two windows pick different lags and
    /// the separation rule has anything to decide.
    @Test(arguments: [(gapMs: 1.5, expectedPeaks: 2), (gapMs: 0.5, expectedPeaks: 1)])
    func separatesArrivalsOverAMillisecondApart(gapMs: Double, expectedPeaks: Int) {
        let rate = Self.rate
        let first = 37.4
        let reference = Self.programSlice(seconds: 1.0, rate: rate)
        let tape = Self.capture(seconds: 2.0, rate: rate,
                                arrivals: [(first, 0.5), (first + gapMs, 0.5)], snrDB: 15)

        let outcome = PassiveDriftCorrelator().analyze(
            reference: reference, referenceRate: rate,
            capture: tape, captureRate: rate,
            expectedDelaysMs: [first, first + gapMs], searchHalfWidthMs: gapMs / 2)

        guard case .usable(let peaks) = outcome else {
            Issue.record("expected the \(gapMs) ms pair to be measurable, got \(outcome)")
            return
        }
        #expect(peaks.count == expectedPeaks)
    }

}
