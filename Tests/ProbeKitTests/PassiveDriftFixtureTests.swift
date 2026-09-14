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
                print(String(format: "CANDIDATE %@ expected=%.2f lag=%.2f score=%.4f",
                             fixture.name, expected, candidate.delayMs, candidate.confidence))
            }
        }
    }
}
