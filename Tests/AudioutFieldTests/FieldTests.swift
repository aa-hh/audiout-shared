// Copyright (C) 2026 ahh and contributors.
// SPDX-License-Identifier: MIT

import Testing
@testable import AudioutField

/// Confirms `field.json` decodes and spot-checks a few sentinels, so a value
/// that drifts from the site's `emitters.js`/`house-groups-bg.js` fails a
/// build instead of a screenshot diff nobody looks at.
@Suite struct FieldTests {
    @Test func defaultsDecodeWithKnownSentinels() {
        #expect(AudioutField.defaults.squash == 1.12)
        #expect(AudioutField.defaults.sharp == 4.0)
        #expect(AudioutField.defaults.gain == 0.65)
        #expect(AudioutField.defaults.paperLift == 1.94)
        #expect(AudioutField.defaults.emitters.count == 3)
    }

    @Test func ramps() {
        #expect(AudioutField.ramps.count == 3)
        #expect(AudioutField.ramps["Movie night"]?.mid == [0.169, 1.0, 0.561])
    }
}
