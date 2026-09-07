# Security policy

## Supported versions

The latest tagged release is the supported one. Fixes ship as a new tag, never
as patches to older tags. Both apps pin this package with `from:` and move the
pin forward when a fix lands — the Mac app and the iPhone companion move
together, or not at all.

## Reporting a vulnerability

**Please don't open a public issue.** Email **support@audiout.app** with:

- what the flaw is and roughly how bad you think it is,
- how to reproduce it — ideally a failing input or test vector,
- the package tag and the `CompanionProto.version` you saw it on.

You'll get an acknowledgement within a few days. If it's a real issue you'll be
credited in the release notes unless you'd rather not be. It's one address for
the whole product: this package, the Mac app, the iPhone companion, the licence
server and the website.

## Please report, don't patch

This package is single-authored on purpose. Every line is the owner's, which is
what lets it be MIT here and linked from a closed-source app — one outside
patch merged without a licence agreement ends that, retroactively and
permanently. So a pull request with a fix can't be merged without a signed
grant, however good the fix is.

Send a description or a failing input instead. That's a licensing constraint,
not a judgement on your work.

## In scope

- **`AudioutProtocol`** — a crash, hang, unbounded allocation or mis-decode on
  hostile JSON. The custom decoder in `CompanionMessage.swift` and the icon
  page caps in `CompanionAppIcon.swift` are the places to look. A way past the
  refuse-forward version check (`CompanionProto.isIncompatible`) counts too.
- **`ProbeKit`** — an out-of-bounds read or non-termination on an arbitrary
  buffer, in `ProbeAnalyzer` or `SyncProbeCorrelator`. It's meant to refuse
  rather than guess, and a refusal that turns into a crash is a bug.

## Not in scope

- **Frame size limits and transport auth.** They live in the apps: the 1 MB
  inbound cap is the Mac app's, and so is the approval prompt.
- **"A trusted peer can send valid commands."** The peer is trusted by design;
  that's what the approval is for.
- **Issues in the apps themselves.** The Mac app has its own policy at
  https://github.com/aa-hh/Audiout. The iPhone companion is private — use the
  same email.

A flaw found through either app that turns out to live here is fixed here,
tagged, and pinned forward in both apps.
