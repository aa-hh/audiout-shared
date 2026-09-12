// Copyright (C) 2026 ahh and contributors.
// SPDX-License-Identifier: MIT
//
// LICENSE-CLEAN by design, like `SyncProbeCorrelator` beside it: MIT, not GPL,
// and nothing GPL-derived may move in. See that file's note before editing
// either.

import Accelerate
import Foundation

/// One arrival candidate: a delay the capture supports, and how strongly.
///
/// Which speaker a candidate belongs to is NOT decided here — several speakers
/// play the same program, so the signal cannot tell them apart. The caller
/// matches candidates to speakers from the baseline delays it passed in.
public struct DriftPeak: Equatable, Sendable {
    /// Delay from the reference slice's start to this arrival, ms.
    public var delayMs: Double
    /// Peak height over what the correlation background is EXPECTED to reach —
    /// the same statement as ``SyncProbeCorrelator/Arrival/peakToSidelobe``.
    /// Pure noise scores ~1.
    public var confidence: Double

    public init(delayMs: Double, confidence: Double) {
        self.delayMs = delayMs
        self.confidence = confidence
    }
}

/// Why a reference slice cannot localize an arrival. Each case is a distinct
/// acoustic reason, kept separate so a caller can log which one keeps firing
/// rather than "measurement skipped".
public enum DriftRejection: String, Equatable, Sendable {
    /// The program was near-silent through this window — a passage between
    /// tracks, or the user turned it down. Nothing to correlate.
    case referenceTooQuiet
    /// The program occupied too little bandwidth (a held tone, a bass-only
    /// passage). A matched filter's timing resolution is ~1/bandwidth, so a
    /// narrowband slice has no sharp peak to find at any SNR.
    case referenceTooNarrowband
    /// The program repeats itself strongly inside the search window (a bare
    /// loop, a metronomic beat). Every repeat is an equally good match, so the
    /// best lag is a coin toss between them — the failure mode this whole
    /// windowed search exists to contain, and a window is not enough when the
    /// period is shorter than the window.
    case referenceTooPeriodic
    /// Reference or capture too short to correlate at all — a setup fault.
    case slicesTooShort
    /// The slice passed every suitability check and still produced no
    /// convincing peak in any search window: room too loud, speaker muted, or
    /// the real delay outside the window the caller expected.
    case noConvincingPeak
}

/// What one analysis window measured.
public enum DriftOutcome: Equatable, Sendable {
    /// At least one convincing arrival, highest confidence first.
    case usable([DriftPeak])
    case unusable(DriftRejection)
}

/// Passive drift tracking: correlate a microphone capture against the program
/// audio the Mac actually sent, instead of a probe the Mac had to inject.
///
/// Chirp calibration (``ProbeAnalyzer``) measures once, loudly, with the user's
/// consent. Bluetooth delay then drifts over a session, and a sweep cannot be
/// injected every minute. So the Mac retains the outgoing program and the same
/// matched filter runs with that retained slice as its reference — the music is
/// the probe. Everything else is unchanged: the FFT matched filter, SNR-aware
/// noise weighting with a plain-filter fallback, parabolic sub-sample peak
/// interpolation, and the median-floor peak-to-sidelobe score all come from
/// ``SyncProbeCorrelator``. PHAT whitening stays rejected for the reason stated
/// there.
///
/// **Two things make program audio harder than a sweep, and both are handled
/// by refusing rather than guessing.** Music is not broadband white — quiet,
/// narrowband or looping passages carry no timing information — so a slice is
/// scored for suitability first and rejected with a reason. And music repeats:
/// a beat every 500 ms makes a false peak every 500 ms, indistinguishable from
/// the true one over a whole tape. So the lag search is confined to a window
/// around each delay the caller already expects from chirp calibration, plus
/// the largest jump worth tracking.
///
/// ### Alignment contract
///
/// `reference[0]` must be the program sample that left the Mac at the same
/// monotonic instant `capture[0]` was recorded. The caller owns that
/// arithmetic — it holds the retained program's start pts and the capture's —
/// and the delays returned here are measured from that shared zero. No pts
/// handling lives in this package.
///
/// ### Sample rates
///
/// The reference and the capture may run at different rates (the Mac retains
/// at 44.1 kHz; a microphone commonly captures at 48 kHz). The reference is
/// resampled to the CAPTURE's rate by linear interpolation and everything is
/// correlated there, so returned delays are quantised to the capture's own
/// resolution before parabolic interpolation refines them. The chirp path
/// instead re-renders its sweep at the capture rate; a retained program cannot
/// be re-rendered, so it is resampled.
///
/// Pure DSP, hardware-free, like everything else in ProbeKit.
public struct PassiveDriftCorrelator: Sendable {

    /// Peaks below this peak-to-sidelobe ratio are not reported.
    ///
    /// LOWER than the chirp path's 5, and that is not a relaxation of
    /// standards — the score means something different here. A sweep's
    /// autocorrelation is an impulse, so its background really is noise and a
    /// true arrival scores in the hundreds. Music correlates with itself at
    /// every lag, so the background this peak is measured against is mostly
    /// the reference's own structure. On the synthetic broadband scenes in
    /// `PassiveDriftCorrelatorTests` a true arrival scores 3–6 and a window
    /// containing no arrival at all scores ~0.9; 3 sits in that gap. The gap
    /// is narrow, which is why the search window and the suitability checks do
    /// most of the work and this threshold only catches what they let through.
    public var minPeakToSidelobe: Double = 3

    /// A reference slice quieter than this (RMS, full scale) is refused. −50
    /// dBFS: below it the retained program is a fade or a gap, not material.
    public var minReferenceRMS: Double = 0.003_16

    /// A reference slice whose power-weighted spectral spread is narrower than
    /// this is refused. 300 Hz of spread bounds the matched filter's timing
    /// resolution at roughly 3 ms, which is the point at which a ±1 ms answer
    /// stops being available at any SNR.
    public var minReferenceBandwidthHz: Double = 300

    /// A reference slice whose own autocorrelation reaches this fraction of its
    /// energy at any lag beyond ``periodicityMinLagSeconds`` is refused as too
    /// periodic to localize.
    public var maxReferencePeriodicity: Double = 0.5

    /// Lags below this are the reference's own main lobe, not a repeat.
    public var periodicityMinLagSeconds: Double = 0.010

    /// Two candidates closer together than this are the same arrival found by
    /// two overlapping search windows; the weaker is dropped.
    public var peakSeparationSeconds: Double = 0.005

    public init() {}

    /// Measure one analysis window.
    ///
    /// - Parameters:
    ///   - reference: retained outgoing program, mono, aligned per the type's
    ///     alignment contract.
    ///   - referenceRate: that slice's sample rate (44.1 kHz today).
    ///   - capture: microphone recording, mono.
    ///   - captureRate: the capture's sample rate; all correlation happens here.
    ///   - expectedDelaysMs: one baseline delay per speaker, from chirp
    ///     calibration or the previous window's answer.
    ///   - searchHalfWidthMs: how far either side of each baseline to search —
    ///     the largest jump worth tracking (~120 ms for Bluetooth). Wider
    ///     windows admit more of the program's own repeats.
    ///   - ambientNoise: optional program-free slice of the same capture, for
    ///     noise weighting. When weighting finds nothing the plain matched
    ///     filter decides, exactly as in ``ProbeAnalyzer``.
    public func analyze(reference: [Float], referenceRate: Double,
                        capture: [Float], captureRate: Double,
                        expectedDelaysMs: [Double], searchHalfWidthMs: Double,
                        ambientNoise: [Float]? = nil) -> DriftOutcome {
        guard referenceRate > 0, captureRate > 0,
              reference.count > 1, capture.count > 1
        else { return .unusable(.slicesTooShort) }

        if let rejection = suitability(of: reference, rate: referenceRate) {
            return .unusable(rejection)
        }

        let probe = Self.resampled(reference, from: referenceRate, to: captureRate)
        guard probe.count > 1, capture.count >= probe.count else {
            return .unusable(.slicesTooShort)
        }
        let searchCount = capture.count - probe.count + 1

        var correlator = SyncProbeCorrelator(sampleRate: captureRate)
        correlator.minPeakToSidelobe = minPeakToSidelobe

        let halfWidth = Int((searchHalfWidthMs / 1000 * captureRate).rounded())
        let windows = expectedDelaysMs.map { delayMs -> Range<Int> in
            let centre = Int((delayMs / 1000 * captureRate).rounded())
            return (centre - halfWidth)..<(centre + halfWidth + 1)
        }

        // Weighting first, plain filter as the fallback — the same order and
        // the same reason as `ProbeAnalyzer.analyze`: weighting is an
        // optimization for stationary noise, and its failure is never the
        // run's.
        var found: [DriftPeak] = []
        if let ambientNoise, !ambientNoise.isEmpty,
           let corr = SyncProbeCorrelator.correlate(recording: capture, probe: probe,
                                                    ambientNoise: ambientNoise),
           corr.count >= searchCount {
            found = peaks(in: corr, searchCount: searchCount, windows: windows,
                          correlator: correlator, rate: captureRate)
        }
        if found.isEmpty {
            guard let corr = SyncProbeCorrelator.correlate(recording: capture, probe: probe,
                                                           ambientNoise: nil),
                  corr.count >= searchCount
            else { return .unusable(.noConvincingPeak) }
            found = peaks(in: corr, searchCount: searchCount, windows: windows,
                          correlator: correlator, rate: captureRate)
        }
        return found.isEmpty ? .unusable(.noConvincingPeak) : .usable(found)
    }

    // MARK: - internals

    /// Best lag per window, strongest first, with duplicates from overlapping
    /// windows removed.
    private func peaks(in corr: [Float], searchCount: Int, windows: [Range<Int>],
                       correlator: SyncProbeCorrelator, rate: Double) -> [DriftPeak] {
        let candidates = windows
            .compactMap { correlator.arrival(inCorrelation: corr, searchCount: searchCount, lags: $0) }
            .sorted { $0.peakToSidelobe > $1.peakToSidelobe }

        let separation = peakSeparationSeconds * rate
        var kept: [SyncProbeCorrelator.Arrival] = []
        for candidate in candidates
        where !kept.contains(where: { abs($0.sampleOffset - candidate.sampleOffset) < separation }) {
            kept.append(candidate)
        }
        return kept.map { DriftPeak(delayMs: $0.sampleOffset / rate * 1000,
                                    confidence: $0.peakToSidelobe) }
    }

    /// Nil when the slice can carry a timing measurement.
    private func suitability(of reference: [Float], rate: Double) -> DriftRejection? {
        var sumSquares = 0.0
        for sample in reference { sumSquares += Double(sample) * Double(sample) }
        let rms = (sumSquares / Double(reference.count)).squareRoot()
        guard rms >= minReferenceRMS else { return .referenceTooQuiet }

        guard let selfCorr = SyncProbeCorrelator.correlate(recording: reference, probe: reference,
                                                           ambientNoise: nil),
              !selfCorr.isEmpty, selfCorr[0] > 0
        else { return .slicesTooShort }

        if bandwidthHz(of: reference, rate: rate) < minReferenceBandwidthHz {
            return .referenceTooNarrowband
        }

        let minLag = max(1, Int(periodicityMinLagSeconds * rate))
        let energy = Double(selfCorr[0])
        var strongestRepeat = 0.0
        // Only lags the search could confuse for the true peak matter, and the
        // slice's own length bounds those.
        let lagCeiling = min(selfCorr.count, reference.count)
        if minLag < lagCeiling {
            for lag in minLag..<lagCeiling {
                strongestRepeat = max(strongestRepeat, abs(Double(selfCorr[lag])))
            }
        }
        guard strongestRepeat / energy < maxReferencePeriodicity else {
            return .referenceTooPeriodic
        }
        return nil
    }

    /// Power-weighted standard deviation of frequency — 0 for a pure tone,
    /// wide for anything broadband. Measured on the magnitude spectrum of the
    /// slice (real input, so only the first half of the bins is independent).
    private func bandwidthHz(of reference: [Float], rate: Double) -> Double {
        var n = 16
        while n < reference.count { n <<= 1 }
        guard let forward = vDSP.DFT(count: n, direction: .forward,
                                     transformType: .complexComplex, ofType: Float.self)
        else { return .infinity }
        let zeros = [Float](repeating: 0, count: n)
        let padded = reference + [Float](repeating: 0, count: n - reference.count)
        var re = [Float](repeating: 0, count: n)
        var im = [Float](repeating: 0, count: n)
        forward.transform(inputReal: padded, inputImaginary: zeros,
                          outputReal: &re, outputImaginary: &im)

        var total = 0.0, weighted = 0.0, weightedSquares = 0.0
        for k in 0..<(n / 2) {
            let power = Double(re[k] * re[k] + im[k] * im[k])
            let hz = Double(k) * rate / Double(n)
            total += power
            weighted += power * hz
            weightedSquares += power * hz * hz
        }
        guard total > 0 else { return 0 }
        let mean = weighted / total
        let variance = max(0, weightedSquares / total - mean * mean)
        return variance.squareRoot()
    }

    /// Linear interpolation onto the capture's rate; identity when the rates
    /// already match, so the common case costs nothing.
    static func resampled(_ samples: [Float], from: Double, to: Double) -> [Float] {
        guard from != to, from > 0, to > 0, samples.count > 1 else { return samples }
        let ratio = from / to
        let count = Int((Double(samples.count) / ratio).rounded(.down))
        guard count > 1 else { return samples }
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let position = Double(i) * ratio
            let low = Int(position)
            let high = min(low + 1, samples.count - 1)
            let fraction = Float(position - Double(low))
            out[i] = samples[low] + (samples[high] - samples[low]) * fraction
        }
        return out
    }
}
