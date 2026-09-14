// Copyright (C) 2026 ahh and contributors.
// SPDX-License-Identifier: MIT
//
// LICENSE-CLEAN by design, like `SyncProbeCorrelator` beside it: MIT, not GPL,
// and nothing GPL-derived may move in. See that file's note before editing
// either.

import Foundation

/// Evidence from the last few analysis windows, added together.
///
/// One 4-second window of ordinary music often scores just under
/// ``PassiveDriftCorrelator``'s gates even when the arrival is real, so a true
/// delay gets thrown away window after window. The correlation values
/// themselves carry the evidence, so this keeps the last few windows'
/// ``DriftSlice`` per speaker and sums them: a lag several windows quietly
/// agree on stands up where no single one of them could.
///
/// Memory: ``windowLimit`` slices per key, and a ±120 ms window at 48 kHz is
/// about 11,500 floats — roughly 140 kB per speaker.
public struct PassiveDriftAccumulator {

    /// How many windows are kept per key. Older ones fall off the front.
    public static let windowLimit = 3

    /// How far a window's own best lag may sit from the summed answer and
    /// still count as agreeing with it, ms.
    public static let voteToleranceMs = 1.5

    /// How many stored windows must agree before an answer is returned.
    public static let minAgreeingWindows = 2

    /// Newest last, at most ``windowLimit`` per key.
    private var history: [String: [DriftSlice]] = [:]

    public init() {}

    /// Record one window's slice for a speaker.
    ///
    /// A slice whose lag step differs from the stored history replaces that
    /// history: two capture rates cannot be summed onto one lag axis, and the
    /// new rate is the one in force.
    public mutating func add(_ slice: DriftSlice, forKey key: String) {
        var stored = history[key] ?? []
        if stored.first?.lagStepMs != slice.lagStepMs { stored = [] }
        stored.append(slice)
        if stored.count > Self.windowLimit { stored.removeFirst(stored.count - Self.windowLimit) }
        history[key] = stored
    }

    public mutating func removeAll() { history.removeAll() }

    /// The lag the stored windows agree on, or nil when they do not.
    ///
    /// The slices are summed by absolute lag, not by array index — windows
    /// searched around different baselines cover different lag ranges, and
    /// adding them index-wise would add unrelated lags together. Only the lags
    /// every stored window actually covers are summed.
    ///
    /// The newest window must be one of the agreeing ones. Without that,
    /// two old windows would go on confirming the same lag through every later
    /// refused window — including a window taken to verify a correction — so a
    /// guessed correction could end up verifying itself.
    public func consensus(forKey key: String) -> (lagMs: Double, agreeingWindows: Int, windowCount: Int)? {
        guard let stored = history[key], stored.count >= Self.minAgreeingWindows,
              let step = stored.first?.lagStepMs, step > 0
        else { return nil }

        // The lag range every window covers.
        let start = stored.map(\.firstLagMs).max()!
        let end = stored.map { $0.firstLagMs + Double($0.values.count) * $0.lagStepMs }.min()!
        let count = Int(((end - start) / step).rounded(.down))
        guard count > 1 else { return nil }

        var sum = [Float](repeating: 0, count: count)
        for slice in stored {
            let offset = Int(((start - slice.firstLagMs) / step).rounded())
            for i in 0..<count where offset + i < slice.values.count {
                sum[i] += slice.values[offset + i]
            }
        }

        var scorer = SyncProbeCorrelator(sampleRate: 1000 / step)
        scorer.minPeakToSidelobe = 0
        guard let peak = scorer.arrival(inCorrelation: sum, searchCount: sum.count,
                                        lags: 0..<sum.count)
        else { return nil }

        let lagMs = start + peak.sampleOffset * step
        let agreeing = stored.filter { slice in
            slice.bestLagMs.map { abs($0 - lagMs) <= Self.voteToleranceMs } ?? false
        }
        guard agreeing.count >= Self.minAgreeingWindows,
              stored.last?.bestLagMs.map({ abs($0 - lagMs) <= Self.voteToleranceMs }) == true
        else { return nil }

        return (lagMs, agreeing.count, stored.count)
    }
}
