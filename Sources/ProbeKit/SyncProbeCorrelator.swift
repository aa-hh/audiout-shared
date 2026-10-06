// Copyright (C) 2026 ahh and contributors.
// SPDX-License-Identifier: MIT
//
// LICENSE-CLEAN by design (PLAN-UNIVERSAL-SYNC Decision 5 lineage): this file
// is MIT, NOT GPL, unlike most of the Mac app's sources. Everything in it is
// probe synthesis and matched-filter math ORIGINAL to this project, written
// from the published literature (Farina's exponential sine sweep; SNR-weighted
// cross-correlation), so the Apple-only Bluetooth path can share it and the
// closed-source iPhone companion can link it. Never put a GPL header on this
// file, and never move GPL-derived code into it: either would relicense the
// package out from under a consumer that cannot take GPL.
//
// ═══ ONE HOME. This file is not copied anywhere. ═══
//
// It lives in the root `ProbeKit` package and BOTH apps depend on that package:
// the Mac's built-in-mic calibration (`AudioutCore`) and the iPhone companion's
// phone-as-microphone measurement. The Mac stages the probe this file
// describes, so the two ends have to agree on them exactly — a divergence would
// not be a local bug, it would be a measurement of the wrong signal reported as
// a confident number. The package is what makes agreement structural; it
// replaced a hand-copy that had to be kept in step by hand.

import Accelerate
import Foundation

// MARK: - SyncProbe

/// Synthesis for the microphone-based sync calibration probe (the
/// mic-measurement tier above the by-ear wizard, dev/notes brief
/// `mic-probe-calibration-brief.md`).
///
/// **One template, both speakers, in turn.** Each speaker plays the same lane:
/// an exponential glide falling 3.6 kHz → 150 Hz over 3.5 s, its top tilted
/// 18 dB down, over a held 110 + 165 Hz drone. The Bluetooth
/// speaker plays first and the reference speaker ``Layout/laneSpacingSeconds``
/// later, so the lanes are separated in TIME, not frequency, and each is
/// searched only where the staging puts it
/// (``SyncProbeCorrelator/laneArrivals(of:in:ambientNoise:searchFrom:laneSpacingSeconds:maxSkewSeconds:)``).
/// Sharing one band is safe only because of that: two different signals in
/// one band separate by 21–35 dB at most, against a 23 dB level gap between
/// the Mac's own speaker and one across the room.
///
/// The energy sits low because the previous probe's 3.2–10 kHz lane was heard
/// as shrill. The faint top is what the timing locks onto: a glide confined
/// to 150–600 Hz came back from a real Bluetooth speaker as a 25 ms wide
/// smear of near-equal peaks.
/// A glide still matters: pure noise cannot be found at a pleasant level, and
/// anything that sweeps can (research note
/// `dev/notes/wizard-sync-tone-2026-10-06/shaped/ROUND3-OPTIONS.md`).
///
/// **The drone is decoration, outside the template.** A held chord matches no
/// moment of a moving glide better than any other, so it creates no rival
/// peak; it costs only the level it takes from the glide. A MOVING decoration
/// does create one: a glide a fifth below matches the template about a second
/// early, only 3 dB down. Never decorate with a parallel glide.
public enum SyncProbe {

    /// One exponential glide's parameters. `startHz > endHz` falls; both edges
    /// must be positive and distinct.
    public struct GlideDesign: Equatable, Sendable {
        public var sampleRate: Double
        public var startHz: Double
        public var endHz: Double
        public var duration: Double
        /// Amplitude of each harmonic: index 0 is the fundamental, index h−1
        /// the h-th harmonic, each an exact multiple of the fundamental's
        /// phase.
        public var partialLevels: [Double]
        /// Raised-cosine fades at each end, so the probe starts and ends
        /// without a click. The level is the Mac's, not this package's.
        public var fadeInSeconds: Double
        public var fadeOutSeconds: Double
        /// Level change per octave above `endHz`, applied as the glide passes
        /// each frequency. Negative darkens the top: −4 dB/oct puts 3.6 kHz
        /// about 18 dB under 150 Hz. 0 is a flat glide.
        public var tiltDBPerOctave: Double = 0

        /// The shipping template, on both speakers. One wide glide from 3.6 kHz
        /// down to 150 Hz with its top 18 dB down, so it sounds low but keeps
        /// a faint bright edge the timing locks onto. A glide confined to
        /// 150–600 Hz measured live (Sonos Move, 2026-10-06) as a 25 ms wide
        /// smear of near-equal peaks and was refused on every run. No
        /// harmonics: a second glide at a fixed ratio puts a copy of the
        /// template inside the other lane's search window.
        public static func probe(sampleRate: Double) -> GlideDesign {
            GlideDesign(sampleRate: sampleRate, startHz: 3_600, endHz: 150,
                        duration: Layout.glideSeconds,
                        partialLevels: [1],
                        fadeInSeconds: 0.3, fadeOutSeconds: 0.6,
                        tiltDBPerOctave: -4)
        }
    }

    /// Where the lanes sit in time, from the probe's epoch.
    public enum Layout {
        /// The drone starts this long before the glide.
        public static let bedLeadSeconds = 0.5
        public static let glideSeconds = 3.5
        /// One lane: drone lead plus glide.
        public static let laneSeconds = 4.0
        /// Lane start to lane start, which is also glide start to glide
        /// start. The Bluetooth lane plays first.
        public static let laneSpacingSeconds = 4.5
        public static let totalSeconds = laneSpacingSeconds + laneSeconds
        /// The plausible skew between the two speakers. The second lane is
        /// searched only ``laneSpacingSeconds`` ± this from the first one
        /// found, so nothing else in the correlation can be read as it.
        /// razor: deliberate ceiling; raise it only together with a wider gap
        /// between the glides.
        public static let maxSkewSeconds = 1.5
        /// The probe sound's name in analytics events.
        public static let analyticsName = "glide_chord"
    }

    /// The held chord under each glide.
    public enum Drone {
        public static let frequenciesHz = [110.0, 165.0]
        /// The drone's RMS over the lane against the glide's RMS over its own
        /// length.
        public static let levelBelowGlideDB = -6.0
        public static let fadeInSeconds = 0.3
        public static let fadeOutSeconds = 0.6
        public static let duration = Layout.laneSeconds

        /// The drone at unit amplitude per sine, fades included, zero outside
        /// `[0, duration)`.
        static func value(at t: Double) -> Double {
            guard t >= 0, t < duration else { return 0 }
            let sum = frequenciesHz.reduce(0.0) { $0 + sin(2 * .pi * $1 * t) }
            return faded(sum, at: t, duration: duration,
                         fadeIn: fadeInSeconds, fadeOut: fadeOutSeconds)
        }

        /// The factor on ``value(at:)`` that puts the drone's RMS over the
        /// lane ``levelBelowGlideDB`` under the glide's RMS.
        static func gain(sampleRate: Double) -> Double {
            func rms(_ x: [Double]) -> Double {
                x.isEmpty ? 0 : (x.reduce(0) { $0 + $1 * $1 } / Double(x.count)).squareRoot()
            }
            let glide = samples(.probe(sampleRate: sampleRate)).map(Double.init)
            let count = Int((duration * sampleRate).rounded())
            let drone = (0..<count).map { value(at: Double($0) / sampleRate) }
            let droneRMS = rms(drone)
            return droneRMS > 0 ? rms(glide) / droneRMS * pow(10, levelBelowGlideDB / 20) : 0
        }
    }

    /// The lane the Mac stages on each speaker, ``Layout/laneSeconds`` long:
    /// the drone from 0, the glide from ``Layout/bedLeadSeconds``, divided by
    /// its own peak so it peaks at exactly 1.
    ///
    /// The drone is decoration. The template the analyzers correlate against
    /// is `samples(.probe(sampleRate:))` alone.
    public static func lane(sampleRate: Double) -> [Float] {
        let count = Int((Layout.laneSeconds * sampleRate).rounded())
        let lead = Int((Layout.bedLeadSeconds * sampleRate).rounded())
        let droneGain = Drone.gain(sampleRate: sampleRate)
        var lane = (0..<count).map { droneGain * Drone.value(at: Double($0) / sampleRate) }
        for (i, g) in samples(.probe(sampleRate: sampleRate)).enumerated() where lead + i < count {
            lane[lead + i] += Double(g)
        }
        let peak = lane.reduce(0) { max($0, abs($1)) }
        return lane.map { Float(peak > 0 ? $0 / peak : 0) }
    }

    /// The glide's instantaneous value at time `t` seconds from its own start,
    /// fades included, zero outside `[0, duration)`. Exposed separately from
    /// ``samples(_:)`` so tests can render a FRACTIONALLY delayed arrival
    /// analytically instead of resampling one.
    public static func value(_ design: GlideDesign, at t: Double) -> Double {
        guard t >= 0, t < design.duration else { return 0 }
        let ratio = design.endHz / design.startHz
        let lnRatio = log(ratio)
        // phase(t) = 2π·f₀·T/ln r · (e^(t·ln r / T) − 1)  — Farina's sweep.
        let k = 2 * Double.pi * design.startHz * design.duration / lnRatio
        let phase = k * (exp(t / design.duration * lnRatio) - 1)
        var sample = 0.0
        for (index, level) in design.partialLevels.enumerated() {
            sample += level * sin(Double(index + 1) * phase)
        }
        if design.tiltDBPerOctave != 0 {
            let octavesAboveEnd = log2(design.startHz / design.endHz)
                * (1 - t / design.duration)
            sample *= pow(10, design.tiltDBPerOctave * octavesAboveEnd / 20)
        }
        return faded(sample, at: t, duration: design.duration,
                     fadeIn: design.fadeInSeconds, fadeOut: design.fadeOutSeconds)
    }

    /// Raised-cosine fade in over `fadeIn` from 0 and out over `fadeOut`
    /// before `duration`, each capped at half the duration.
    private static func faded(_ sample: Double, at t: Double, duration: Double,
                              fadeIn: Double, fadeOut: Double) -> Double {
        var sample = sample
        let fadeIn = min(fadeIn, duration / 2)
        let fadeOut = min(fadeOut, duration / 2)
        if fadeIn > 0, t < fadeIn {
            sample *= 0.5 - 0.5 * cos(.pi * t / fadeIn)
        }
        let fromEnd = duration - t
        if fadeOut > 0, fromEnd < fadeOut {
            sample *= 0.5 - 0.5 * cos(.pi * fromEnd / fadeOut)
        }
        return sample
    }

    /// The glide rendered at its design sample rate.
    public static func samples(_ design: GlideDesign) -> [Float] {
        precondition(design.startHz > 0 && design.endHz > 0 && design.startHz != design.endHz,
                     "an exponential sweep needs two positive, distinct band edges")
        let count = Int((design.duration * design.sampleRate).rounded())
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            out[i] = Float(value(design, at: Double(i) / design.sampleRate))
        }
        return out
    }
}

// MARK: - SyncProbeCorrelator

/// Offline matched filter: where, in a mic recording, does each known probe
/// arrive — and how far apart are two arrivals.
///
/// The whole calibration rests on one cancellation (the BeepBeep observation):
/// one microphone hears both speakers, so the Mac's capture latency and the
/// probes' shared scheduled start are common to both arrivals and drop out of
/// the DIFFERENCE. What survives is the per-speaker output latency difference
/// plus the speakers' distance asymmetry to the mic (~2.9 ms per metre).
///
/// Weighting is SNR-aware, not PHAT: when the caller supplies an ambient-noise
/// segment (a lead-in slice of the same recording, before the probes start),
/// correlation bins are divided by the measured noise power spectrum, so a
/// tonal interferer (a hum, a voice) is discounted instead of being whitened
/// up to equal vote. The chirp path adds no whitening on top of that. The
/// probe's −4 dB/octave tilt is deliberate (it keeps the glide low and
/// pleasant), and dividing by the probe's magnitude would undo it inside the
/// filter, lifting the faint top to a full vote and throwing away per-band
/// SNR, which is exactly the information a noisy party room needs (the 2026
/// TDOA-probing result: trained estimators learn magnitude-aware weighting and
/// never learn PHAT).
///
/// ``correlate(recording:probe:ambientNoise:whiteningExponent:sampleRate:)`` does take a
/// whitening exponent, defaulted to 0 so every chirp caller keeps the filter
/// above. ``PassiveDriftCorrelator`` passes a non-zero value because its
/// reference is music, not a sweep: a pop mix's magnitude is anything but
/// flat, and its bass repeats often enough to own the correlation background.
///
/// **Confidence is measured against the background's EXPECTED largest lag,
/// never its observed one.** The observed maximum is one sample out of a
/// quarter-million, and in any real room the arrival's own reverb tail owns
/// it: the live 2026-08-28 captures put that tail 5% of peak height, so a
/// flawless arrival scored 19 where its honest floor said 3824 — a 46 dB
/// understatement, handed to a gate. Reverb is not evidence against the peak
/// it is an echo of. So the background is summarised ROBUSTLY — a median,
/// which a few percent of contaminated lags cannot move — and scaled to the
/// largest value that many Gaussian lags would be expected to reach. Pure
/// noise still scores ~1, because its best lag is exactly that expected best
/// lag; what changes is that a quiet-but-real arrival is no longer refused
/// for having echoed. Never reach for `max()` here, however natural it looks.
///
/// Everything here is pure and hardware-free; capture and probe playback live
/// elsewhere.
public struct SyncProbeCorrelator {

    public let sampleRate: Double

    public init(sampleRate: Double) { self.sampleRate = sampleRate }

    /// Correlation peaks below this peak-to-sidelobe ratio are rejected as
    /// "probe not found" — the recording's best match is not convincingly
    /// better than its own background. Pure noise scores ~1 by construction
    /// (its best lag IS the background's expected best lag); a real arrival
    /// at sane SNR runs to the hundreds.
    public var minPeakToSidelobe: Double = 5

    /// Background estimate excludes this much on either side of the peak, wide
    /// enough to cover the sweep autocorrelation's own skirt.
    public var sidelobeExclusionSeconds: Double = 0.005

    /// The background estimate also excludes this long AFTER the peak: a real
    /// room answers a probe with its reflections, so the correlation
    /// legitimately carries secondary peaks trailing the direct path — the
    /// impulse response's tail, not evidence against the measurement. Nothing
    /// physical arrives BEFORE the direct path, so the region ahead of the
    /// peak is honest background whatever the shadow's length.
    ///
    /// The shadow is a courtesy, not the guarantee: the estimator below is
    /// what actually makes reverb harmless.
    public var reverbShadowSeconds: Double = 0.25

    /// Half-width of the neighbourhood around the peak that
    /// ``Arrival/localScore`` measures its background over.
    ///
    /// ±300 ms because that is what the Mac's replay harness
    /// (`dev/drift-window-analysis.py`, its `local` column) uses, and these
    /// two numbers are compared against each other. It is wide enough to hold
    /// several repeats of a musical bar and narrow enough that the lags in it
    /// are the ones the peak actually competes with.
    public var localBackgroundHalfWidthSeconds: Double = 0.3

    /// How far from the best lag another lag has to sit before
    /// ``Arrival/peakMargin`` counts it as a rival rather than as part of the
    /// same arrival.
    ///
    /// 3 ms, matching the same harness (its `p2p` column). The design brief
    /// said 5 ms in prose; the harness is what the two sides are measured
    /// against, so 3 ms is what ships.
    public var peakMarginSeparationSeconds: Double = 0.003
    /// How far from the peak a match must sit to count as a rival reading of
    /// the probe. Measured live (Sonos Move and a MacBook, 2026-10-06): the
    /// glide's energy sits low, and a Move smears its arrival into peaks up
    /// to 9 ms apart within 3 dB, while two runs still agreed to 1.3 ms.
    /// The guard is for readings a whole echo or a second wrong; that smear is
    /// the arrival's own width.
    public var probeMarginSeparationSeconds: Double = 0.012

    /// `median(|x|) = 0.6745 σ` for zero-mean Gaussian `x` — the constant that
    /// turns a robust median into a standard deviation.
    private static let medianOfHalfNormal = 0.674_489_750_196_081_7

    /// One probe's arrival in a recording.
    public struct Arrival: Equatable {
        /// Where the probe's first sample lands in the recording, in samples
        /// from the recording's start — fractional, via parabolic
        /// interpolation on the correlation peak.
        public var sampleOffset: Double
        /// Peak height over what the background outside the exclusion window
        /// is EXPECTED to reach: the measurement's own confidence statement.
        ///
        /// Expected, not observed — see ``SyncProbeCorrelator``'s note. The
        /// observed maximum is a single worst sample and a real room hands it
        /// to the arrival's own reverb, which reads as evidence against the
        /// very peak it came from.
        public var peakToSidelobe: Double
        /// The same statement as ``peakToSidelobe``, but measured against the
        /// background within ``SyncProbeCorrelator/localBackgroundHalfWidthSeconds``
        /// of the peak instead of the whole tape.
        ///
        /// A whole-tape background is dominated by lags nowhere near the peak.
        /// When the reference is music rather than a sweep, the lags that can
        /// actually be mistaken for the arrival are its own neighbours — the
        /// same bar one repeat later — and those are the ones this measures
        /// against. Infinity when the neighbourhood holds too few lags to
        /// summarise.
        public var localScore: Double
        /// Peak height over the highest rival lag inside the searched range.
        /// 1 means the runner-up matched the winner; infinity when there is no
        /// positive rival at all. Two readings of "rival":
        /// ``SyncProbeCorrelator/arrival(of:in:ambientNoise:)`` takes the best
        /// lag more than ``SyncProbeCorrelator/peakMarginSeparationSeconds``
        /// away on either side. The probe path
        /// (``SyncProbeCorrelator/laneArrivals(of:in:ambientNoise:searchFrom:laneSpacingSeconds:maxSkewSeconds:)``)
        /// skips ``SyncProbeCorrelator/probeMarginSeparationSeconds`` before
        /// the peak and the whole ``SyncProbeCorrelator/reverbShadowSeconds``
        /// after it, so the arrival's own smear and the room's echoes of it
        /// are not counted.
        public var peakMargin: Double
    }

    /// Finds `probe` in `recording`, or nil when no convincing peak exists.
    /// `ambientNoise` is an optional probe-free slice of the same capture used
    /// to weight the correlation by measured noise (see the type note).
    public func arrival(of probe: [Float], in recording: [Float],
                 ambientNoise: [Float]? = nil) -> Arrival? {
        guard probe.count > 1, recording.count >= probe.count else { return nil }
        let searchCount = recording.count - probe.count + 1
        guard searchCount > 0 else { return nil }
        // A refused correlation is a refused arrival. `corr` is otherwise the
        // FFT length, always ≥ `searchCount`; the count check states that
        // rather than trusting it, since every index below rides on it.
        guard let corr = Self.correlate(recording: recording, probe: probe,
                                        ambientNoise: ambientNoise, sampleRate: sampleRate),
              corr.count >= searchCount
        else { return nil }

        return arrival(inCorrelation: corr, searchCount: searchCount, lags: 0..<searchCount)
    }

    /// The best lag inside `lags`, scored against the robust background of the
    /// WHOLE correlation.
    ///
    /// Factored out of ``arrival(of:in:ambientNoise:)`` so the passive drift
    /// path can ask the same question of a narrow lag window without a second
    /// copy of the peak-and-background math. The background stays whole-tape
    /// deliberately: a window a few hundred lags wide has no honest background
    /// of its own, and scoring a peak against its own immediate neighbourhood
    /// is how a matched filter flatters itself.
    ///
    /// `claimed` lists lags another search has already taken, and
    /// `claimRadius` how far around each of them this one must stay away. Both
    /// the peak search and the runner-up that ``Arrival/peakMargin`` measures
    /// skip that ground, so a second speaker whose window overlaps the first
    /// one's can be asked what it hears APART from the arrival already
    /// accounted for, and is not scored against it either. The background
    /// estimates still count those lags: a loud arrival 40 ms away really is
    /// part of what this correlation looks like.
    ///
    /// `marginIgnoresEchoes` is the probe's reading of ``Arrival/peakMargin``:
    /// lags inside ``probeMarginSeparationSeconds`` of the peak are its own
    /// main lobe, and lags in the ``reverbShadowSeconds`` after it are the
    /// room's echoes of it, so neither counts as a rival. Only a match before
    /// the arrival, or past the shadow, can.
    func arrival(inCorrelation corr: [Float], searchCount: Int, lags: Range<Int>,
                 claimed: [Int] = [], claimRadius: Int = 0,
                 marginIgnoresEchoes: Bool = false) -> Arrival? {
        let lo = max(0, lags.lowerBound)
        let hi = min(searchCount, lags.upperBound)
        guard lo < hi, searchCount <= corr.count else { return nil }
        func isClaimed(_ i: Int) -> Bool {
            claimed.contains { abs(i - $0) <= claimRadius }
        }

        var peakIndex = lo
        var peakValue = -Float.infinity
        for i in lo..<hi where corr[i] > peakValue && !isClaimed(i) {
            peakValue = corr[i]
            peakIndex = i
        }
        guard peakValue > 0 else { return nil }

        let exclusion = max(1, Int(sidelobeExclusionSeconds * sampleRate))
        let shadow = max(exclusion, Int(reverbShadowSeconds * sampleRate))
        var background: [Float] = []
        background.reserveCapacity(searchCount)
        for i in 0..<searchCount where i < peakIndex - exclusion || i > peakIndex + shadow {
            background.append(abs(corr[i]))
        }
        guard background.count > 1 else { return nil }
        let psr = Self.score(peak: peakValue, background: &background)
        guard psr >= minPeakToSidelobe else { return nil }

        // The same estimate over the lags right around the peak. No reverb
        // shadow here: a 250 ms shadow inside a ±300 ms neighbourhood would
        // leave only the lags ahead of the peak, which is a different
        // measurement, and the harness this number is compared against
        // excludes the peak symmetrically.
        let neighbourhood = max(1, Int(localBackgroundHalfWidthSeconds * sampleRate))
        var localBackground: [Float] = []
        localBackground.reserveCapacity(2 * neighbourhood)
        for i in max(0, peakIndex - neighbourhood)..<min(searchCount, peakIndex + neighbourhood)
        where abs(i - peakIndex) > exclusion {
            localBackground.append(abs(corr[i]))
        }
        let localScore = localBackground.count > 1
            ? Self.score(peak: peakValue, background: &localBackground) : .infinity

        // The strongest lag that is not this arrival. Whether it is a rival
        // reading of the same sound or the music's next repeat, a peak the
        // runner-up nearly matches is a coin toss the caller should not act on.
        let separation = max(1, Int((marginIgnoresEchoes ? probeMarginSeparationSeconds
                                                         : peakMarginSeparationSeconds) * sampleRate))
        let echoes = marginIgnoresEchoes ? shadow : separation
        var runnerUp = -Float.infinity
        for i in lo..<hi
        where (i < peakIndex - separation || i > peakIndex + echoes)
            && corr[i] > runnerUp && !isClaimed(i) {
            runnerUp = corr[i]
        }
        let margin = runnerUp > 0 ? Double(peakValue) / Double(runnerUp) : .infinity

        // Parabola through the peak and its neighbours: the sweep's main lobe
        // spans several samples (≈ sampleRate / bandwidth), so three points
        // resolve the true maximum to a fraction of a sample.
        var offset = Double(peakIndex)
        if peakIndex > 0, peakIndex + 1 < searchCount {
            let cm = Double(corr[peakIndex - 1])
            let c0 = Double(corr[peakIndex])
            let cp = Double(corr[peakIndex + 1])
            let denom = cm - 2 * c0 + cp
            if denom < 0 {
                offset += 0.5 * (cm - cp) / denom
            }
        }
        return Arrival(sampleOffset: offset, peakToSidelobe: psr,
                       localScore: localScore, peakMargin: margin)
    }

    /// Peak height over the largest value this many lags of background are
    /// EXPECTED to reach. Sorts in place, so the caller's array is consumed.
    private static func score(peak: Float, background: inout [Float]) -> Double {
        background.sort()
        let sigma = Double(background[background.count / 2]) / medianOfHalfNormal
        let sidelobe = (2 * log(Double(background.count))).squareRoot() * sigma
        return sidelobe > 0 ? Double(peak) / sidelobe : .infinity
    }

    /// Both lanes of an in-turn probe located in one recording, as
    /// `(earlier, later)`, offsets in samples from the recording's start. Nil
    /// when either lane is missing or unconvincing — the caller falls back to
    /// the by-ear wizard, never to a shaky number.
    ///
    /// Both lanes play the same `template`, so one correlation over
    /// `recording[searchFrom...]` holds both arrivals. The stronger is found
    /// first, anywhere. The other is searched only `laneSpacingSeconds ±
    /// maxSkewSeconds` away from it, on either side, because the staging
    /// fixes that spacing and nothing else in the correlation can be trusted
    /// to stay out of the way: room reflections put weaker copies of an
    /// arrival at fixed distances from it. Each arrival ignores the
    /// other's neighbourhood (``reverbShadowSeconds``) when it measures
    /// ``Arrival/peakMargin``, so the margin is about rivals, not about the
    /// other speaker.
    public func laneArrivals(of template: [Float], in recording: [Float],
                             ambientNoise: [Float]? = nil, searchFrom: Int = 0,
                             laneSpacingSeconds: Double, maxSkewSeconds: Double)
        -> (earlier: Arrival, later: Arrival)? {
        guard template.count > 1, searchFrom >= 0,
              recording.count - searchFrom >= template.count
        else { return nil }
        let region = Array(recording[searchFrom...])
        let searchCount = region.count - template.count + 1
        guard let corr = Self.correlate(recording: region, probe: template,
                                        ambientNoise: ambientNoise, sampleRate: sampleRate),
              corr.count >= searchCount,
              let strongest = arrival(inCorrelation: corr, searchCount: searchCount,
                                      lags: 0..<searchCount, marginIgnoresEchoes: true)
        else { return nil }

        let p1 = Int(strongest.sampleOffset.rounded())
        let near = Int(((laneSpacingSeconds - maxSkewSeconds) * sampleRate).rounded())
        let far = Int(((laneSpacingSeconds + maxSkewSeconds) * sampleRate).rounded())
        let claimRadius = Int(reverbShadowSeconds * sampleRate)
        let second = [(p1 - far)..<(p1 - near + 1), (p1 + near)..<(p1 + far + 1)]
            .compactMap { arrival(inCorrelation: corr, searchCount: searchCount, lags: $0,
                                  claimed: [p1], claimRadius: claimRadius,
                                  marginIgnoresEchoes: true) }
            .max { $0.peakToSidelobe < $1.peakToSidelobe }
        guard var second,
              var first = arrival(inCorrelation: corr, searchCount: searchCount,
                                  lags: 0..<searchCount,
                                  claimed: [Int(second.sampleOffset.rounded())],
                                  claimRadius: claimRadius, marginIgnoresEchoes: true)
        else { return nil }

        first.sampleOffset += Double(searchFrom)
        second.sampleOffset += Double(searchFrom)
        return first.sampleOffset <= second.sampleOffset ? (first, second) : (second, first)
    }

    // MARK: correlation internals

    /// Linear cross-correlation of `recording` against `probe` via FFT:
    /// `corr[lag] = Σ recording[lag+i] · probe[i]`, optionally divided per
    /// frequency bin by the ambient noise power spectrum.
    ///
    /// `nil` when vDSP declines to build a transform of the required length —
    /// the only way this function fails. It is `nil` rather than `[]` on
    /// purpose: an empty array flows straight into the caller's search loop
    /// and is indexed, which is an out-of-range CRASH where this package's
    /// whole contract is to refuse instead. An Optional makes the compiler
    /// force that decision at every call site, so the guarantee cannot be
    /// deleted later by someone tidying a guard away.
    ///
    /// The failure is unreachable on macOS and reachable on a phone: a 15 s
    /// tape at 48 kHz asks for n = 2^20, each call transiently holds ~46 MB,
    /// and under iOS memory pressure the allocation can be declined.
    ///
    /// `whiteningExponent` divides each bin by the probe's own magnitude
    /// spectrum raised to that power: 0 leaves the plain matched filter
    /// untouched, 1 is the phase transform (the probe is known exactly, so
    /// dividing by its magnitude leaves phase only). Values between the two
    /// whiten partially. Every chirp caller stays at 0 — see the type note for
    /// why the calibration path does not want this — and only the passive
    /// drift path, where the reference is music rather than a sweep, passes a
    /// non-zero value.
    ///
    /// The ambient noise estimate is smoothed over 100 Hz (see
    /// ``correlations(recording:probe:ambientNoise:whiteningExponent:bandEdgesHz:sampleRate:ambientSmoothingHz:)``).
    static func correlate(recording: [Float], probe: [Float],
                          ambientNoise: [Float]?,
                          whiteningExponent: Double = 0,
                          sampleRate: Double) -> [Float]? {
        correlations(recording: recording, probe: probe, ambientNoise: ambientNoise,
                     whiteningExponent: whiteningExponent,
                     bandEdgesHz: [], sampleRate: sampleRate,
                     ambientSmoothingHz: 100)?.full
    }

    /// ``correlate(recording:probe:ambientNoise:whiteningExponent:sampleRate:)`` plus one
    /// correlation per frequency band, all from the same pair of forward
    /// transforms.
    ///
    /// A band's correlation is that same cross-spectrum with the bins outside
    /// the band set to zero, inverse-transformed. Masking a spectrum already
    /// computed costs one inverse transform per band and shifts no phase, so a
    /// band's peak sits at the lag that band would have produced had its two
    /// time signals been filtered and correlated on their own. Filtering the
    /// signals again per band would cost four more forward transforms for the
    /// same answer.
    ///
    /// `bandEdgesHz` are the edges, rising, so four bands are five numbers.
    /// Empty (the default) asks for no bands and does exactly the work of
    /// ``correlate(recording:probe:ambientNoise:whiteningExponent:sampleRate:)``.
    ///
    /// `ambientSmoothingHz` is how wide a stretch of the ambient slice's
    /// spectrum is averaged into each bin's noise estimate. Nil keeps a fixed
    /// 64 bins either side, whatever the transform length. The probe passes a
    /// fixed width in hertz: its recordings are several seconds long, so 64
    /// bins would be only a few hertz and the estimate would stay as ragged
    /// as one periodogram.
    static func correlations(recording: [Float], probe: [Float],
                             ambientNoise: [Float]?,
                             whiteningExponent: Double = 0,
                             bandEdgesHz: [Double], sampleRate: Double,
                             ambientSmoothingHz: Double?)
        -> (full: [Float], bands: [[Float]])? {
        let n = fftLength(for: recording.count + probe.count)
        guard let forward = vDSP.DFT(count: n, direction: .forward,
                                     transformType: .complexComplex, ofType: Float.self),
              let inverse = vDSP.DFT(count: n, direction: .inverse,
                                     transformType: .complexComplex, ofType: Float.self)
        else { return nil }

        let zeros = [Float](repeating: 0, count: n)
        let recPadded = recording + [Float](repeating: 0, count: n - recording.count)
        var recRe = [Float](repeating: 0, count: n)
        var recIm = [Float](repeating: 0, count: n)
        forward.transform(inputReal: recPadded, inputImaginary: zeros,
                          outputReal: &recRe, outputImaginary: &recIm)

        let probePadded = probe + [Float](repeating: 0, count: n - probe.count)
        var probeRe = [Float](repeating: 0, count: n)
        var probeIm = [Float](repeating: 0, count: n)
        forward.transform(inputReal: probePadded, inputImaginary: zeros,
                          outputReal: &probeRe, outputImaginary: &probeIm)

        // recording · conj(probe), per bin.
        var crossRe = [Float](repeating: 0, count: n)
        var crossIm = [Float](repeating: 0, count: n)
        for k in 0..<n {
            crossRe[k] = recRe[k] * probeRe[k] + recIm[k] * probeIm[k]
            crossIm[k] = recIm[k] * probeRe[k] - recRe[k] * probeIm[k]
        }

        if whiteningExponent > 0 {
            let weight = whiteningWeights(probeReal: probeRe, probeImaginary: probeIm,
                                          exponent: whiteningExponent)
            for k in 0..<n {
                crossRe[k] *= weight[k]
                crossIm[k] *= weight[k]
            }
        }

        if let ambientNoise, !ambientNoise.isEmpty {
            // A width in hertz means nothing without a sample rate; dividing
            // by a zero rate would hand `Int` an infinity and trap.
            let radius = ambientSmoothingHz.flatMap { hz in
                sampleRate > 0 ? max(1, Int((hz / 2) / (sampleRate / Double(n)))) : nil
            } ?? min(64, n / 2)
            let weight = noiseWeights(ambient: ambientNoise, fftLength: n, forward: forward,
                                      radius: radius)
            for k in 0..<n {
                crossRe[k] *= weight[k]
                crossIm[k] *= weight[k]
            }
        }

        var corrRe = [Float](repeating: 0, count: n)
        var corrIm = [Float](repeating: 0, count: n)
        inverse.transform(inputReal: crossRe, inputImaginary: crossIm,
                          outputReal: &corrRe, outputImaginary: &corrIm)
        let scale = 1 / Float(n)
        for k in 0..<n { corrRe[k] *= scale }

        var bands: [[Float]] = []
        if bandEdgesHz.count > 1, sampleRate > 0 {
            bands.reserveCapacity(bandEdgesHz.count - 1)
            for (low, high) in zip(bandEdgesHz, bandEdgesHz.dropFirst()) {
                var bandRe = crossRe
                var bandIm = crossIm
                // A real signal's spectrum is symmetric, so bin k and bin n-k
                // are the same frequency and have to be masked together.
                for k in 0..<n {
                    let hz = Double(min(k, n - k)) * sampleRate / Double(n)
                    if hz < low || hz >= high {
                        bandRe[k] = 0
                        bandIm[k] = 0
                    }
                }
                var bandCorrRe = [Float](repeating: 0, count: n)
                var bandCorrIm = [Float](repeating: 0, count: n)
                inverse.transform(inputReal: bandRe, inputImaginary: bandIm,
                                  outputReal: &bandCorrRe, outputImaginary: &bandCorrIm)
                for k in 0..<n { bandCorrRe[k] *= scale }
                bands.append(bandCorrRe)
            }
        }
        return (corrRe, bands)
    }

    /// Per-bin `1 / (noisePower + ε)` from a probe-free ambient slice: the
    /// slice's zero-padded periodogram, box-smoothed over `radius` bins either
    /// side (a single periodogram's per-bin variance is ~100%; averaging
    /// ~129 neighbours makes it a usable estimate), then regularised so
    /// near-silent bins cannot explode.
    private static func noiseWeights(ambient: [Float], fftLength n: Int,
                                     forward: vDSP.DFT<Float>, radius: Int) -> [Float] {
        let zeros = [Float](repeating: 0, count: n)
        let padded = Array(ambient.prefix(n)) + [Float](repeating: 0, count: max(0, n - ambient.count))
        var re = [Float](repeating: 0, count: n)
        var im = [Float](repeating: 0, count: n)
        forward.transform(inputReal: padded, inputImaginary: zeros,
                          outputReal: &re, outputImaginary: &im)
        var power = [Float](repeating: 0, count: n)
        for k in 0..<n { power[k] = re[k] * re[k] + im[k] * im[k] }

        var smoothed = [Float](repeating: 0, count: n)
        var prefix = [Float](repeating: 0, count: n + 1)
        for k in 0..<n { prefix[k + 1] = prefix[k] + power[k] }
        for k in 0..<n {
            let lo = max(0, k - radius)
            let hi = min(n - 1, k + radius)
            smoothed[k] = (prefix[hi + 1] - prefix[lo]) / Float(hi - lo + 1)
        }

        let mean = prefix[n] / Float(n)
        let epsilon = max(mean * 0.05, .leastNormalMagnitude)
        var weights = [Float](repeating: 0, count: n)
        for k in 0..<n { weights[k] = 1 / (smoothed[k] + epsilon) }
        return weights
    }

    /// Per-bin `1 / (probePower + ε)^(exponent/2)`: the probe's own magnitude
    /// spectrum raised to `exponent`, inverted, so bands where the probe is
    /// loud stop out-voting bands where it is quiet.
    ///
    /// Music is the reason this exists. The probe's tilt is deliberate and is
    /// not whitened away, so the chirp path leaves this at 0; a pop mix's power
    /// sits in the bass, which repeats every 5–25 ms, and the treble that
    /// actually resolves timing sits near the microphone's floor. Whitening
    /// levels the two, at the cost of giving quiet bands — where the room's
    /// noise is all there is — a full vote. The exponent sets how far to go.
    ///
    /// The floor is 5% of the probe's mean power, the same shape and the same
    /// fraction as ``noiseWeights``, so a near-empty bin divides by the floor
    /// instead of by nothing. No smoothing here: unlike the ambient slice,
    /// this spectrum is the exact known reference, not an estimate from one
    /// noisy periodogram.
    private static func whiteningWeights(probeReal re: [Float], probeImaginary im: [Float],
                                         exponent: Double) -> [Float] {
        let n = re.count
        var power = [Float](repeating: 0, count: n)
        var total = 0.0
        for k in 0..<n {
            power[k] = re[k] * re[k] + im[k] * im[k]
            total += Double(power[k])
        }
        let epsilon = max(Float(total / Double(n)) * 0.05, .leastNormalMagnitude)
        let half = Float(exponent / 2)
        var weights = [Float](repeating: 0, count: n)
        for k in 0..<n { weights[k] = 1 / powf(power[k] + epsilon, half) }
        return weights
    }

    /// Power of two covering `minimum` — vDSP's DFT wants a friendly length,
    /// and a power of two (of at least 16) always is one.
    private static func fftLength(for minimum: Int) -> Int {
        var n = 16
        while n < minimum { n <<= 1 }
        return n
    }
}
