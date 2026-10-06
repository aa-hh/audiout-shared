# Readability rubric (Guard 7 and the branch review)

This rubric has two consumers. Guard 7's deterministic screen runs at commit
and blocks only the three near-certain slop patterns below. The branch code
review, `scripts/review-branch.sh`, runs on each pull request before it lands on
`main`; its instruction files in `docs/review/` carry a digest of this file.
Readability is one category of that review; bugs come first.

Copied from the Audiout Mac repo, where it came out of a 2026-08-06 audit:
240 findings, of which the two biggest categories were comments narrating
git-owned history and comments that had drifted into being *wrong*.

## Remove before committing

1. **Change-log narration** — "replaces the old X", "previously", "used to",
   "(fixed 2026-07-26)", "(architecture review …, defect B)", commit hashes,
   "this session". Git owns history. EXCEPTION: a past live regression cited
   as the WHY a guard exists is a trap doc — keep it, present tense.
2. **Stale claims** — "a later task wires this", "no caller passes true yet",
   "BUILD-ONLY scope" on shipped code. If you touched a comment's
   neighborhood, verify its claims still hold; a wrong comment is worse than
   none.
3. **Narration** — restating the adjacent line ("// Start the timer").
4. **Reviewer-speak** — "correctly handles", "to be safe", "purely additive,
   no new locking", "not a regression from …". You are talking to the diff
   reviewer, not the next reader; it is noise the moment the branch merges.
5. **Redundant doc comments** — `///` adding nothing beyond the signature.
   Public API keeps a doc comment, but it must say something (units,
   lifecycle, retention).
6. **Hedges** — "for now", "might not be ideal". A real ceiling becomes one
   terse sentence naming the ceiling and upgrade path.
7. **Orphan tags** — task ids that grep to nothing under `docs/`.
   References to an ADR in `docs/adr/` are live traceability — keep them.
8. **Commented-out code** and debug leftovers (bare `print` in library code —
   CLI/snapshot tools print by design).

## Naming (the part that bites hardest)

- **Misleading names** — says X, does Y (`updateRouting` that syncs
  exclusions; `displayHeight` that returns a width). Highest value; fix or
  flag, never ship silently.
- Journey names (`finalResult`, `updatedDevice`, `tempX`), type echo
  (`deviceArray`, `-State` suffixes), generic nouns in specific roles
  (`data`, `info`, `result`).
- Match the file's existing vocabulary and the glossary in `CONTEXT.md`
  (its "Avoid" lists are deliberate).
- Scope-length rule: single letters die outside tight loops.

## Protected — never "clean up"

- Why-heavy trap comments: wire-format constraints, lane and sign
  conventions, DSP gotchas, "NEVER/ONLY/must" invariants, ALL-CAPS emphasis inside
  them. This repo's long constraint comments are deliberate. Length alone is
  never a finding.
- ADR references; `razor:`; trailing `slop-ok` / `real-time-ok` /
  `print-ok` / `new-suite-ok` markers; the SPDX licence header; string
  literals of every kind (wire keys, command names, JSON keys in
  `field.json`).

## Mechanics

- The deterministic screen hard-blocks only near-certain slop ("this
  session", dated changelog parentheticals, `=====` banners). A rare
  legitimate hit takes a trailing `slop-ok` comment.
- `git commit --no-verify` remains the documented emergency escape, same as
  every guard.
- The reviewing models run once per pull request (twice at most), never
  inside a hook. They run as subagents of the Claude session that owns the
  branch, because headless `claude -p` is refused on this account:
  `bash scripts/review-branch.sh`, follow its printed steps, then
  `bash scripts/review-branch.sh --continue`, which posts the findings as one
  PR comment and sets the `review` commit status the pull request needs.
- Review discipline (branch review and PR review): fewer correct findings
  beat many doubtful ones, and a complexity finding must name exactly what to
  delete and what replaces it — never call something over-engineered without
  showing the smaller shape.
