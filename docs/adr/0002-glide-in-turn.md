# The sync probe is one low glide, played by each speaker in turn

The owner heard the two simultaneous sweeps as shrill, the Bluetooth lane's 3.2–10 kHz above all, and chose a replacement by ear on 2026-10-06: a glide falling 600 → 150 Hz over 3.5 s with its 2nd and 3rd partials at −12 and −18 dB, over a held 110 + 165 Hz drone that starts 0.5 s earlier. Both speakers play the same 4.0 s lane, the Bluetooth speaker first and the reference 4.5 s later, 8.5 s in all, and each lane is searched only where that spacing puts it. The template, the drone and the spacing live in `SyncProbe` (`GlideDesign.probe`, `Drone`, `Layout`), so the Mac's staged lane and the phone's template stay identical by construction. The level stays the Mac's: `SyncProbe.lane` peaks at 1 and the Mac scales it. The second lane is searched within 1.5 s of the staged spacing. Both apps refuse a reading whose `peakMargin` is under 1.995 (6 dB): a moving decoration, such as a glide a fifth below, puts a rival about a second early only 3 dB down. This supersedes 0001, whose last sentence kept the one-second sweep length (`ProbeAnalyzer.sweepSeconds`, `AlignmentTickInjector.probeSweepSeconds`) with its 80 ms fade inside it: 0002 replaces the sweep design entirely, bands and sweep direction included, because separating the lanes in time made disjoint bands unnecessary.

## Consequences

- The template and the spacing are a measurement change. They ship as one tag, pinned in both apps in the same session. A Mac on the old sweeps and a phone on the glide correlate against different signals and report a confident wrong number.
- `ProbeAnalyzer` removes the 4.5 s spacing itself, so `offsetMs` keeps its old meaning and the Mac keeps trim semantics.
- The probe takes 8.5 s instead of 1 s, so both apps' capture limits and timeouts grow with it.

## Amendment, same day

The first live run on a Sonos Move refused every measurement. A glide confined to 150–600 Hz came back through the speaker and the room as a 25 ms wide smear of near-equal peaks, and the two analysis passes disagreed by 60 ms on the same recording. The template is now one glide falling 3.6 kHz → 150 Hz with a −4 dB per octave tilt, so the top sits about 18 dB under the bottom (round-3 candidate E24, capped at 3.6 kHz so 8 kHz test scenes stay below Nyquist). It keeps the low character and gives the timing a sharp edge. The harmonics are gone: a second glide at a fixed ratio puts a copy of the template inside the other lane's window.
