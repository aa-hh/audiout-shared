// Copyright (C) 2026 ahh and contributors.
// SPDX-License-Identifier: MIT
//
// LICENSE-CLEAN by design, like the files under test: MIT, not GPL.

import Foundation
import Testing
@testable import ProbeKit

/// The reduction of a probe capture to one number: does it recover a known
/// offset at the sample rates a phone actually hands us, does it keep the
/// sign the Mac expects, and does it refuse rather than guess.
///
/// Every scene here uses the SHIPPING probe — the glide over its drone, on
/// both speakers in turn, as the Mac stages it — rather than the small fast
/// sweeps `SyncProbeCorrelatorTests` uses to exercise the filter itself. That
/// is the point of this suite: it tests the contract with the Mac, not the
/// mathematics.
@Suite struct ProbeAnalyzerTests {

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

    /// Phones hand us 48 kHz most of the time and 44.1 kHz sometimes; nothing
    /// in the analyzer may assume either. 8 kHz keeps most scenes cheap while
    /// still clearing the glide's 3.6 kHz top.
    private static let rate = 8_000.0
    private static let spacing = SyncProbe.Layout.laneSpacingSeconds

    /// A capture with the reference lane landing at `referenceDelay` samples
    /// and the target lane one staged spacing earlier, `skew` samples late on
    /// top of that, over optional noise and hum. `drone: false` drops the bed
    /// from both lanes; `parallelGlide` adds a second glide a fifth below the
    /// template (2/3 of its frequencies, same shape, equal RMS) to each lane.
    private func renderCapture(sampleRate: Double,
                               referenceDelay: Double,
                               skew: Double,
                               referenceGain: Double = 0.5,
                               targetGain: Double = 0.5,
                               seconds: Double = 10,
                               noiseRMS: Double = 0,
                               humHz: Double = 0,
                               humAmplitude: Double = 0,
                               drone: Bool = true,
                               parallelGlide: Bool = false,
                               seed: UInt64 = 11) -> [Float] {
        let glide = SyncProbe.GlideDesign.probe(sampleRate: sampleRate)
        var fifthBelow = glide
        fifthBelow.startHz = glide.startHz * 2 / 3
        fifthBelow.endHz = glide.endHz * 2 / 3
        func rms(_ x: [Float]) -> Double {
            (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)).squareRoot()
        }
        let fifthGain = parallelGlide
            ? rms(SyncProbe.samples(glide)) / rms(SyncProbe.samples(fifthBelow)) : 0
        let droneGain = drone ? SyncProbe.Drone.gain(sampleRate: sampleRate) : 0
        let lead = SyncProbe.Layout.bedLeadSeconds
        func lane(_ t: Double) -> Double {
            droneGain * SyncProbe.Drone.value(at: t)
                + SyncProbe.value(glide, at: t - lead)
                + fifthGain * SyncProbe.value(fifthBelow, at: t - lead)
        }
        let targetDelay = referenceDelay - Self.spacing * sampleRate + skew
        var rng = SeededRNG(seed: seed)
        let length = Int(seconds * sampleRate)
        var out = [Float](repeating: 0, count: length)
        for i in 0..<length {
            var sample = 0.0
            sample += referenceGain * lane((Double(i) - referenceDelay) / sampleRate)
            sample += targetGain * lane((Double(i) - targetDelay) / sampleRate)
            if noiseRMS > 0 {
                // Box–Muller: one Gaussian per sample.
                let u1 = Double.random(in: 1e-12..<1, using: &rng)
                let u2 = Double.random(in: 0..<1, using: &rng)
                sample += noiseRMS * sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
            }
            if humAmplitude > 0 {
                sample += humAmplitude * sin(2 * .pi * humHz * Double(i) / sampleRate)
            }
            out[i] = Float(sample)
        }
        return out
    }

    /// The reference lane's start in the usual scene: the target lane starts
    /// 1 s into the capture.
    private static let referenceDelay = rate * (1.0 + spacing)

    // MARK: the measurement

    @Test func aKnownOffsetIsRecoveredInMilliseconds() throws {
        // Target 20 ms later than its staged slot.
        let capture = renderCapture(sampleRate: Self.rate,
                                    referenceDelay: Self.referenceDelay,
                                    skew: Self.rate * 0.020)
        let analysis = try ProbeAnalyzer(sampleRate: Self.rate).analyze(recording: capture)
        #expect(abs(analysis.offsetMs - 20) < 0.5,
                "a 20 ms lag must read as 20 ms: got \(analysis.offsetMs)")
        #expect(analysis.confidence > 10,
                "a clean two-lane capture is confident: \(analysis.confidence)")
    }

    @Test func theSignSaysTheTargetSoundedLate() throws {
        let late = try ProbeAnalyzer(sampleRate: Self.rate)
            .analyze(recording: renderCapture(sampleRate: Self.rate,
                                              referenceDelay: Self.referenceDelay,
                                              skew: Self.rate * 0.015))
        let early = try ProbeAnalyzer(sampleRate: Self.rate)
            .analyze(recording: renderCapture(sampleRate: Self.rate,
                                              referenceDelay: Self.referenceDelay,
                                              skew: -Self.rate * 0.015))
        #expect(late.offsetMs > 0, "target after its slot is POSITIVE — the Mac's convention")
        #expect(early.offsetMs < 0, "target before its slot is negative")
        #expect(abs(late.offsetMs + early.offsetMs) < 0.5, "and the two are symmetric")
    }

    @Test func fortyFourPointOneKilohertzMeasuresTheSameOffset() throws {
        let rate = 44_100.0
        let analysis = try ProbeAnalyzer(sampleRate: rate)
            .analyze(recording: renderCapture(sampleRate: rate,
                                              referenceDelay: rate * (1.0 + Self.spacing),
                                              skew: rate * 0.020))
        #expect(abs(analysis.offsetMs - 20) < 0.5,
                "the rate is a parameter, not an assumption: got \(analysis.offsetMs)")
    }

    /// The phone sits somewhere, and "somewhere" is rarely equidistant.
    @Test func aQuietTargetIsFoundBesideALoudReference() throws {
        let capture = renderCapture(sampleRate: Self.rate,
                                    referenceDelay: Self.referenceDelay,
                                    skew: Self.rate * 0.030,
                                    referenceGain: 0.7,
                                    targetGain: 0.05,   // ~23 dB down
                                    noiseRMS: 0.002)
        let analysis = try ProbeAnalyzer(sampleRate: Self.rate).analyze(recording: capture)
        #expect(abs(analysis.offsetMs - 30) < 1.0,
                "the quiet lane is searched apart from the loud one: got \(analysis.offsetMs)")
    }

    @Test func aHumIsSurvivedWhenTheAmbientLeadInIsSupplied() throws {
        // The target lane starts at 1 s, so everything before that is
        // provably probe-free. The hum sits inside the glide's band.
        let capture = renderCapture(sampleRate: Self.rate,
                                    referenceDelay: Self.referenceDelay,
                                    skew: Self.rate * 0.012,
                                    referenceGain: 0.25,
                                    targetGain: 0.25,
                                    humHz: 400,
                                    humAmplitude: 0.5)
        let analysis = try ProbeAnalyzer(sampleRate: Self.rate)
            .analyze(recording: capture, ambientEndSample: Int(Self.rate * 0.9))
        #expect(abs(analysis.offsetMs - 12) < 1.0,
                "weighting discounts the hum's bins: got \(analysis.offsetMs)")
    }

    /// A lead-in too short to describe the room must not be handed to the
    /// weighting — it falls through to the plain matched filter instead.
    @Test func aUselessAmbientSliceStillMeasures() throws {
        let capture = renderCapture(sampleRate: Self.rate,
                                    referenceDelay: Self.referenceDelay,
                                    skew: Self.rate * 0.020)
        let analysis = try ProbeAnalyzer(sampleRate: Self.rate)
            .analyze(recording: capture, ambientEndSample: Int(Self.rate * 0.1))
        #expect(abs(analysis.offsetMs - 20) < 0.5,
                "below the ambient floor the unweighted pass decides: got \(analysis.offsetMs)")
    }

    /// Red if a change to `SyncProbe.Drone` puts a rival peak within 6 dB of
    /// either lane's arrival or moves the measured offset.
    @Test func theDroneCreatesNoRivalPeak() throws {
        func measure(drone: Bool) throws -> ProbeAnalysis {
            try ProbeAnalyzer(sampleRate: Self.rate)
                .analyze(recording: renderCapture(sampleRate: Self.rate,
                                                  referenceDelay: Self.referenceDelay,
                                                  skew: Self.rate * 0.0175,
                                                  noiseRMS: 0.01,
                                                  drone: drone))
        }
        let bare = try measure(drone: false)
        let bedded = try measure(drone: true)
        #expect(bedded.peakMargin >= 1.995,
                "a held chord matches no moment of a moving glide: margin \(bedded.peakMargin)")
        #expect(abs(bedded.offsetMs - bare.offsetMs) < 0.1,
                "and moves nothing: \(bedded.offsetMs) against \(bare.offsetMs)")
    }

    /// Red if the template goes back to a narrow low glide: there a glide a
    /// fifth below matched the template about a second early nearly as well
    /// as the real arrival. Across 3.6 kHz → 150 Hz the same decoration only
    /// overlaps part of the template, so the reading must not move.
    @Test func aParallelGlideAFifthBelowDoesNotMoveTheReading() throws {
        let analysis = try ProbeAnalyzer(sampleRate: Self.rate)
            .analyze(recording: renderCapture(sampleRate: Self.rate,
                                              referenceDelay: Self.referenceDelay,
                                              skew: Self.rate * 0.010,
                                              parallelGlide: true))
        #expect(abs(analysis.offsetMs - 10) < 0.1,
                "a glide a fifth below leaves the 10 ms skew alone: got \(analysis.offsetMs) ms")
        #expect(analysis.peakMargin >= 1.995,
                "and clears the apps' 6 dB rival guard: margin \(analysis.peakMargin)")
    }

    /// Red if the lane the Mac stages (`SyncProbe.lane`: drone gain, glide
    /// tail, peak normalisation) stops matching the template the analyzer
    /// correlates against, or the analyzer stops removing the staged spacing.
    @Test func theStagedLaneItselfReadsBackItsSkew() throws {
        let rate = Self.rate
        let lane = SyncProbe.lane(sampleRate: rate)
        let target = Int(rate * 1.010)   // 10 ms late
        let reference = Int(rate * (1.0 + Self.spacing))
        var capture = [Float](repeating: 0, count: Int(rate * 10))
        for (i, s) in lane.enumerated() {
            capture[target + i] += 0.5 * s
            capture[reference + i] += 0.5 * s
        }
        let analysis = try ProbeAnalyzer(sampleRate: rate).analyze(recording: capture)
        #expect(abs(analysis.offsetMs - 10) < 0.1,
                "the staged lane reads back its 10 ms skew: got \(analysis.offsetMs) ms")
    }

    /// Red if `searchFromSample` stops keeping the search off the capture
    /// before it: a louder lane there would win the first search and pair
    /// with the real target as if it were a lane of this run.
    @Test func aLouderLaneBeforeTheSearchStartIsIgnored() throws {
        let rate = Self.rate
        var capture = renderCapture(sampleRate: rate,
                                    referenceDelay: rate * (5.0 + Self.spacing),
                                    skew: rate * 0.020,
                                    seconds: 14)
        let decoyStart = Int(rate * 0.2)
        for (i, s) in SyncProbe.lane(sampleRate: rate).enumerated() {
            capture[decoyStart + i] += 1.5 * s
        }
        let analysis = try ProbeAnalyzer(sampleRate: rate)
            .analyze(recording: capture, searchFromSample: Int(rate * 4.5))
        #expect(abs(analysis.offsetMs - 20) < 0.5,
                "only the pair after the search start is read: got \(analysis.offsetMs) ms")
    }

    // MARK: refusal

    @Test func pureNoiseIsRefused() {
        var rng = SeededRNG(seed: 99)
        let noise = (0..<Int(Self.rate * 10)).map { _ -> Float in
            let u1 = Double.random(in: 1e-12..<1, using: &rng)
            let u2 = Double.random(in: 0..<1, using: &rng)
            return Float(0.1 * sqrt(-2 * log(u1)) * cos(2 * .pi * u2))
        }
        #expect(throws: ProbeAnalysisError.probeNotFound) {
            _ = try ProbeAnalyzer(sampleRate: Self.rate).analyze(recording: noise)
        }
    }

    /// Only ONE lane present is still a refusal: a measurement needs both
    /// arrivals, and half of one is not "best effort".
    @Test func aCaptureMissingTheTargetLaneIsRefused() {
        let capture = renderCapture(sampleRate: Self.rate,
                                    referenceDelay: Self.referenceDelay,
                                    skew: 0,
                                    targetGain: 0)
        #expect(throws: ProbeAnalysisError.probeNotFound) {
            _ = try ProbeAnalyzer(sampleRate: Self.rate).analyze(recording: capture)
        }
    }

    /// Red if the length check goes back to one sweep's length instead of
    /// `Layout.totalSeconds`: a capture that cannot hold both lanes would be
    /// searched instead of refused as a setup fault.
    @Test func aCaptureShorterThanTheWholeProbeIsRefused() {
        let short = [Float](repeating: 0,
                            count: Int(Self.rate * SyncProbe.Layout.totalSeconds) - 1)
        #expect(throws: ProbeAnalysisError.recordingTooShort) {
            _ = try ProbeAnalyzer(sampleRate: Self.rate).analyze(recording: short)
        }
    }

    // MARK: the contract with the Mac

    /// The Mac stages the lanes at these times and this analyzer removes the
    /// spacing itself, so a change here moves both apps at once. Red if a
    /// layout number moves without the Mac and the phone moving with it.
    @Test func theLaneLayoutIsPinned() {
        #expect(SyncProbe.Layout.laneSpacingSeconds == 4.5)
        #expect(SyncProbe.Layout.glideSeconds == 3.5)
        #expect(SyncProbe.Layout.totalSeconds == 8.5)
        #expect(SyncProbe.Layout.bedLeadSeconds == 0.5)
    }

    /// Red if the template's band, tilt or partials change: the Mac stages this
    /// glide and both apps correlate against it.
    @Test func theTemplateBandIsPinned() {
        let glide = SyncProbe.GlideDesign.probe(sampleRate: Self.rate)
        #expect(glide.startHz == 3_600 && glide.endHz == 150, "the glide falls 3.6 kHz → 150 Hz")
        #expect(glide.tiltDBPerOctave == -4, "the top sits about 18 dB under the bottom")
        #expect(glide.partialLevels == [1], "one glide, no harmonics")
    }
}
