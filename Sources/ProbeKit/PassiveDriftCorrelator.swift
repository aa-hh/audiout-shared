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
    /// ``confidence`` measured against the lags within 300 ms of the peak
    /// instead of the whole tape — the background the peak actually competes
    /// with. Same statement as ``SyncProbeCorrelator/Arrival/localScore``.
    public var localConfidence: Double
    /// Peak height over the best rival lag more than 3 ms away inside the same
    /// search window. 1 means the runner-up matched the winner. Same statement
    /// as ``SyncProbeCorrelator/Arrival/peakMargin``.
    public var margin: Double
    /// How many of the four sub-bands put their own best lag within
    /// ``PassiveDriftCorrelator/bandAgreementToleranceMs`` of this one.
    ///
    /// The music's own repeat is a feature of the band that carries the
    /// repeat, usually the bass; a real arrival is the same event in every
    /// band at once. So four narrow correlations vote, and a lag only the
    /// loudest band believes in is not an arrival.
    public var agreeingBands: Int
    /// How far apart the agreeing bands' own lags sit, ms — 0 when fewer than
    /// two agree. Small means the bands landed on one event.
    public var bandSpreadMs: Double

    public init(delayMs: Double, confidence: Double,
                localConfidence: Double = .infinity, margin: Double = .infinity,
                agreeingBands: Int = 4, bandSpreadMs: Double = 0) {
        self.delayMs = delayMs
        self.confidence = confidence
        self.localConfidence = localConfidence
        self.margin = margin
        self.agreeingBands = agreeingBands
        self.bandSpreadMs = bandSpreadMs
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
/// ``SyncProbeCorrelator``. One thing does differ: this path whitens the
/// cross-spectrum partially by the reference's own magnitude
/// (``whiteningExponent``), which the chirp path does not, because a sweep is
/// already flat across its band and a pop mix is not.
///
/// A second thing differs: the whitened cross-spectrum is also masked into
/// four bands and inverse-transformed again, and a lag is only an arrival when
/// three of those four bands put it in the same place. One sound reaches the
/// microphone at one time in every band at once; a musical repeat belongs to
/// the band that carries it.
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
    /// the reference's own structure — less so since ``whiteningExponent``
    /// took some of that structure out. On the synthetic scenes in
    /// `PassiveDriftCorrelatorTests` a true arrival now scores 3.2–10.9 and a
    /// window containing no arrival at all scores ~0.8; 3 sits in that gap.
    /// The gap is narrow, which is why the search window and the suitability
    /// checks do most of the work and this threshold only catches what they
    /// let through.
    ///
    /// It is also no longer the only thing a peak has to clear: the whole-tape
    /// background cannot see the music's own next repeat, so ``minPeakMargin``
    /// and ``minLocalScore`` are what actually separate an arrival from one.
    /// A caller that lowered this number to accept quieter arrivals can put it
    /// back — that was what the live 2.3 was for.
    public var minPeakToSidelobe: Double = 3

    /// A peak whose best rival inside the same search window comes closer than
    /// this ratio is not reported, whatever it scored.
    ///
    /// The one number over the whole tape cannot tell a real arrival from the
    /// music's next repeat, because the repeat sits tens of milliseconds away
    /// while most of that background is lags nowhere near either. This gate
    /// asks the question the whole-tape score cannot: inside the range the
    /// caller actually searched, is the winner clear of the runner-up?
    ///
    /// 1.2 from the four live windows in `PassiveDriftFixtureTests`. The
    /// window with a repeatable arrival (21:16:33, arrival at 570.6 ms) clears
    /// its runner-up by 1.31; the three windows with nothing to find reach
    /// 1.02, 1.05 and 1.10. 1.2 is the middle of that gap. The design brief
    /// proposed 1.5 as a starting point, which these fixtures rule out — it
    /// refuses the one true arrival among them.
    public var minPeakMargin: Double = 1.2

    /// A peak whose ``SyncProbeCorrelator/Arrival/localScore`` is below this is
    /// not reported, whatever it scored over the whole tape.
    ///
    /// The whole-tape background is mostly quiet lags far from the peak, so a
    /// peak that barely stands out from its own neighbourhood can still score
    /// well on it. This gate measures the peak against the 300 ms either side
    /// of it, where the music's own repeats are.
    ///
    /// 2.4 from the same four windows: the real arrival scores 3.06 locally,
    /// and the three unusable windows reach 1.58, 1.90 and 0.90 — the last
    /// being the noise window, which scores about 1 by construction.
    public var minLocalScore: Double = 2.4

    /// How many of the four sub-bands have to land on a lag before it is
    /// reported as an arrival.
    ///
    /// A sound leaving a speaker arrives at one time, and every band that can
    /// hear it puts it there. A musical repeat does not: a bass line that
    /// comes round every 10 ms makes a false peak in the bottom band and
    /// nothing at all in the top one. Two of four still refuses a lag only
    /// the band carrying the repeat believes, and leaves room for the two
    /// bands a quiet passage can leave with nothing to hear.
    ///
    /// Two rather than three is the owner's ruling of 2026-09-14. Three
    /// refused the 21:16:33 window in `PassiveDriftFixtureTests`, a real
    /// arrival at 570.6 ms that cleared both other gates and that only the
    /// bottom and top bands voted for, the capture being the quietest in the
    /// set at -48 dBFS.
    ///
    /// The four bands are geometric across ``timingBandLowHz`` to
    /// ``timingBandHighHz``, and the music below 300 Hz is not among them —
    /// that is where the mic hears best and where the repeats live, so it
    /// gets no vote at all.
    public var minAgreeingBands: Int = 2

    /// How far a band's own best lag may sit from the full-band lag and still
    /// count as agreeing, ms.
    ///
    /// 1.5 ms is what the design brief asked for, and it is roughly what a
    /// band this narrow can resolve: the bottom band spans 400 Hz, so its
    /// correlation lobe is a couple of milliseconds wide and its peak can sit
    /// a millisecond off the full-band one while describing the same arrival.
    /// Tighter than that would refuse real agreement; looser would let the
    /// nearest repeat count as a vote.
    public var bandAgreementToleranceMs: Double = 1.5

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

    /// Lower edge of the band the suitability checks and the matched filter
    /// judge, Hz. A pop mix's power is mostly bass, and a bass note repeats
    /// every 5–25 ms, so the full-band slice looks periodic even when its
    /// transients carry plenty of timing; small Bluetooth speakers barely
    /// reproduce that bass anyway. 300 Hz rather than the chirp probe's 500:
    /// at 500 the synthetic broadband scene in `PassiveDriftCorrelatorTests`
    /// loses enough low-mid content that its quieter speaker scores 2.9, under
    /// ``minPeakToSidelobe``; at 300 it scores 3.1 and the bass-heavy scene 4.3.
    public var timingBandLowHz: Double = 300

    /// Upper edge of that band, Hz. Ignored when at or above the capture's
    /// Nyquist frequency (half its sample rate).
    public var timingBandHighHz: Double = 8_000

    /// How hard to whiten the cross-spectrum by the reference's own magnitude
    /// spectrum before the peak search: 0 is the plain matched filter, 1 the
    /// phase transform, and anything between whitens partially.
    ///
    /// 0.7 comes from a sweep of 0, 0.3, 0.5, 0.7 and 1.0 over the four live
    /// windows captured 2026-09-13 (two Bluetooth speakers, vocal pop at
    /// normal listening level, Mac built-in microphone). The plain filter
    /// resolved nothing there: the microphone hears the bass, which repeats
    /// every ~10 ms, while the treble that carries the timing sits near its
    /// floor. Whitening raised the true arrival's score — the window with the
    /// clearest arrival went 2.52 plain, 3.44, 4.21, 5.12, 6.57 — and, more
    /// to the point, raised it faster than the competing lobes 5 ms away.
    ///
    /// 0.7 rather than 1.0 because at 1.0 the second window with a credible
    /// arrival fell back below the threshold (3.10 at 0.7, 2.85 at 1.0) and a
    /// window whose three candidate lobes sat within 10% of each other was
    /// accepted on that 10%. Whitening harder gives bands where the music is
    /// quiet, and the room's own noise is all there is, a bigger vote; the
    /// literature says the same, from the other direction — Donohue,
    /// Hannemann and Dietz (Signal Processing 87(7), 2007) put the best
    /// exponent near 0.4 for speech in reverberant rooms, and Cobos et al.
    /// (IEEE/ACM TASLP 2020) find the phase transform optimal only at high
    /// signal-to-noise ratio, which a living room at 50 dBA is not. A window
    /// with no arrival in it scored ~1 at every exponent, so nothing here
    /// buys its score by lifting the background.
    public var whiteningExponent: Double = 0.7

    /// Two search windows that land this close together have found the same
    /// arrival; the baseline nearer to it keeps it and the other looks again
    /// with that lag ruled out.
    ///
    /// 1 ms, not the 5 ms this started at, because whitening sharpens the
    /// lobe to a fraction of a millisecond where the plain filter's was
    /// milliseconds wide. At 5 ms two arrivals 1.5 ms apart were reported as
    /// one (`separatesArrivalsOverAMillisecondApart`), and the caller's rule
    /// for a genuinely merged peak — one peak alone in two speakers' windows
    /// means those speakers arrived together — needs a merge to mean they
    /// really did. Two peaks this close are inside the caller's 10 ms
    /// leave-alone band either way, so splitting them never moves a speaker
    /// that was already in sync.
    public var peakSeparationSeconds: Double = 0.001

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
        analyzeWithCandidates(reference: reference, referenceRate: referenceRate,
                              capture: capture, captureRate: captureRate,
                              expectedDelaysMs: expectedDelaysMs,
                              searchHalfWidthMs: searchHalfWidthMs,
                              ambientNoise: ambientNoise).outcome
    }

    /// ``analyze(reference:referenceRate:capture:captureRate:expectedDelaysMs:searchHalfWidthMs:ambientNoise:)``
    /// plus, for diagnostics, the strongest correlation peak inside each
    /// expected delay's search window whatever its confidence — so a
    /// `.noConvincingPeak` window says whether the true arrival scored just
    /// under ``minPeakToSidelobe`` or was never in the window.
    ///
    /// Candidates clear none of the four gates: each carries its whole-tape
    /// confidence, its local one, its margin and its band vote as measured, so
    /// a refused window's log line says which gate stopped it. A candidate's
    /// delay is the full-band lag; an accepted peak's is the one the agreeing
    /// bands settled on, which sits within
    /// ``bandAgreementToleranceMs`` of it.
    ///
    /// `candidates` follows `expectedDelaysMs` order, from the correlation
    /// that decided `outcome` (noise-weighted when that found a peak, plain
    /// otherwise). A window with no positive correlation or no room inside the
    /// capture contributes nothing. Empty when the slice was refused before
    /// correlating (quiet, narrowband, periodic, too short).
    public func analyzeWithCandidates(reference: [Float], referenceRate: Double,
                                      capture: [Float], captureRate: Double,
                                      expectedDelaysMs: [Double], searchHalfWidthMs: Double,
                                      ambientNoise: [Float]? = nil)
        -> (outcome: DriftOutcome, candidates: [DriftPeak]) {
        guard referenceRate > 0, captureRate > 0,
              reference.count > 1, capture.count > 1
        else { return (.unusable(.slicesTooShort), []) }

        // Level is judged full-band: −50 dBFS is a statement about the program
        // being there at all; whether its in-band part can carry timing is the
        // bandwidth and periodicity checks' call.
        guard Self.rms(reference) >= minReferenceRMS else { return (.unusable(.referenceTooQuiet), []) }

        // One identical filter on every signal the matched filter sees. Its
        // phase response shifts reference and capture alike, so it cancels out
        // of the correlation lag (the cross-correlation of two equally
        // filtered signals is the original one smoothed by a zero-phase kernel).
        let probe = bandLimited(Self.resampled(reference, from: referenceRate, to: captureRate),
                                rate: captureRate)
        guard probe.count > 1, capture.count >= probe.count else {
            return (.unusable(.slicesTooShort), [])
        }
        if let rejection = suitability(of: probe, rate: captureRate) {
            return (.unusable(rejection), [])
        }
        let capture = bandLimited(capture, rate: captureRate)
        let ambientNoise = ambientNoise.map { bandLimited($0, rate: captureRate) }
        let searchCount = capture.count - probe.count + 1

        let centres = expectedDelaysMs.map { Int(($0 / 1000 * captureRate).rounded()) }
        let halfWidth = Int((searchHalfWidthMs / 1000 * captureRate).rounded())
        let windows = centres.map { ($0 - halfWidth)..<($0 + halfWidth + 1) }
        let bandEdges = Self.votingBandEdges(low: timingBandLowHz,
                                             high: min(timingBandHighHz, captureRate / 2))

        func measure(against ambient: [Float]?) -> [Measured]? {
            guard let corr = SyncProbeCorrelator.correlations(
                    recording: capture, probe: probe, ambientNoise: ambient,
                    whiteningExponent: whiteningExponent,
                    bandEdgesHz: bandEdges, sampleRate: captureRate),
                  corr.full.count >= searchCount
            else { return nil }
            return measurements(full: corr.full, bands: corr.bands, searchCount: searchCount,
                                windows: windows, centres: centres, rate: captureRate)
        }

        // Weighting first, plain filter as the fallback — the same order and
        // the same reason as `ProbeAnalyzer.analyze`: weighting is an
        // optimization for stationary noise, and its failure is never the
        // run's.
        var measured: [Measured] = []
        if let ambientNoise, !ambientNoise.isEmpty, let weighted = measure(against: ambientNoise) {
            measured = weighted
        }
        if !measured.contains(where: { accepts($0.peak) }) {
            guard let plain = measure(against: nil) else {
                return (.unusable(.noConvincingPeak), [])
            }
            measured = plain
        }

        let found = measured
            .filter { accepts($0.peak) }
            .map { measurement -> DriftPeak in
                var peak = measurement.peak
                peak.delayMs = measurement.agreedDelayMs
                return peak
            }
            .sorted { $0.confidence > $1.confidence }
        return (found.isEmpty ? .unusable(.noConvincingPeak) : .usable(found),
                measured.map(\.peak))
    }

    // MARK: - internals

    /// One window's answer: the peak as measured, plus the lag the agreeing
    /// bands settled on. A refused window reports the first and nothing acts
    /// on the second.
    private struct Measured {
        var peak: DriftPeak
        var agreedDelayMs: Double
    }

    /// Every gate at once. A peak that clears all four is an arrival.
    private func accepts(_ peak: DriftPeak) -> Bool {
        peak.confidence >= minPeakToSidelobe
            && peak.margin >= minPeakMargin
            && peak.localConfidence >= minLocalScore
            && peak.agreeingBands >= minAgreeingBands
    }

    /// One measurement per search window, in the caller's order, scored but
    /// not judged.
    ///
    /// Two speakers whose search windows overlap would otherwise both report
    /// the loudest arrival in the overlap and the second one would be lost —
    /// with ±120 ms windows around baselines a few milliseconds apart, that is
    /// every window. So the windows are resolved in one pass: the baseline
    /// sitting closest to a shared peak keeps it, and a window whose peak has
    /// been taken looks again with that ground ruled out. What comes back is a
    /// candidate like any other and still has to clear the gates, so two
    /// speakers that really did arrive together produce one peak and one
    /// refusal rather than an invented second arrival.
    private func measurements(full: [Float], bands: [[Float]], searchCount: Int,
                              windows: [Range<Int>], centres: [Int],
                              rate: Double) -> [Measured] {
        var scorer = SyncProbeCorrelator(sampleRate: rate)
        // The gates decide, so nothing is dropped before they see it.
        scorer.minPeakToSidelobe = 0
        let sameArrival = max(1, Int((peakSeparationSeconds * rate).rounded()))
        let keepOut = max(1, Int((scorer.peakMarginSeparationSeconds * rate).rounded()))

        let unconstrained = windows.map {
            scorer.arrival(inCorrelation: full, searchCount: searchCount, lags: $0)
        }
        func distanceFromBaseline(_ i: Int) -> Double {
            guard let arrival = unconstrained[i] else { return .infinity }
            return abs(arrival.sampleOffset - Double(centres[i]))
        }
        var claimed: [Int] = []
        var resolved = [SyncProbeCorrelator.Arrival?](repeating: nil, count: windows.count)
        for i in windows.indices.sorted(by: { distanceFromBaseline($0) < distanceFromBaseline($1) }) {
            guard let first = unconstrained[i] else { continue }
            let index = Int(first.sampleOffset.rounded())
            if !claimed.contains(where: { abs($0 - index) <= sameArrival }) {
                resolved[i] = first
                claimed.append(index)
            } else if let second = scorer.arrival(inCorrelation: full, searchCount: searchCount,
                                                  lags: windows[i], claimed: claimed,
                                                  claimRadius: keepOut) {
                resolved[i] = second
                claimed.append(Int(second.sampleOffset.rounded()))
            }
        }

        // Scored last, once every claim is known: the arrival another speaker
        // has been given is not a rival lag, and a window holding two speakers
        // would otherwise report each of them as narrowly beaten by the other.
        // The bands are asked the same question with the same ground ruled
        // out, or they would all vote for whichever arrival is louder.
        return windows.indices.compactMap { i -> Measured? in
            guard let claim = resolved[i] else { return nil }
            // Only a claim far enough away to count as a rival is ruled out.
            // One inside the keep-out is part of this arrival's own skirt,
            // which the margin already declines to score against, and ruling
            // it out would take this peak with it.
            let elsewhere = claimed.filter { abs(Double($0) - claim.sampleOffset) > Double(keepOut) }
            guard let arrival = scorer.arrival(inCorrelation: full, searchCount: searchCount,
                                               lags: windows[i], claimed: elsewhere,
                                               claimRadius: keepOut)
            else { return nil }
            let lagMs = arrival.sampleOffset / rate * 1000
            let bandLags = bands.compactMap { band -> Double? in
                scorer.arrival(inCorrelation: band, searchCount: searchCount, lags: windows[i],
                               claimed: elsewhere, claimRadius: keepOut)
                    .map { $0.sampleOffset / rate * 1000 }
            }
            let agreeing = bandLags.filter { abs($0 - lagMs) <= bandAgreementToleranceMs }.sorted()
            let spread = agreeing.count > 1 ? agreeing[agreeing.count - 1] - agreeing[0] : 0
            var peak = Self.peak(arrival, rate: rate)
            peak.agreeingBands = agreeing.count
            peak.bandSpreadMs = spread
            return Measured(peak: peak, agreedDelayMs: Self.median(agreeing) ?? lagMs)
        }
    }

    /// The voting bands' edges, geometric across the band the matched filter
    /// already judges — four bands, five numbers. The same edges the Mac's
    /// replay harness (`dev/drift-window-analysis.py`) prints in its `bands`
    /// row, so the two answers are about the same signals.
    static func votingBandEdges(low: Double, high: Double, count: Int = 4) -> [Double] {
        guard low > 0, high > low, count > 0 else { return [] }
        let ratio = pow(high / low, 1 / Double(count))
        return (0...count).map { low * pow(ratio, Double($0)) }
    }

    private static func median(_ sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    private static func peak(_ arrival: SyncProbeCorrelator.Arrival, rate: Double) -> DriftPeak {
        DriftPeak(delayMs: arrival.sampleOffset / rate * 1000,
                  confidence: arrival.peakToSidelobe,
                  localConfidence: arrival.localScore,
                  margin: arrival.peakMargin)
    }

    /// Nil when the band-limited slice can carry a timing measurement.
    private func suitability(of reference: [Float], rate: Double) -> DriftRejection? {
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

    private static func rms(_ samples: [Float]) -> Double {
        var sumSquares = 0.0
        for sample in samples { sumSquares += Double(sample) * Double(sample) }
        return (sumSquares / Double(samples.count)).squareRoot()
    }

    /// ``timingBandLowHz``–``timingBandHighHz`` as a 2nd-order Butterworth
    /// high-pass then low-pass (audio-EQ-cookbook biquads, Q = 1/√2). An edge
    /// at or above Nyquist, or at or below 0, is left out.
    func bandLimited(_ samples: [Float], rate: Double) -> [Float] {
        func section(hz: Double, highPass: Bool) -> [Double] {
            let w0 = 2 * Double.pi * hz / rate
            let cosW = cos(w0), alpha = sin(w0) / 2.squareRoot()
            let a0 = 1 + alpha
            let b = highPass ? [(1 + cosW) / 2, -(1 + cosW), (1 + cosW) / 2]
                             : [(1 - cosW) / 2, 1 - cosW, (1 - cosW) / 2]
            // vDSP's order: b0, b1, b2, a1, a2, with a0 normalised to 1.
            return b.map { $0 / a0 } + [-2 * cosW / a0, (1 - alpha) / a0]
        }
        var coefficients: [Double] = []
        if timingBandLowHz > 0, timingBandLowHz < rate / 2 {
            coefficients += section(hz: timingBandLowHz, highPass: true)
        }
        if timingBandHighHz > 0, timingBandHighHz < rate / 2 {
            coefficients += section(hz: timingBandHighHz, highPass: false)
        }
        guard !coefficients.isEmpty,
              var filter = vDSP.Biquad(coefficients: coefficients, channelCount: 1,
                                       sectionCount: vDSP_Length(coefficients.count / 5),
                                       ofType: Float.self)
        else { return samples }
        return filter.apply(input: samples)
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
