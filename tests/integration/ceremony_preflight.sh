#!/usr/bin/env bash
# The key-ceremony preflight (custody contract v1.3 section 3) must be a
# checker with teeth: its rehearsal runs the real tooling on TEST keys only,
# proves the cold artifacts restore the right identity through independent
# oracles, and leaves no key material behind. NOT `set -e`: failures are
# the thing under test.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PRE="$ROOT/ceremony-preflight"
SIGIL="${SIGIL_BIN:-$ROOT/zig-out/bin/sigil}"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ $# -gt 1 ]] && printf '       %s\n' "$2"; return 0; }
WORK="${TMPDIR:-/tmp}/sigil-preflight-test-$$"
mkdir -p "$WORK" || exit 1
trap 'rm -rf "$WORK"' EXIT

echo "ceremony preflight tests — $PRE"
if [[ ! -x "$PRE" ]]; then fail "ceremony-preflight exists and is executable"; echo "$PASS passed, $FAIL failed"; exit 1; fi
pass "ceremony-preflight exists and is executable"

"$PRE" --help > "$WORK/help.txt" 2>&1; rc=$?
[[ $rc -eq 0 ]] && pass "--help exits 0" || fail "--help exits 0" "rc=$rc"
grep -q -- '--rehearse' "$WORK/help.txt" && pass "--help documents --rehearse" || fail "--help documents --rehearse"

# Checks-only mode never fails on host residuals it cannot verify; it reports them.
"$PRE" --sigil "$SIGIL" --work "$WORK/checks" > "$WORK/checks.txt" 2>&1; rc=$?
grep -q -i 'residual' "$WORK/checks.txt" && pass "checks mode names the residual assumptions it cannot verify" || fail "checks mode names the residual assumptions it cannot verify"
grep -q -i 'swap' "$WORK/checks.txt" && pass "checks mode reports swap state" || fail "checks mode reports swap state"
grep -q -i 'core dump' "$WORK/checks.txt" && pass "checks mode reports the core-dump limit" || fail "checks mode reports the core-dump limit"
grep -q -i 'tmpdir' "$WORK/checks.txt" && pass "checks mode reports TMPDIR's filesystem" || fail "checks mode reports TMPDIR's filesystem"
grep -q 'sigil ' "$WORK/checks.txt" && pass "checks mode reports the sigil build it will use" || fail "checks mode reports the sigil build it will use"

# Rehearsal: TEST keys only, oracles required, nothing left behind.
"$PRE" --sigil "$SIGIL" --work "$WORK/reh" --rehearse > "$WORK/reh.txt" 2>&1; rc=$?
if [[ $rc -eq 0 ]]; then pass "rehearsal exits 0 with every oracle on PATH"
# shellcheck disable=SC2312  # diagnostic-only substitution; verdict already set
else fail "rehearsal exits 0 with every oracle on PATH" "rc=$rc; $(tail -5 "$WORK/reh.txt" | tr '\n' '|')"; fi
grep -q 'REHEARSAL PASSED' "$WORK/reh.txt" && pass "rehearsal prints REHEARSAL PASSED" || fail "rehearsal prints REHEARSAL PASSED"
grep -q -i 'openssl' "$WORK/reh.txt" && pass "rehearsal cites the openssl identity oracle" || fail "rehearsal cites the openssl identity oracle"
grep -q -i 'zbar' "$WORK/reh.txt" && pass "rehearsal cites the zbar paper oracle" || fail "rehearsal cites the zbar paper oracle"
grep -q -i 'test-only\|TEST' "$WORK/reh.txt" && pass "rehearsal says it used test keys only" || fail "rehearsal says it used test keys only"
find "$WORK/reh" -name '*.key' -o -name '*.sealed' -o -name '*.pem' > "$WORK/left.txt" 2>/dev/null
left=$(wc -l < "$WORK/left.txt"); left=${left//[[:space:]]/}
[[ "$left" == "0" ]] && pass "rehearsal leaves no key material behind" || fail "rehearsal leaves no key material behind" "$left files remain"

# A missing oracle FAILS the rehearsal rather than skipping it.
mkdir -p "$WORK/nopath"; printf '#!/usr/bin/env bash\nexit 127\n' > "$WORK/nopath/zbarimg"; chmod +x "$WORK/nopath/zbarimg"
PATH="$WORK/nopath:$PATH" "$PRE" --sigil "$SIGIL" --work "$WORK/reh2" --rehearse > "$WORK/reh2.txt" 2>&1; rc=$?
[[ $rc -ne 0 ]] && pass "a broken zbar oracle fails the rehearsal" || fail "a broken zbar oracle fails the rehearsal"
grep -q 'REHEARSAL PASSED' "$WORK/reh2.txt" && fail "a failed rehearsal never prints REHEARSAL PASSED" || pass "a failed rehearsal never prints REHEARSAL PASSED"

# --strict promotes host residual warnings to failures only when they are real
# failures; a passphrase on the command line is always refused.
"$PRE" --sigil "$SIGIL" --work "$WORK/pw" --rehearse --passphrase secret > "$WORK/pw.txt" 2>&1; rc=$?
[[ $rc -ne 0 ]] && pass "a passphrase on the command line is refused" || fail "a passphrase on the command line is refused"

echo ""
echo "$PASS passed, $FAIL failed"
exit $(( FAIL > 0 ? 1 : 0 ))
