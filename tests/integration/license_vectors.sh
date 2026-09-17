#!/usr/bin/env bash
# The license-class fixture vectors — the set every app gate TDDs against and
# the red team receives (public halves only). Contract: docs/
# MECHA_LICENSE_CONTRACT_V1.md sections 4/6; expected policy decisions live in
# examples/license_vectors/manifest.json (forward-looking spec for
# mecha_policy — this script asserts only what sigil itself decides: the
# CRYPTO layer, at ERROR CLASS granularity).
#
# Why cross-role rejections assert the SIGNATURE class: the beta/paid/demo
# key split is the boundary that caps a leaked key's blast radius. If two
# roles ever shared a key, rejection would shift from signature to policy
# and a mere "rejected" assertion would stay green through the collapse.
#
# The test_beta/test_paid keypairs are TEST-ONLY (passphrases public, in
# the generator, deliberately). Per Mecha conventions: `set -u` only.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SIGIL="${SIGIL_BIN:-$REPO_ROOT/zig-out/bin/sigil}"
LV="$REPO_ROOT/examples/license_vectors"
BETA_PUB="$LV/test_beta.key.pub"
PAID_PUB="$LV/test_paid.key.pub"
DEMO_PUB="$REPO_ROOT/examples/demo/demo.key.pub"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() {
	FAIL=$((FAIL + 1))
	printf '  FAIL %s\n' "$1" >&2
	[[ $# -gt 1 ]] && printf '       %s\n' "$2" >&2
	return 0
}

if [[ ! -x "$SIGIL" ]]; then
	echo "FATAL: sigil binary not found at $SIGIL" >&2
	exit 1
fi
for f in "$BETA_PUB" "$PAID_PUB" "$LV/manifest.json"; do
	if [[ ! -f "$f" ]]; then
		echo "FATAL: fixture missing: $f (run examples/license_vectors/generate)" >&2
		exit 1
	fi
done

# Envelopes signed by the beta role vs signed by the paid role.
BETA_SIGNED="beta_valid beta_expired beta_month_end beta_leap wrong_product wrong_class_for_key beta_missing_expiry malformed_expiry_empty"
PAID_SIGNED="paid_valid"

# verify_ok <name> <pubkey>: envelope verifies AND payload round-trips
# byte-identically (compared via files — command substitution strips the
# trailing newline, which is part of the signed bytes).
verify_ok() {
	local name="$1" pub="$2"
	local got rc
	got="$(mktemp "${TMPDIR:-/tmp}/sigil-lv-XXXXXX")"
	"$SIGIL" verify "$LV/$name.sigil" --pubkey "$pub" > "$got" 2>/dev/null
	rc=$?
	if [[ $rc -eq 0 ]] && cmp -s "$got" "$LV/$name.payload.json"; then
		pass "$name verifies under its own role and yields the exact payload"
	else
		fail "$name verifies under its own role and yields the exact payload" "rc=$rc"
	fi
	rm -f "$got"
}

# reject_sig <name> <pubkey> <desc>: exit 1 AND the SIGNATURE error class.
reject_sig() {
	local name="$1" pub="$2" desc="$3"
	local err rc
	err=$("$SIGIL" verify "$LV/$name.sigil" --pubkey "$pub" 2>&1 >/dev/null)
	rc=$?
	if [[ $rc -ne 1 ]]; then
		fail "$desc" "expected exit 1, got $rc: ${err:0:120}"
		return
	fi
	if ! grep -q "signature does not verify" <<<"$err"; then
		fail "$desc" "rejected, but not as a signature failure: ${err:0:120}"
		return
	fi
	pass "$desc"
}

echo "license-class vectors — binary: $SIGIL"

# Sensitivity: every fixture verifies under the role that signed it.
for n in $BETA_SIGNED; do verify_ok "$n" "$BETA_PUB"; done
for n in $PAID_SIGNED; do verify_ok "$n" "$PAID_PUB"; done

# Key separation, both directions, plus demo-trust exclusion. Note the
# wrong_class_for_key fixture VERIFIES under the beta key (above) — its
# rejection is mecha_policy's job (class_key_mismatch), recorded in the
# manifest, NOT a crypto failure. That asymmetry is the design.
reject_sig beta_valid "$PAID_PUB" "beta-signed grant offered to the paid role fails at SIGNATURE"
reject_sig paid_valid "$BETA_PUB" "paid-signed grant offered to the beta role fails at SIGNATURE"
reject_sig beta_valid "$DEMO_PUB" "beta-signed grant offered to demo trust fails at SIGNATURE"

err=$("$SIGIL" verify "$REPO_ROOT/examples/demo/license.sigil" --pubkey "$BETA_PUB" 2>&1 >/dev/null)
rc=$?
if [[ $rc -eq 1 ]] && grep -q "signature does not verify" <<<"$err"; then
	pass "demo-signed license offered to test-beta trust fails at SIGNATURE"
else
	fail "demo-signed license offered to test-beta trust fails at SIGNATURE" "rc=$rc ${err:0:120}"
fi

# Manifest consistency, both directions: every referenced file exists, and
# every fixture envelope is referenced. Mechanical, not hand-picked.
manifest_ok=1
while IFS= read -r ref; do
	if [[ ! -f "$LV/$ref" ]]; then
		fail "manifest references existing file: $ref"
		manifest_ok=0
	fi
done < <(grep -o '"[a-z_]*\.\(sigil\|payload\.json\)"' "$LV/manifest.json" | tr -d '"' | sort -u)
[[ $manifest_ok -eq 1 ]] && pass "every file the manifest references exists"

sweep_ok=1
for f in "$LV"/*.sigil; do
	base="$(basename "$f")"
	if ! grep -q "\"$base\"" "$LV/manifest.json"; then
		fail "fixture $base is listed in the manifest"
		sweep_ok=0
	fi
done
[[ $sweep_ok -eq 1 ]] && pass "every fixture envelope appears in the manifest"

# Vacuity guards: fixtures pairwise distinct; expiry-bearing payloads
# actually carry expiry; the missing/empty-expiry payloads actually lack it.
prev=""
for f in "$LV"/*.sigil; do
	if [[ -n "$prev" ]] && cmp -s "$prev" "$f"; then
		fail "fixtures $(basename "$prev") and $(basename "$f") are distinct" "identical bytes"
	fi
	prev="$f"
done
pass "adjacent fixture-distinctness sweep completed"

for n in beta_valid beta_expired beta_month_end beta_leap; do
	if grep -q '"expiry":"[0-9]' "$LV/$n.payload.json"; then
		pass "$n payload carries a dated expiry"
	else
		fail "$n payload carries a dated expiry"
	fi
done
if grep -q '"expiry"' "$LV/beta_missing_expiry.payload.json"; then
	fail "beta_missing_expiry payload truly lacks expiry"
else
	pass "beta_missing_expiry payload truly lacks expiry"
fi
if grep -q '"expiry":""' "$LV/malformed_expiry_empty.payload.json"; then
	pass "malformed_expiry_empty payload carries the empty-string expiry"
else
	fail "malformed_expiry_empty payload carries the empty-string expiry"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
exit "$FAIL"
