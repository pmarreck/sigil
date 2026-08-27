#!/usr/bin/env bash
# The mecha-update/v1 signed vectors — the fixture set validate_gui's updater
# TDDs against (their docs/self-update-design.md, implementation-order item 2).
#
# What each case pins, and why the ERROR CLASS is asserted rather than mere
# rejection: the update/license purpose boundary is the KEY SPLIT — a genuine
# license envelope offered to the update verifier must fail at SIGNATURE. If
# the two purposes ever accidentally shared a key, that failure would shift
# from signature to schema (the envelope would verify and only the payload
# would look wrong), and a test asserting only "rejected" would stay green
# through the collapse of the boundary it exists to watch.
#
# The update_test keypair is TEST-ONLY (passphrase in this file, deliberately).
# Per Mecha conventions: `set -u` only.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SIGIL="${SIGIL_BIN:-$REPO_ROOT/zig-out/bin/sigil}"
UV="$REPO_ROOT/examples/update_vectors"
UPDATE_PUB="$UV/update_test.key.pub"

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

# expect <rc> <sig-class:yes|no> <description> <envelope> <pubkey>
# sig-class=yes additionally requires the rejection to be the SIGNATURE error,
# not an encoding or schema complaint — see the header comment for why.
expect() {
	local want_rc="$1" sig_class="$2" desc="$3" env="$4" pub="$5"
	local err rc
	err=$("$SIGIL" verify "$env" --pubkey "$pub" 2>&1 >/dev/null)
	rc=$?
	if [[ $rc -ne $want_rc ]]; then
		fail "$desc" "expected exit $want_rc, got $rc: ${err:0:120}"
		return
	fi
	if [[ "$sig_class" == "yes" ]] && ! grep -q "signature does not verify" <<<"$err"; then
		fail "$desc" "rejected, but not as a signature failure: ${err:0:120}"
		return
	fi
	pass "$desc"
}

echo "mecha-update/v1 vectors — binary: $SIGIL"

# Sensitivity: the valid manifest verifies, and its payload round-trips
# byte-identically to the committed JSON (the updater hashes exact verified
# bytes for its equivocation check, so byte identity is load-bearing).
#
# Compared via files, NOT $(...): command substitution strips trailing
# newlines, and the payload's trailing newline is part of the signed bytes —
# the first run of this test failed on exactly that.
got_file="$(mktemp "${TMPDIR:-/tmp}/sigil-uv-payload-XXXXXX")"
trap 'rm -f "$got_file"' EXIT
"$SIGIL" verify "$UV/manifest_valid.sigil" --pubkey "$UPDATE_PUB" > "$got_file" 2>/dev/null
rc=$?
if [[ $rc -eq 0 ]] && cmp -s "$got_file" "$UV/manifest_valid.json"; then
	pass "the valid manifest verifies and yields the exact committed payload"
else
	fail "the valid manifest verifies and yields the exact committed payload" "rc=$rc"
fi

# Specificity, each with the signature-class requirement.
expect 1 yes "a tampered payload is rejected as a signature failure" \
	"$UV/manifest_tampered_payload.sigil" "$UPDATE_PUB"
expect 1 yes "a tampered signature is rejected as a signature failure" \
	"$UV/manifest_tampered_sig.sigil" "$UPDATE_PUB"
expect 1 yes "a manifest signed by the license key is rejected (wrong key)" \
	"$UV/manifest_wrong_key.sigil" "$UPDATE_PUB"
expect 1 yes "a genuine LICENSE offered as update metadata fails at SIGNATURE (purpose boundary)" \
	"$REPO_ROOT/examples/demo/license.sigil" "$UPDATE_PUB"

# And the mirror: update metadata offered to the LICENSE verifier.
expect 1 yes "the update manifest offered to the license key also fails at SIGNATURE" \
	"$UV/manifest_valid.sigil" "$REPO_ROOT/examples/demo/demo.key.pub"

# Vacuity guards: every tampered fixture must actually differ from the valid
# one, or the rejections above prove nothing.
for t in manifest_tampered_payload manifest_tampered_sig manifest_wrong_key; do
	if cmp -s "$UV/manifest_valid.sigil" "$UV/$t.sigil"; then
		fail "fixture $t differs from the valid manifest" "identical bytes — the control is vacuous"
	else
		pass "fixture $t differs from the valid manifest"
	fi
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
exit "$FAIL"
