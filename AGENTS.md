# audiout-shared

## Purpose

Everything the Audiout Mac app and the Audiout iPhone companion both need, and
nothing else. Two products in one package:

- **`AudioutProtocol`** — the wire protocol the Mac's `CompanionServer` and the
  phone speak: Bonjour constants (`CompanionProto`), the JSON envelope
  (`CompanionEnvelope`/`CompanionMessage`), the command set
  (`CompanionCommand`), and the state snapshot types (`Snapshot` and friends).
- **`ProbeKit`** — the speaker sync-measurement DSP. A DOWN sweep
  (2000→500 Hz) on the reference lane and an UP sweep (3200→10000 Hz) on the
  target lane play at one scheduled moment; one microphone hears both, so
  capture latency and the shared start cancel in the arrival DIFFERENCE. This
  package synthesises the sweeps and recovers that difference.

**This repository exists because SwiftPM cannot depend on a package inside a
subdirectory of another repo.** A git dependency's manifest has to sit at that
repository's root. The two apps are in separate repositories — the Mac app is
GPL with public source, the companion is closed and paid — so the code they
share had to become a repository of its own.

## Rules

- **Every change here lands in two apps.** Nothing in this package has a single
  consumer, so there is no such thing as a local fix. Before changing a type,
  ask what the other end does with it.
- **MIT, and every source file says so.** That is load-bearing in both
  directions: the Mac app is GPL (it links the vendored OwnTone-derived sender
  in `AirPlayEngine`), and the phone app ships closed-source. A GPL header here
  would relicense the package out from under the phone; no header at all
  defaults to all-rights-reserved, which is wrong for source published beside a
  GPL tree. Never add a GPL header, and **never copy code in from a GPL
  sibling** — retype the shape or write the type fresh.
- **The freedom rests on single authorship.** Every line here is the owner's,
  which is what makes linking it from a proprietary app his call to make. One
  outside patch merged without a licence agreement ends that, retroactively and
  permanently. No third-party contributions without a signed grant.
- **Zero dependencies, forever.** No `dependencies:` entry, no shell-out in the
  manifest. That guarantee is why this package can be reached from an iOS app
  at all — `AudioutCore` resolves Homebrew prefixes at manifest time, which does
  not exist on iOS. If something seems to need a dependency, it belongs in the
  app, not here.

### AudioutProtocol

- **Changing the wire encoding of an existing `CompanionMessage` or
  `CompanionCommand` case is a protocol break**, not a refactor — both peers
  must ship together or one silently misdecodes the other. Add a new case
  instead.
- **Bump `CompanionProto.version` only when a case's SEMANTICS change** in a way
  an old peer would misinterpret — not merely for a new case, which `.unknown`
  already absorbs.
- **Refuse-forward, not refuse-behind.** A peer advertising a version greater
  than `CompanionProto.version` is refused; an older peer is fine to talk to.
  This runs twice: on the Bonjour TXT `proto` key before a socket opens, and
  again on `hello`/`welcome`'s `protoVersion` once connected.
- **Icons ride OUTSIDE `Snapshot` on purpose.** `AppIconPayload` /
  `CompanionAppIcons` are their own request/response pair, bounded by a page
  size and a request cap, precisely so that the server's identical-snapshot
  suppression is never defeated by icon churn. Fold an icon into `Snapshot` and
  every late-resolving icon re-sends the entire app state.

### ProbeKit

- **This is the single home of `SyncProbeCorrelator.swift`.** It used to be
  hand-copied into the phone's own package. The copy is gone and must not come
  back: the Mac stages the sweeps this file describes, so a divergence between
  the two ends is not a local bug — it is a measurement of the wrong signal,
  reported as a confident number.
- **`ProbeAnalyzer.sweepSeconds` (1.0) IS still a hand-copy**, of
  `AlignmentTickInjector.probeSweepSeconds` in the Mac app. The dependency runs
  one way only — this package may never import `AudioutCore` — so those two
  constants move together by hand or not at all.
- **The lane assignment is the Mac's choice, not this package's.** DOWN is the
  reference lane, UP the target. Swapping the labels here reverses the sign of
  every measurement, and nothing fails loudly when it happens.
- **The caller reports the raw measurement; the Mac owns trim semantics.**
  `offsetMs` is positive when the target sounded LATE. No sign convention or
  trim arithmetic belongs in here.
- **Refuse rather than guess.** A capture shorter than one sweep throws
  `recordingTooShort`; a sweep not found convincingly throws `probeNotFound`.
  There is no best-effort answer — the caller falls back to asking the user by
  ear, and a wrong number is worse than none because nobody learns it was
  invented.
- **Pure DSP, and it stays that way.** No `AVFoundation`, no networking, no app
  types. Anything touching a microphone or a socket belongs in the app.

## Tests

```
swift test
```

Both suites are pure computation on synthetic input: no hardware, no phone, no
Mac app. `ProbeKitTests` renders arrivals at analytic fractional delays, so the
expected answer is exact by construction — it covers sub-sample accuracy, the
two lanes separating under a 23 dB level imbalance, echoes, hum, and every
refusal path.

Note this repo has none of the Mac repo's hooks, so nothing stops a bare
`swift` command here and nothing runs these tests for you on commit.

## Releasing

Both apps pin a version, so a change is not real to them until it is tagged:

```
git tag 0.2.0 && git push --tags
```

A protocol break needs both apps updated and shipped together — tag it, raise
the floor in both, and treat the two app-side bumps as one change.
