# Sync sweeps play 6 dB quieter with 80 ms fades

The two probe sweeps in `SyncProbeCorrelator` are the sound a user hears most in the sync flow, and at full level with a 10 ms fade each end they click and read as a test tone. Decided 2026-09-05: raise the fade to 80 ms and lower the level by 6 dB. The fade lives here, in `SweepDesign`, so the phone's local copy of the sweep and the Mac's staged sweep stay identical by construction. The level does not: `SweepDesign` carries no amplitude, the phone only correlates, and the correlator's confidence is invariant to template level, so the 6 dB is the Mac's staging amplitude in `AlignmentTickInjector.stageProbe` (0.35 to 0.175), judged by a live listen on a real speaker. If the far lane reads thin, the fallback is 3 dB (0.25), never a change to the bands or the sweep direction, which the lane separation depends on.

## Consequences

- The fade is a measurement change, not a cosmetic one. It ships as one tag, pinned in both apps in the same session. A Mac on the old sweep and a phone on the new one correlate against different signals and report a confident wrong number.
- The level is Mac-only and can move without a package tag.
- `ProbeAnalyzer.sweepSeconds` and the Mac's `AlignmentTickInjector.probeSweepSeconds` are unchanged. The fade lives inside the one-second duration.
