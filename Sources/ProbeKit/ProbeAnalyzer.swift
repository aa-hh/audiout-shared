// Copyright (C) 2026 ahh and contributors.
// SPDX-License-Identifier: MIT
//
// LICENSE-CLEAN by design, like `SyncProbeCorrelator` beside it: MIT, not GPL,
// and nothing GPL-derived may move in. See that file's note before editing
// either.

import Foundation

/// What one probe recording measured. RAW measurement only — the Mac owns what
/// a given offset means for a device's trim.
public struct ProbeAnalysis: Sendable, Equatable {
    /// Target arrival minus reference arrival, ms, with the lanes' staged
    /// spacing already removed. Positive = the target sounded LATE, i.e. its
    /// applied latency is this much too small.
    public let offsetMs: Double
    /// The weaker of the two arrivals' peak-to-sidelobe ratios — the
    /// measurement's own confidence statement. Pure noise scores ~1; a real
    /// arrival at sane SNR runs to the hundreds.
    public let confidence: Double
    /// The smaller of the two lanes' ``SyncProbeCorrelator/Arrival/peakMargin``:
    /// each arrival's height over the strongest rival lag in its own search.
    /// 1 means a rival matched the winner; callers refuse below 1.995 (6 dB);
    /// both apps do.
    public let peakMargin: Double
}

public enum ProbeAnalysisError: Error, Sendable {
    /// The capture is shorter than the whole probe, so it cannot hold both
    /// lanes. A setup fault, not an acoustic one.
    case recordingTooShort
    /// One or both lanes were not found convincingly. The honest outcome of a
    /// room too loud, a speaker too quiet, or a run that was torn down early.
    case probeNotFound
}

/// Recovers a target speaker's alignment error from a recording of the probe
/// the Mac stages: the same glide on both speakers in turn, the target
/// (Bluetooth) lane first and the reference lane
/// ``SyncProbe/Layout/laneSpacingSeconds`` later.
///
/// One technique serves both microphones: the Mac's built-in one
/// (`MicProbeSession`) and the phone's. One microphone hears both speakers,
/// and both lanes ride one scheduled start, so the capture latency cancels in
/// the DIFFERENCE of the two arrivals; this analyzer subtracts the staged
/// spacing from it. What survives is the per-speaker output latency difference
/// plus the speakers' distance asymmetry to the mic.
///
/// **What the phone changes is that the microphone moves.** The Mac's mic sits
/// where the Mac sits; a phone is carried, and distance asymmetry costs about
/// 2.9 ms per metre. Held at the listening position that is the measurement you
/// actually want — sync at the ears, not sync at the laptop. Held beside one
/// speaker it is a confident wrong answer, and nothing in the signal can tell
/// the two apart. Placement is the caller's problem to state plainly to the
/// user; this package cannot detect it.
///
/// The template is recreated locally at the capture's own sample rate, so the
/// phone needs nothing from the Mac but the knowledge that a run is under
/// way — no reference audio crosses the network.
public struct ProbeAnalyzer: Sendable {

    /// Ambient weighting needs at least this much probe-free lead-in to
    /// describe anything; below it the slice is noise about noise.
    static let minimumAmbientSeconds = 0.3

    private let sampleRate: Double

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    /// Measure one capture.
    ///
    /// `ambientEndSample` marks where the probe-free lead-in ends — the
    /// capture up to just before the probe entered the Mac's feed. Air can
    /// only lag the feed, so that slice is provably probe-free. Pass 0 when
    /// the boundary is unknown; the measurement then runs unweighted, which is
    /// the same path a useless ambient slice falls back to anyway.
    /// `searchFromSample` keeps the search off anything earlier; the search
    /// never starts before `ambientEndSample` either.
    ///
    /// The SNR weighting gets first go, but its failure is never the run's:
    /// during a wizard entry that lead-in slice legitimately carries the tail
    /// of the user's music still draining through the sinks' ~2 s delay (live
    /// finding, 2026-08-28: every probe measured fine acoustically and was then
    /// refused, because weighting by the music's spectrum crushed exactly the
    /// probe band — for noise that was gone by probe time). Weighting is an
    /// optimization for noise that is genuinely stationary; when it finds
    /// nothing, the plain matched filter decides.
    public func analyze(recording: [Float], ambientEndSample: Int = 0,
                        searchFromSample: Int = 0) throws -> ProbeAnalysis {
        guard sampleRate > 0 else { throw ProbeAnalysisError.recordingTooShort }
        let layout = SyncProbe.Layout.self
        let probeFrames = Int((layout.totalSeconds * sampleRate).rounded())
        guard recording.count >= probeFrames else { throw ProbeAnalysisError.recordingTooShort }

        let template = SyncProbe.samples(.probe(sampleRate: sampleRate))
        let correlator = SyncProbeCorrelator(sampleRate: sampleRate)

        let ambientFloor = Int(Self.minimumAmbientSeconds * sampleRate)
        let ambient: [Float]? = ambientEndSample > ambientFloor
            ? Array(recording[0..<min(ambientEndSample, recording.count)])
            : nil
        let searchFrom = max(searchFromSample, ambientEndSample)

        func lanes(_ ambientNoise: [Float]?) -> (earlier: SyncProbeCorrelator.Arrival,
                                                 later: SyncProbeCorrelator.Arrival)? {
            correlator.laneArrivals(of: template, in: recording, ambientNoise: ambientNoise,
                                    searchFrom: searchFrom,
                                    laneSpacingSeconds: layout.laneSpacingSeconds,
                                    maxSkewSeconds: layout.maxSkewSeconds)
        }

        // The earlier arrival is the target (Bluetooth) lane and the later the
        // reference, because that is the order the Mac stages them in.
        guard let (target, reference) = ambient.flatMap(lanes) ?? lanes(nil)
        else { throw ProbeAnalysisError.probeNotFound }
        let skewSeconds = (target.sampleOffset - reference.sampleOffset) / sampleRate
            + layout.laneSpacingSeconds
        return ProbeAnalysis(
            offsetMs: skewSeconds * 1000,
            confidence: min(target.peakToSidelobe, reference.peakToSidelobe),
            peakMargin: min(target.peakMargin, reference.peakMargin))
    }
}
