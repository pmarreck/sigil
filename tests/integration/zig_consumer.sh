#!/usr/bin/env bash
# Downstream Zig consumer contract: `b.dependency("sigil").artifact("sigil")`
# resolves to the static VERIFIER library on every shipped target (Linux,
# macOS, Windows), a product links the C ABI through it, and the linked
# product carries no signing code.
#
# tests/zig_consumer depends on this checkout by path. The flake package
# zig-consumer-results compiles it (every target in tests/zig_consumer/targets,
# then the native conformance program) and records each step's exit status
# and log as data, so the compiles rerun only when the Zig package or the
# consumer changes. This suite judges those records and runs the program.
# There is no direct-build fallback: missing results fail. NOT `set -e`.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
R="${SIGIL_ZIG_CONSUMER_OUT:-$ROOT/.nix-out/zig-consumer}"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ $# -gt 1 ]] && printf '%s\n' "$2" | tail -5 | sed 's/^/       /'; return 0; }
echo "downstream Zig consumer — $R"

if [[ ! -d "$R/steps" ]]; then
	fail "zig consumer results exist (./build makes .nix-out/zig-consumer)" "$R"
	echo ""; echo "$PASS passed, $FAIL failed"; exit 1
fi

# step NAME: the recorded exit status is present and zero.
step_ok() { [[ -f "$R/steps/$1.rc" && "$(cat "$R/steps/$1.rc")" == 0 ]]; }
step_log() { cat "$R/steps/$1.log" 2>/dev/null || echo "no record for step $1"; }

targets=$(grep -v '^[[:space:]]*$' "$ROOT/tests/zig_consumer/targets" 2>/dev/null)
[[ $(wc -l <<<"$targets") -ge 5 ]] && pass "the consumer is compiled for $(wc -l <<<"$targets") targets" \
	|| fail "tests/zig_consumer/targets lists the shipped targets" "$targets"
for t in $targets; do
	step_ok "resolve-$t" && pass "artifact(\"sigil\") is the static verifier for $t" \
		|| fail "artifact(\"sigil\") resolves for $t" "$(step_log "resolve-$t")"
done

D="$ROOT/examples/demo"
exe="$R/bin/verify_conformance"
if step_ok install && [[ -x "$exe" ]]; then
	out=$("$exe" "$D/payload.bin" "$D/sig.bin" "$D/pubkey.bin" 2>&1); rc=$?
else
	out=$(step_log install); rc=1
fi
if [[ $rc -eq 0 ]] && grep -q '^  ok' <<<"$out" && ! grep -q 'FAIL' <<<"$out"; then
	pass "C conformance program linked through artifact(\"sigil\") passes ($(grep -c '^  ok' <<<"$out") checks)"
else fail "C conformance program linked through artifact(\"sigil\")" "$out"; fi

# Forbidden: every function the signing header exports that the verifier
# header does not. Positive half: nm must see the verifier's own sigil_verify.
forbidden=$(comm -23 <(grep -oE '\bsigil_[a-z_]+ *\(' "$ROOT/include/sigil_sign.h" | tr -d ' (' | sort -u) \
	<(grep -oE '\bsigil_[a-z_]+ *\(' "$ROOT/include/sigil.h" | tr -d ' (' | sort -u))
if [[ -f "$exe" && -n "$forbidden" ]]; then
	defined=$(nm --defined-only "$exe" 2>/dev/null | awk '{print $NF}')
	grep -qx 'sigil_verify' <<<"$defined" && pass "nm sees sigil_verify in the linked consumer" || fail "nm sees sigil_verify in the linked consumer"
	leaked=$(grep -xF -f <(printf '%s\n' "$forbidden") <<<"$defined")
	[[ -z "$leaked" ]] && pass "the linked consumer defines none of $(wc -l <<<"$forbidden") signing exports" || fail "the linked consumer defines no signing exports" "$leaked"
else fail "consumer executable installed and signing export list derived" "$exe"; fi

echo ""
echo "$PASS passed, $FAIL failed"
exit $(( FAIL > 0 ? 1 : 0 ))
