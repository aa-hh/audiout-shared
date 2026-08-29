# audiout-shared

The code the Audiout Mac app and the Audiout iPhone companion both need.

Two products, no dependencies, MIT:

- **`AudioutProtocol`** — the wire protocol between them. Bonjour constants,
  the JSON envelope, the command set, and the state snapshot types.
- **`ProbeKit`** — the speaker sync-measurement DSP. Sweep synthesis, and the
  matched filter that recovers how far apart two speakers sounded from a single
  microphone recording of both.

It is its own repository because SwiftPM cannot depend on a package that lives
in a subdirectory of another repo, and the two apps live in separate
repositories: the Mac app is GPL with public source, the companion is closed
and paid. MIT here is what lets both of them link it.

## Using it

```swift
.package(url: "https://github.com/aa-hh/audiout-shared.git", from: "0.1.0"),
```

```swift
.product(name: "AudioutProtocol", package: "audiout-shared"),
.product(name: "ProbeKit", package: "audiout-shared"),
```

## Tests

Run the package's own suite from the repo root — no hardware, no phone, no Mac
app, since every test here is pure computation on synthetic input.

```
swift test
```
