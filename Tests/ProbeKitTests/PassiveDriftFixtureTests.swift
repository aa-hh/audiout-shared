// Copyright (C) 2026 ahh and contributors.
// SPDX-License-Identifier: MIT
//
// LICENSE-CLEAN by design, like the files under test: MIT, not GPL.

import Foundation
import Testing
@testable import ProbeKit

/// The synthetic scenes in `PassiveDriftCorrelatorTests` know their own answer
/// exactly; a room does not. These fixtures are real dumped windows — the mix
/// the Mac sent and what its microphone heard — band-limited, resampled to
/// 24 kHz and stored as Int16 by `tools/make-drift-fixtures.py`.
///
/// What they are for: a written-down record of what today's correlator scores
/// on real material, so a later change to it can be judged against something
/// other than a synthetic scene. Nothing here asserts an arrival. Most of the
/// first four windows are refused, that refusal is the finding, and a test that
/// failed on it would have to be deleted before the algorithm could be worked
/// on at all.
///
/// Adding windows takes no code change: re-run the generator over the new dump
/// directory and commit what it writes.
@Suite struct PassiveDriftFixtureTests {

    /// One dumped window, decoded and ready to correlate.
    struct Fixture: Decodable {
        var name: String
        /// How the window was recorded, from the dump's own labels file:
        /// `good` (music at a normal level), `noise`, `garbage` (speakers
        /// muted at their own buttons), `jump+40` (one speaker's trim moved by
        /// a known amount).
        var label: String
        var referenceRate: Double
        var captureRate: Double
        var referenceFullScale: Double
        var captureFullScale: Double
        var baselines: [Baseline]
        /// Present only where the recording forced a known delay change, so
        /// the right answer is known rather than merely expected.
        var trueDelayMs: Double?

        struct Baseline: Decodable {
            var expectedDelayMs: Double
            var anchor: Bool
        }

        var expectedDelaysMs: [Double] { baselines.map(\.expectedDelayMs) }

        /// Int16 little-endian, scaled back to the amplitude it was dumped at.
        /// The correlator refuses a reference under −50 dBFS, so a fixture that
        /// came back normalised would not be the same measurement.
        static func samples(_ url: URL, fullScale: Double) throws -> [Float] {
            let data = try Data(contentsOf: url)
            return (0..<(data.count / 2)).map { i in
                let value = Int16(bitPattern: UInt16(data[i * 2]) | UInt16(data[i * 2 + 1]) << 8)
                return Float(Double(value) / 32_767 * fullScale)
            }
        }

        func reference(in directory: URL) throws -> [Float] {
            try Self.samples(directory.appendingPathComponent("\(name)-ref.i16"),
                             fullScale: referenceFullScale)
        }

        func capture(in directory: URL) throws -> [Float] {
            try Self.samples(directory.appendingPathComponent("\(name)-cap.i16"),
                             fullScale: captureFullScale)
        }
    }

    private struct Manifest: Decodable {
        var rate: Double
        var fixtures: [Fixture]
    }

    static let directory = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")

    static func manifest() throws -> [Fixture] {
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        return try JSONDecoder().decode(Manifest.self, from: data).fixtures
    }

    /// Every fixture through the correlator, printed. The numbers are the
    /// record; the assertions are only that the fixtures are all there and
    /// decode to the signals their sidecars describe.
    @Test func measuresEveryFixture() throws {
        let fixtures = try Self.manifest()
        #expect(fixtures.count >= 4)

        for fixture in fixtures {
            let reference = try fixture.reference(in: Self.directory)
            let capture = try fixture.capture(in: Self.directory)
            #expect(reference.count > 1)
            #expect(capture.count >= reference.count)

            let result = PassiveDriftCorrelator().analyzeWithCandidates(
                reference: reference, referenceRate: fixture.referenceRate,
                capture: capture, captureRate: fixture.captureRate,
                expectedDelaysMs: fixture.expectedDelaysMs, searchHalfWidthMs: 120)

            let verdict: String
            switch result.outcome {
            case .usable(let peaks):
                verdict = "usable " + peaks.map { String(format: "%.1fms@%.2f", $0.delayMs, $0.confidence) }
                    .joined(separator: " ")
            case .unusable(let reason):
                verdict = "unusable \(reason.rawValue)"
            }
            print("FIXTURE \(fixture.name) label=\(fixture.label) \(verdict)")
            // One line per expected delay, in the order the fixture lists them,
            // whatever the confidence. This is what the Python harness in the
            // Mac repo is compared against: `drift-window-analysis.py
            // --fixtures <dir> --swift <this output>`.
            for (expected, candidate) in zip(fixture.expectedDelaysMs, result.candidates) {
                print(String(format: "CANDIDATE %@ expected=%.2f lag=%.2f score=%.4f local=%.4f margin=%.4f bands=%d spread=%.2f",
                             fixture.name, expected, candidate.delayMs, candidate.confidence,
                             candidate.localConfidence, candidate.margin,
                             candidate.agreeingBands, candidate.bandSpreadMs))
            }
        }
    }

    /// The gates and the band vote, at the score threshold the Mac app ran
    /// live.
    ///
    /// Live test 3 (2026-09-13) accepted the 21:13:33 window at 574.3 ms with
    /// a whole-tape score of 2.40 and corrected a speaker that had not moved.
    /// Its peak stands 2% clear of the next lag in the same window and one
    /// sub-band out of four puts the arrival there; neither is visible to the
    /// whole-tape score. So this fixes both halves: with the gates and the
    /// vote off, 2.3 accepts that window again — the defect — and with them on
    /// it is refused.
    ///
    /// The 21:16:33 window is the one the vote must not refuse. Its two gates
    /// pass (margin 1.46, local 3.06) and two bands carry it: the 300–682 Hz
    /// and 3520–8000 Hz bands put the arrival at 570.6 and 571.2, the two
    /// middle bands at 585.3 and 593.7. That capture is the quietest in the
    /// set at −48 dBFS, which is why two of its four bands hear nothing to
    /// vote with. Ticket 10 asked for 3 of 4, which refused it; the owner
    /// ruled 2 of 4 on 2026-09-14 and it comes back, while every other
    /// refusal here still holds.
    @Test func gatesAndBandVoteRefuseWhatTheScoreAloneAccepted() throws {
        var correlator = PassiveDriftCorrelator()
        correlator.minPeakToSidelobe = 2.3

        var ungated = correlator
        ungated.minPeakMargin = 0
        ungated.minLocalScore = 0
        ungated.minAgreeingBands = 0

        for fixture in try Self.manifest() where fixture.name.hasPrefix("2026-09-13") {
            let reference = try fixture.reference(in: Self.directory)
            let capture = try fixture.capture(in: Self.directory)
            func analyze(_ correlator: PassiveDriftCorrelator) -> (DriftOutcome, [DriftPeak]) {
                correlator.analyzeWithCandidates(
                    reference: reference, referenceRate: fixture.referenceRate,
                    capture: capture, captureRate: fixture.captureRate,
                    expectedDelaysMs: fixture.expectedDelaysMs, searchHalfWidthMs: 120)
            }

            let (outcome, candidates) = analyze(correlator)
            let votes = candidates.map { "\($0.agreeingBands)" }.joined(separator: ",")

            if fixture.name == "2026-09-13T21-16-33Z-good" {
                var accepted: [Double] = []
                if case .usable(let peaks) = outcome { accepted = peaks.map(\.delayMs) }
                #expect(accepted.count == 1,
                        "two of four should accept this window: \(accepted)")
                #expect(accepted.contains { abs($0 - 570.6) <= 1 },
                        "the accepted arrival is the 570.6 ms one: \(accepted)")
                #expect(candidates.first?.agreeingBands == 2,
                        "\(fixture.name) rests on exactly two bands: \(votes)")
                continue
            }

            #expect(outcome == .unusable(.noConvincingPeak),
                    "\(fixture.name) holds no arrival the estimator can stand behind")
            #expect(candidates.allSatisfy { $0.agreeingBands < 2 },
                    "\(fixture.name) should have no lag two bands agree on: \(votes)")

            if fixture.name == "2026-09-13T21-13-33Z-good" {
                #expect(analyze(ungated).0 != .unusable(.noConvincingPeak),
                        "the gates and the vote have stopped being what refuses it")
            }
        }
    }

    /// The forced +40 ms trim, read off the windows either side of it.
    ///
    /// Both speakers play the same music, so with ±120 ms search windows
    /// around baselines a few milliseconds apart every window contains both
    /// arrivals and the plain search hands the same global maximum to both
    /// baselines. Ticket 09's whitened filter did not change that — it is the
    /// claim resolution that does: the baseline nearest a shared peak keeps
    /// it and the other looks again with that lag ruled out, so each speaker
    /// owns an arrival of its own.
    ///
    /// What the +40 ms trim does to these windows is widen the distance
    /// between the two arrivals by the trim, and that is what this measures.
    /// It does NOT compare a speaker's arrival between blocks: the tracker was
    /// running live and corrected both speakers during the good blocks (the
    /// dumps' own baselines move from 537/529 to 562.8/562.8), and each
    /// relaunch rolls a fresh Bluetooth link latency, so no arrival is the
    /// same measurement twice across a block boundary.
    @Test func theForcedJumpWidensTheGapBetweenTheTwoArrivals() throws {
        let correlator = PassiveDriftCorrelator()
        var gaps: [String: Double] = [:]
        var secondSpeaker: [String: Double] = [:]

        for fixture in try Self.manifest() where fixture.name.hasPrefix("2026-09-14") {
            let reference = try fixture.reference(in: Self.directory)
            let capture = try fixture.capture(in: Self.directory)
            let result = correlator.analyzeWithCandidates(
                reference: reference, referenceRate: fixture.referenceRate,
                capture: capture, captureRate: fixture.captureRate,
                expectedDelaysMs: fixture.expectedDelaysMs, searchHalfWidthMs: 120)
            let lags = result.candidates.map(\.delayMs)
            #expect(lags.count == 2, "\(fixture.name) measured \(lags.count) windows, not 2")
            guard lags.count == 2 else { continue }
            gaps[fixture.name] = abs(lags[0] - lags[1])
            secondSpeaker[fixture.name] = lags.min()!
            let accepted: Int
            if case .usable(let peaks) = result.outcome { accepted = peaks.count } else { accepted = 0 }
            print(String(format: "JUMP %@ lags %.2f / %.2f  gap %.2f  accepted %d",
                         fixture.name, lags[0], lags[1], abs(lags[0] - lags[1]), accepted))
        }

        let good = ["2026-09-14T08-45-08Z-good", "2026-09-14T08-51-08Z-good",
                    "2026-09-14T09-36-08Z-good"].compactMap { gaps[$0] }
        let jumped = ["2026-09-14T09-45-55Z-jump+40", "2026-09-14T09-51-55Z-jump+40",
                      "2026-09-14T09-54-55Z-jump+40"].compactMap { gaps[$0] }
        #expect(good.count == 3 && jumped.count == 3)
        guard good.count == 3, jumped.count == 3 else { return }

        let widening = jumped.reduce(0, +) / 3 - good.reduce(0, +) / 3
        print(String(format: "JUMP widening %.2f ms (good %@, jumped %@)", widening,
                     good.map { String(format: "%.1f", $0) }.joined(separator: "/"),
                     jumped.map { String(format: "%.1f", $0) }.joined(separator: "/")))
        #expect(abs(widening - 40) <= 2, "the +40 ms trim reads \(widening) ms")

        // The speaker whose trim never moved. Its arrival is the earlier of
        // the two in every window from the jump onwards, including the first
        // window after the trim was taken back out.
        let unmoved = ["2026-09-14T09-45-55Z-jump+40", "2026-09-14T09-51-55Z-jump+40",
                       "2026-09-14T09-54-55Z-jump+40", "2026-09-14T10-01-16Z-good"]
            .compactMap { secondSpeaker[$0] }
        #expect(unmoved.count == 4)
        if let low = unmoved.min(), let high = unmoved.max() {
            #expect(high - low <= 2, "the untouched speaker moved: \(unmoved)")
        }
    }
}
