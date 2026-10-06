#!/bin/bash
# Refuses newly added real-time waits in staged Tests/*.swift files.
# Run by .githooks/pre-commit. `--self-test` checks the rules in a throwaway repo.

RE='Task\.sleep|Thread\.sleep|usleep\(|(^|[^A-Za-z0-9_.])sleep\(|asyncAfter|SuiteWait\.settle\(|\.wait\(timeout:|([Tt]imeout|[Dd]elay|[Dd]eadline|[Ii]nterval|[Gg]race|[Ww]indow|[Ss]econds)(Override)?[[:space:]]*(:[[:space:]]*[A-Za-z]+[[:space:]]*)?[=:][[:space:]]*0*\.0*[1-9]'

if [ "$1" = "--self-test" ]; then
    self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
    tmp=$(mktemp -d) || exit 1
    trap 'rm -rf "$tmp"' EXIT
    cd "$tmp" || exit 1
    git init -q . && git config user.email t@t && git config user.name t
    mkdir -p Tests Sources
    fail=0
    # check <block|pass> <path> <line>
    check() {
        printf '%s\n' "$3" > "$2"
        git add -f "$2"
        bash "$self" >/dev/null 2>&1; rc=$?
        git reset -q
        if { [ "$1" = block ] && [ $rc -ne 1 ]; } || { [ "$1" = pass ] && [ $rc -ne 0 ]; }; then
            echo "FAIL (expected $1, rc=$rc): $3"; fail=1
        fi
    }
    while IFS= read -r l; do check block Tests/T.swift "$l"; done <<'LINES'
try? await Task.sleep(nanoseconds: 1)
Thread.sleep(forTimeInterval: 1)
usleep(1)
q.asyncAfter(deadline: .now() + 1) {}
SuiteWait.settle(0.3)
sem.wait(timeout: .now() + 5)
stallSeconds = 0.05
castAbsenceGrace: TimeInterval = 0.05
test_handshakeTimeoutOverride = 0.3
makeBackend(castAbsenceGrace: 0.3)
Task.sleep(nanoseconds: 1) // real-time-ok:
LINES
    while IFS= read -r l; do check pass Tests/T.swift "$l"; done <<'LINES'
nowSeconds = 0.0
lightWindowAlpha: CGFloat = 0.9
makeBackend(castAbsenceGrace: 1)
Task.sleep(nanoseconds: 1) // real-time-ok: hang ceiling
// comment naming Task.sleep
LINES
    check pass Sources/S.swift 'Task.sleep(nanoseconds: 1)'
    [ $fail -eq 0 ] && echo "all check-test-waits tests passed"
    exit $fail
fi

# A conflict-resolution merge commit carries other people's lines.
[ -f "$(git rev-parse --git-dir 2>/dev/null)/MERGE_HEAD" ] && exit 0

hits=""
for f in $(git diff --cached --no-renames --name-only --diff-filter=AM -- 'Tests/' | grep -E '\.swift$'); do
    out=$(git diff --cached --no-renames -U0 -- "$f" | awk '
        /^@@/ { s = $3; sub(/^\+/, "", s); split(s, p, ","); n = p[1] + 0; next }
        /^\+\+\+/ { next }
        /^\+/ { print n ":" substr($0, 2); n++ }' \
        | grep -vE '^[0-9]+:[[:space:]]*//' \
        | grep -E "$RE" \
        | grep -vE 'real-time-ok:[[:space:]]*[^[:space:]]' | cut -d: -f1)
    for ln in $out; do hits="$hits    $f:$ln"$'\n'; done
done

if [ -n "$hits" ]; then
    echo "" >&2
    echo "  REFUSED: real-time wait added in a test file:" >&2
    printf '%s' "$hits" >&2
    echo "  A wait on the wall clock flakes on a slow CI runner. Inject the clock or" >&2
    echo "  scheduler and drive it from the test instead. A trailing" >&2
    echo "  '// real-time-ok: <reason>' exempts a line (a hang ceiling counts as a reason)." >&2
    echo "  ('git commit --no-verify' for a real emergency.)" >&2
    exit 1
fi
exit 0
