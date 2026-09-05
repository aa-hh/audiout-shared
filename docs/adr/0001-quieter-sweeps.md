# Sync sweeps play 6 dB quieter with 80 ms fades

The two probe sweeps in `SyncProbeCorrelator` are the sound a user hears most in the sync flow, and at full level with a 10 ms fade each end they click and read as a test tone. Decided 2026-09-05: lower the level by 6 dB and raise the fade to 80 ms, in this package, so the phone's local copy of the sweep and the Mac's staged sweep stay identical by construction. The correlator's synthetic tests pass at a 23 dB level imbalance between lanes, so 6 dB of margin is spent on comfort with headroom left; if those tests show the peak-over-background margin dropping, the fallback is 3 dB with 40 ms fades, never a change to the bands or the sweep direction, which the lane separation depends on.

## Consequences

- This is a measurement change, not a cosmetic one. It ships as one tag, pinned in both apps in the same session. A Mac on the old sweep and a phone on the new one correlate against different signals and report a confident wrong number.
- `ProbeAnalyzer.sweepSeconds` and the Mac's `AlignmentTickInjector.probeSweepSeconds` are unchanged. The fade lives inside the one-second duration.
