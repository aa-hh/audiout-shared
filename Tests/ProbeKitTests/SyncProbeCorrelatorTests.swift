// Copyright (C) 2026 ahh and contributors.
// SPDX-License-Identifier: MIT
//
// LICENSE-CLEAN by design, like the file under test: MIT, not GPL.

import Foundation
import Testing
@testable import ProbeKit

/// The matched filter behind mic-probe calibration: does it find a probe's
/// arrival to a fraction of a sample, tell two simultaneous probes apart,
/// survive noise and echoes, and refuse to answer when no probe is there.
/// Every acoustic scene here is synthetic — arrivals are rendered
/// analytically at fractional delays, so the expected answer is exact by
/// construction.
@Suite struct SyncProbeCorrelatorTests {

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

    // MARK: scene construction

    /// A probe landing in the recording at a (possibly fractional) sample
    /// delay, scaled by `gain`.
    private struct PlacedProbe {
        var design: SyncProbe.GlideDesign
        var delaySamples: Double
        var gain: Double
    }

    /// Renders a mic "recording": each placed probe evaluated analytically at
    /// its fractional delay, plus optional white noise and a hum tone.
    private func renderScene(length: Int, sampleRate: Double,
                             probes: [PlacedProbe],
                             noiseRMS: Double = 0, humHz: Double = 0,
                             humAmplitude: Double = 0,
                             seed: UInt64 = 7) -> [Float] {
        var rng = SeededRNG(seed: seed)
        var out = [Float](repeating: 0, count: length)
        for i in 0..<length {
            var sample = 0.0
            for probe in probes {
                let t = (Double(i) - probe.delaySamples) / sampleRate
                sample += probe.gain * SyncProbe.value(probe.design, at: t)
            }
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

    /// Small, fast scene: 8 kHz clock, 200–3000 Hz single-partial sweeps.
    private static let fastRate = 8_000.0
    private static func fastUp(duration: Double = 0.5) -> SyncProbe.GlideDesign {
        SyncProbe.GlideDesign(sampleRate: fastRate, startHz: 200, endHz: 3_000,
                              duration: duration, partialLevels: [1],
                              fadeInSeconds: 0.01, fadeOutSeconds: 0.01)
    }
    private static func fastDown(duration: Double = 0.5) -> SyncProbe.GlideDesign {
        SyncProbe.GlideDesign(sampleRate: fastRate, startHz: 3_000, endHz: 200,
                              duration: duration, partialLevels: [1],
                              fadeInSeconds: 0.01, fadeOutSeconds: 0.01)
    }

    /// One probe lane placed in a recording: where it starts, in samples,
    /// and how loud it arrives.
    private struct PlacedLane {
        var delaySamples: Double
        var gain: Double
    }

    /// A mic recording of shipping probe lanes, each rendered analytically at
    /// its fractional delay as `SyncProbe.lane` builds it (drone from the
    /// lane's start, glide from `bedLeadSeconds`), plus optional white noise.
    private func renderLanes(length: Int, sampleRate: Double, lanes: [PlacedLane],
                             noiseRMS: Double = 0, seed: UInt64 = 7) -> [Float] {
        let glide = SyncProbe.GlideDesign.probe(sampleRate: sampleRate)
        let droneGain = SyncProbe.Drone.gain(sampleRate: sampleRate)
        let lead = SyncProbe.Layout.bedLeadSeconds
        var rng = SeededRNG(seed: seed)
        var out = [Float](repeating: 0, count: length)
        for i in 0..<length {
            var sample = 0.0
            for lane in lanes {
                let t = (Double(i) - lane.delaySamples) / sampleRate
                sample += lane.gain * (droneGain * SyncProbe.Drone.value(at: t)
                                       + SyncProbe.value(glide, at: t - lead))
            }
            if noiseRMS > 0 {
                let u1 = Double.random(in: 1e-12..<1, using: &rng)
                let u2 = Double.random(in: 0..<1, using: &rng)
                sample += noiseRMS * sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
            }
            out[i] = Float(sample)
        }
        return out
    }

    /// The two lanes' measured skew, ms: later minus earlier, less the
    /// staged spacing.
    private static func skewMs(_ lanes: (earlier: SyncProbeCorrelator.Arrival,
                                         later: SyncProbeCorrelator.Arrival),
                               rate: Double) -> Double {
        ((lanes.later.sampleOffset - lanes.earlier.sampleOffset) / rate
            - SyncProbe.Layout.laneSpacingSeconds) * 1000
    }

    // MARK: synthesis

    @Test func sweepSamplesMatchTheAnalyticFormAndStayBounded() {
        let design = Self.fastUp()
        let samples = SyncProbe.samples(design)
        #expect(samples.count == 4_000, "0.5 s at 8 kHz is 4000 samples")
        for (i, s) in samples.enumerated() {
            #expect(abs(s) <= 1.0001, "a constant-amplitude sweep never clips")
            let analytic = Float(SyncProbe.value(design, at: Double(i) / design.sampleRate))
            #expect(s == analytic, "samples(_:) is value(_:at:) on the sample grid")
        }
        #expect(abs(samples[0]) < 1e-6 && abs(samples[samples.count - 1]) < 0.05,
                "the fades take the ends to (near) zero — no click on air")
    }

    // MARK: single-probe arrival

    @Test func integerDelayIsRecoveredToWellUnderASample() throws {
        let up = SyncProbe.samples(Self.fastUp())
        let rec = renderScene(length: 8_000, sampleRate: Self.fastRate,
                              probes: [PlacedProbe(design: Self.fastUp(),
                                                   delaySamples: 400, gain: 0.8)])
        let correlator = SyncProbeCorrelator(sampleRate: Self.fastRate)
        let arrival = try #require(correlator.arrival(of: up, in: rec),
                                   "a clean, loud probe must be found")
        #expect(abs(arrival.sampleOffset - 400) < 0.1,
                "clean integer-sample arrival lands on the sample: got \(arrival.sampleOffset)")
        #expect(arrival.peakToSidelobe > 10,
                "a clean arrival is confident, not borderline: PSR \(arrival.peakToSidelobe)")
    }

    @Test func fractionalDelayIsResolvedSubSample() throws {
        let up = SyncProbe.samples(Self.fastUp())
        let rec = renderScene(length: 8_000, sampleRate: Self.fastRate,
                              probes: [PlacedProbe(design: Self.fastUp(),
                                                   delaySamples: 400.37, gain: 0.8)])
        let correlator = SyncProbeCorrelator(sampleRate: Self.fastRate)
        let arrival = try #require(correlator.arrival(of: up, in: rec))
        #expect(abs(arrival.sampleOffset - 400.37) < 0.35,
                "parabolic interpolation resolves a fractional arrival: got \(arrival.sampleOffset)")
    }

    @Test func aWeakEchoDoesNotStealTheArrivalFromTheDirectPath() throws {
        // Direct path plus a −6 dB reflection 15 ms later — the everyday room.
        let up = SyncProbe.samples(Self.fastUp())
        let echoDelay = 400.0 + 0.015 * Self.fastRate
        let rec = renderScene(length: 8_000, sampleRate: Self.fastRate,
                              probes: [
                                PlacedProbe(design: Self.fastUp(), delaySamples: 400, gain: 0.8),
                                PlacedProbe(design: Self.fastUp(), delaySamples: echoDelay, gain: 0.4),
                              ])
        let correlator = SyncProbeCorrelator(sampleRate: Self.fastRate)
        let arrival = try #require(correlator.arrival(of: up, in: rec))
        #expect(abs(arrival.sampleOffset - 400) < 0.5,
                "the stronger direct path wins over its echo: got \(arrival.sampleOffset)")
    }

    // MARK: refusal

    @Test func pureNoiseYieldsNoArrival() {
        let up = SyncProbe.samples(Self.fastUp())
        let rec = renderScene(length: 8_000, sampleRate: Self.fastRate,
                              probes: [], noiseRMS: 0.3)
        let correlator = SyncProbeCorrelator(sampleRate: Self.fastRate)
        #expect(correlator.arrival(of: up, in: rec) == nil,
                "no probe in the room means no answer — never a confident hallucination")
    }

    @Test func theWrongProbeIsNotMistakenForTheRightOne() {
        // Only the DOWN sweep is in the air; asking for the UP sweep must fail.
        // The matched filter rejects a different glide, whatever the probe is.
        let up = SyncProbe.samples(Self.fastUp())
        let rec = renderScene(length: 8_000, sampleRate: Self.fastRate,
                              probes: [PlacedProbe(design: Self.fastDown(),
                                                   delaySamples: 400, gain: 0.8)])
        let correlator = SyncProbeCorrelator(sampleRate: Self.fastRate)
        #expect(correlator.arrival(of: up, in: rec) == nil,
                "an up-sweep matched filter must not fire on a down sweep")
    }

    @Test func degenerateInputsReturnNilNotNonsense() {
        let correlator = SyncProbeCorrelator(sampleRate: Self.fastRate)
        let up = SyncProbe.samples(Self.fastUp())
        #expect(correlator.arrival(of: up, in: []) == nil)
        #expect(correlator.arrival(of: up, in: [0.1, 0.2]) == nil,
                "a recording shorter than the probe cannot contain it")
        #expect(correlator.arrival(of: [], in: up) == nil)
    }

    /// Red if the ambient smoothing width in hertz is divided by a zero
    /// sample rate again: `Int(.infinity)` traps the process instead of the
    /// correlator answering.
    @Test func aZeroRateWithAnAmbientSliceDoesNotTrap() {
        let up = SyncProbe.samples(Self.fastUp())
        let rec = renderScene(length: 8_000, sampleRate: Self.fastRate,
                              probes: [PlacedProbe(design: Self.fastUp(),
                                                   delaySamples: 400, gain: 0.8)],
                              noiseRMS: 0.01)
        _ = SyncProbeCorrelator(sampleRate: 0)
            .arrival(of: up, in: rec, ambientNoise: Array(rec[0..<300]))
    }

    // MARK: two probes, one recording

    @Test func simultaneousUpAndDownProbesSeparateAndTheOffsetIsExact() throws {
        // Both speakers play at once, arrivals 333.5 samples apart, unequal
        // loudness — the shape of the real calibration moment.
        let up = SyncProbe.samples(Self.fastUp())
        let down = SyncProbe.samples(Self.fastDown())
        let rec = renderScene(length: 12_000, sampleRate: Self.fastRate,
                              probes: [
                                PlacedProbe(design: Self.fastUp(), delaySamples: 400.4, gain: 0.8),
                                PlacedProbe(design: Self.fastDown(), delaySamples: 733.9, gain: 0.4),
                              ],
                              noiseRMS: 0.02)
        let correlator = SyncProbeCorrelator(sampleRate: Self.fastRate)
        let a = try #require(correlator.arrival(of: up, in: rec))
        let b = try #require(correlator.arrival(of: down, in: rec))
        let offsetSeconds = (b.sampleOffset - a.sampleOffset) / Self.fastRate
        let expected = (733.9 - 400.4) / Self.fastRate
        #expect(abs(offsetSeconds - expected) < 0.5 / Self.fastRate,
                "the arrival difference is the measurement: got \(offsetSeconds * 1000) ms, wanted \(expected * 1000) ms")
        #expect(offsetSeconds > 0, "B arriving later reads positive")
    }

    /// Red if `laneArrivals` stops searching the second lane at the staged
    /// spacing, or loses the sub-sample peak on either lane.
    @Test func twoLanesInTurnDeliverTheSkewUnderNoiseAndEchoes() throws {
        // The Mac-side geometry: its own speaker 11 dB louder at the mic than
        // the Bluetooth one across the room, each with a room echo, under
        // white noise above the quiet lane per sample (white is harsher on
        // the glide's darkened top than a real room's falling floor). Target first, the
        // reference 4.5 s later and 7.5 ms late on top of that.
        let rate = Self.fastRate
        let target = 1_440.25
        let reference = target + SyncProbe.Layout.laneSpacingSeconds * rate + 60   // +7.5 ms
        let quiet = 0.02
        let loud = quiet * pow(10, 11.0 / 20)
        let rec = renderLanes(length: 72_000, sampleRate: rate,
                              lanes: [PlacedLane(delaySamples: target, gain: quiet),
                                      PlacedLane(delaySamples: target + 112, gain: quiet * 0.4),
                                      PlacedLane(delaySamples: reference, gain: loud),
                                      PlacedLane(delaySamples: reference + 72, gain: loud * 0.4)],
                              noiseRMS: 0.03)
        let correlator = SyncProbeCorrelator(sampleRate: rate)
        let lanes = try #require(
            correlator.laneArrivals(of: SyncProbe.samples(.probe(sampleRate: rate)), in: rec,
                                    laneSpacingSeconds: SyncProbe.Layout.laneSpacingSeconds,
                                    maxSkewSeconds: SyncProbe.Layout.maxSkewSeconds),
            "both lanes under loud noise are the design point")
        #expect(abs(Self.skewMs(lanes, rate: rate) - 7.5) < 0.1,
                "got \(Self.skewMs(lanes, rate: rate)) ms, wanted 7.5 ms")
        #expect(lanes.earlier.peakToSidelobe >= correlator.minPeakToSidelobe,
                "the quiet target lane clears the gate: PSR \(lanes.earlier.peakToSidelobe)")
    }

    /// Red if the probe's rival check counts the room's echo of an arrival
    /// (or the arrival's own smear) as a rival: a Sonos Move measured live
    /// with a reflection 22 ms after its arrival only 5 dB down and peaks
    /// 6-9 ms apart within 3 dB, and every reading was refused.
    @Test func anEchoJustAfterAnArrivalIsNotARival() throws {
        let rate = Self.fastRate
        let target = 1_440.25
        let reference = target + SyncProbe.Layout.laneSpacingSeconds * rate + 60   // +7.5 ms
        let rec = renderLanes(length: 72_000, sampleRate: rate,
                              lanes: [PlacedLane(delaySamples: target, gain: 0.1),
                                      PlacedLane(delaySamples: target + 0.008 * rate, gain: 0.07),
                                      PlacedLane(delaySamples: target + 0.022 * rate, gain: 0.056),
                                      PlacedLane(delaySamples: reference, gain: 0.1)],
                              noiseRMS: 0.005)
        let correlator = SyncProbeCorrelator(sampleRate: rate)
        let lanes = try #require(
            correlator.laneArrivals(of: SyncProbe.samples(.probe(sampleRate: rate)), in: rec,
                                    laneSpacingSeconds: SyncProbe.Layout.laneSpacingSeconds,
                                    maxSkewSeconds: SyncProbe.Layout.maxSkewSeconds))
        #expect(abs(Self.skewMs(lanes, rate: rate) - 7.5) < 0.1,
                "the direct arrival wins: got \(Self.skewMs(lanes, rate: rate)) ms")
        #expect(lanes.earlier.peakMargin >= 1.995,
                "an echo 22 ms on and a peak 8 ms on are the arrival's, not rivals: \(lanes.earlier.peakMargin)")
    }

    /// Red if the second lane is searched over the whole correlation again,
    /// or only on the side after the first arrival: here the louder lane is
    /// the EARLIER one, so the quiet reference sits after it.
    @Test func theQuietLaneIsFoundBesideALaneTenDecibelsLouder() throws {
        // Target 10 dB louder than the reference this time, arriving 22.79 ms
        // early on top of the staged spacing, each with an echo 100 ms on.
        let rate = Self.fastRate
        let target = 1_600.0
        let reference = target + SyncProbe.Layout.laneSpacingSeconds * rate - 182.32   // −22.79 ms
        let loud = 0.0395
        let quiet = loud * pow(10, -10.0 / 20)
        let rec = renderLanes(length: 72_000, sampleRate: rate,
                              lanes: [PlacedLane(delaySamples: target, gain: loud),
                                      PlacedLane(delaySamples: target + 800, gain: loud * 0.34),
                                      PlacedLane(delaySamples: reference, gain: quiet),
                                      PlacedLane(delaySamples: reference + 800, gain: quiet * 0.34)],
                              noiseRMS: 0.000_5)
        let correlator = SyncProbeCorrelator(sampleRate: rate)
        let lanes = try #require(
            correlator.laneArrivals(of: SyncProbe.samples(.probe(sampleRate: rate)), in: rec,
                                    laneSpacingSeconds: SyncProbe.Layout.laneSpacingSeconds,
                                    maxSkewSeconds: SyncProbe.Layout.maxSkewSeconds),
            "a 10 dB quieter speaker is the ordinary geometry, not a bad capture")
        #expect(abs(Self.skewMs(lanes, rate: rate) + 22.79) < 0.1,
                "got \(Self.skewMs(lanes, rate: rate)) ms, wanted −22.79 ms")
        #expect(lanes.later.peakToSidelobe >= correlator.minPeakToSidelobe,
                "the quiet reference lane clears the gate: PSR \(lanes.later.peakToSidelobe)")
    }

    @Test func aLateReflectionIsNotEvidenceAgainstTheArrivalItEchoes() throws {
        // A live room, and the shape of the 2026-08-28 refusals: one clean
        // arrival plus its own reflection at −10 dB, arriving 350 ms later —
        // past the reverb shadow, so the old max-of-background estimator
        // handed the gate the echo and scored the measurement at ~3, refusing
        // a peak sitting 60 dB above the room's actual noise. Reverb is
        // structure, not background; a robust estimate has to ignore it.
        let up = SyncProbe.samples(Self.fastUp())
        let reflection = 400.0 + 0.35 * Self.fastRate
        let rec = renderScene(length: 24_000, sampleRate: Self.fastRate,
                              probes: [
                                PlacedProbe(design: Self.fastUp(), delaySamples: 400, gain: 0.8),
                                PlacedProbe(design: Self.fastUp(), delaySamples: reflection,
                                            gain: 0.25),
                              ],
                              noiseRMS: 0.001)
        let correlator = SyncProbeCorrelator(sampleRate: Self.fastRate)
        let arrival = try #require(correlator.arrival(of: up, in: rec),
                                   "a reverberant room must not veto its own direct path")
        #expect(abs(arrival.sampleOffset - 400) < 0.5,
                "the direct path still wins: got \(arrival.sampleOffset)")
        #expect(arrival.peakToSidelobe > 50,
                "confidence reflects the noise floor, not the echo: got \(arrival.peakToSidelobe)")
    }

    // MARK: noise weighting

    @Test func aLoudHumIsSurvivedWhenAmbientNoiseIsSupplied() throws {
        // A tonal interferer well above the probe's level, sitting inside the
        // probe band. The ambient lead-in lets the correlator discount that
        // bin instead of letting it vote at full weight.
        let up = SyncProbe.samples(Self.fastUp())
        let rec = renderScene(length: 12_000, sampleRate: Self.fastRate,
                              probes: [PlacedProbe(design: Self.fastUp(),
                                                   delaySamples: 2_400, gain: 0.1)],
                              noiseRMS: 0.02, humHz: 997, humAmplitude: 0.7)
        // The probe-free lead-in of the same scene is the ambient sample.
        let ambient = Array(rec[0..<2_000])
        let correlator = SyncProbeCorrelator(sampleRate: Self.fastRate)
        let weighted = try #require(correlator.arrival(of: up, in: rec,
                                                       ambientNoise: ambient),
                                    "with the noise spectrum known, the hum must not drown the probe")
        #expect(abs(weighted.sampleOffset - 2_400) < 0.5,
                "the arrival stays accurate under the hum: got \(weighted.sampleOffset)")

        if let unweighted = correlator.arrival(of: up, in: rec) {
            #expect(weighted.peakToSidelobe >= unweighted.peakToSidelobe,
                    "noise weighting never costs confidence on the scene it models")
        }
    }

    /// The wizard's chirp path must be exactly what it was before the passive
    /// drift path needed whitening. This scene's answer and score are the
    /// numbers the unmodified correlator produced (2026-09-14, run against
    /// both versions of the file); the correlation arrays at exponent 0 and
    /// with no exponent at all are compared sample for sample as well, so a
    /// future weighting cannot quietly apply itself to a caller that asked
    /// for none. Red if whitening reaches the chirp path by default.
    @Test func whiteningLeavesTheChirpPathAlone() {
        let up = Self.fastUp()
        let probe = SyncProbe.samples(up)
        let recording = renderScene(length: 16_000, sampleRate: Self.fastRate,
                                    probes: [PlacedProbe(design: up, delaySamples: 3210.4, gain: 0.8),
                                             PlacedProbe(design: Self.fastDown(),
                                                         delaySamples: 5120.7, gain: 0.5)],
                                    noiseRMS: 0.02)

        let arrival = SyncProbeCorrelator(sampleRate: Self.fastRate).arrival(of: probe, in: recording)
        #expect(arrival != nil)
        if let arrival {
            #expect(abs(arrival.sampleOffset - 3210.375_638_319_296_7) < 1e-6)
            #expect(abs(arrival.peakToSidelobe - 54.723_266_826_380_05) < 1e-6)
        }

        let unweighted = SyncProbeCorrelator.correlate(recording: recording, probe: probe,
                                                       ambientNoise: nil, sampleRate: Self.fastRate)
        let atZero = SyncProbeCorrelator.correlate(recording: recording, probe: probe,
                                                   ambientNoise: nil, whiteningExponent: 0,
                                                   sampleRate: Self.fastRate)
        #expect(unweighted != nil)
        #expect(unweighted == atZero)
    }

}
