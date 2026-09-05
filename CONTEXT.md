# Audiout

The words the Mac app, the iPhone app, and the website share. Both apps speak the protocol in this package, so a term settled here is settled for both.

## Language

**Scene**:
A saved set of speakers with a name, recalled as one target for Main Audio.
_Avoid_: Group, preset, quick config

**Main Audio**:
The Mac's system output as Audiout routes it: one fader over everything the Mac plays that no app route has claimed.
_Avoid_: Main Out, master, system output

**Speaker**:
One AirPlay, Bluetooth, or Chromecast output the Mac can play to.
_Avoid_: Device, output, endpoint (in user-facing copy)

**Measurement**:
One run of the sync probe: the Mac plays both sweeps, the iPhone's microphone hears them, and the arrival difference becomes that speaker's offset.
_Avoid_: Calibration, probe (user-facing), alignment run

**Offset**:
How late one speaker sounds relative to the reference, in milliseconds, positive when late. The Mac applies it as the correction.
_Avoid_: Trim, delay, latency, sync value

**Settled**:
The Mac's verdict that a Bluetooth speaker's delay has stopped jumping since it connected, so a measurement taken now will hold.
_Avoid_: Stable, ready, warmed up, clock locked

**First pass**:
A measurement taken before the speaker settled. Applied at once, labelled, and re-checked by the phone when the Mac says the speaker has settled.
_Avoid_: Provisional, preliminary, rough

**Timing from last time**:
The offset a Bluetooth speaker had when it was last measured, applied again on reconnect and shown under that label until a new measurement replaces it. Replaced when a re-measurement differs by 10 ms or more.
_Avoid_: Cached offset, remembered trim, stale offset

**Demo**:
The phone app running against a pretend Mac with six pretend speakers, for a reviewer or a buyer with no Mac in the room. Always labelled on screen.
_Avoid_: Sandbox, preview, sample mode, mock

**Align by ear**:
The Mac-only fallback that finds an offset from the user's answers to paired clicks, with no microphone.
_Avoid_: Wizard, calibration
