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
# shellcheck disable=SC2312  # diagnostic-only: the verdict is already counted
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ $# -gt 1 ]] && printf '%s\n' "$2" | tail -5 | sed 's/^/       /'; return 0; }
echo "downstream Zig consumer — $R"

if [[ ! -d "$R/steps" ]]; then
	fail "zig consumer results exist (./build makes .nix-out/zig-consumer)" "$R"
	echo ""; echo "$PASS passed, $FAIL failed"; exit 1
fi

# step NAME: the recorded exit status is present and zero.
step_ok() { local rc; [[ -f "$R/steps/$1.rc" ]] && rc=$(<"$R/steps/$1.rc") && [[ $rc == 0 ]]; }
step_log() { cat "$R/steps/$1.log" 2>/dev/null || echo "no record for step $1"; }

targets=$(grep -v '^[[:space:]]*$' "$ROOT/tests/zig_consumer/targets" 2>/dev/null)
ntargets=$(wc -l <<<"$targets")
[[ $ntargets -ge 5 ]] && pass "the consumer is compiled for $ntargets targets" \
	|| fail "tests/zig_consumer/targets lists the shipped targets" "$targets"
for t in $targets; do
	if step_ok "resolve-$t"; then
		pass "artifact(\"sigil\") is the static verifier for $t"
	else
		log=$(step_log "resolve-$t")
		fail "artifact(\"sigil\") resolves for $t" "$log"
	fi
done

D="$ROOT/examples/demo"
exe="$R/bin/verify_conformance"
if step_ok install && [[ -x "$exe" ]]; then
	out=$("$exe" "$D/payload.bin" "$D/sig.bin" "$D/pubkey.bin" 2>&1); rc=$?
else
	out=$(step_log install); rc=1
fi
if [[ $rc -eq 0 ]] && grep -q '^  ok' <<<"$out" && ! grep -q 'FAIL' <<<"$out"; then
	nok=$(grep -c '^  ok' <<<"$out")
	pass "C conformance program linked through artifact(\"sigil\") passes ($nok checks)"
else fail "C conformance program linked through artifact(\"sigil\")" "$out"; fi

# Forbidden: every function the signing header declares that the verifier
# header does not, as scripts/c-header-functions reads them (the same reader
# the export inventories use). Positive half: nm must see the verifier's own
# sigil_verify.
forbidden=""
if sign_fns=$(bash "$ROOT/scripts/c-header-functions" "$ROOT/include/sigil_sign.h") \
	&& verify_fns=$(bash "$ROOT/scripts/c-header-functions" "$ROOT/include/sigil.h"); then
	sign_fns=$(sort -u <<<"$sign_fns")
	verify_fns=$(sort -u <<<"$verify_fns")
	forbidden=$(comm -23 <(printf '%s\n' "$sign_fns") <(printf '%s\n' "$verify_fns"))
fi
if [[ -f "$exe" && -n "$forbidden" ]] && nm_out=$(nm --defined-only "$exe" 2>&1); then
	defined=$(awk '{print $NF}' <<<"$nm_out")
	grep -qx 'sigil_verify' <<<"$defined" && pass "nm sees sigil_verify in the linked consumer" || fail "nm sees sigil_verify in the linked consumer"
	leaked=$(grep -xF -f <(printf '%s\n' "$forbidden") <<<"$defined")
	nforbidden=$(wc -l <<<"$forbidden")
	[[ -z "$leaked" ]] && pass "the linked consumer defines none of $nforbidden signing exports" || fail "the linked consumer defines no signing exports" "$leaked"
else fail "consumer executable installed, read by nm, and signing export list derived" "$exe"; fi

echo ""
echo "$PASS passed, $FAIL failed"
exit $(( FAIL > 0 ? 1 : 0 ))
