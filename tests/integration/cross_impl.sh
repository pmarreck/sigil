#!/usr/bin/env bash
# Cross-implementation round trips through the CLI. What this binary
# (SIGIL_BIN) makes, the peer (SIGIL_PEER_BIN, another frontend and library
# pair) must read identically, and both must make the same bytes from the
# same key and inputs. ./test runs this once per pair with the other pair as
# the peer, so both directions are covered. A missing peer fails; it never
# skips. The key is TEST-ONLY and lives in disposable scratch. NOT `set -e`.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SIGIL="${SIGIL_BIN:-$ROOT/zig-out/bin/sigil}"
PEER="${SIGIL_PEER_BIN:-$ROOT/.nix-out/c-on-rust/bin/sigil}"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ $# -gt 1 ]] && printf '       %s\n' "$2"; return 0; }
finish() { printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; exit "$FAIL"; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sigil-cross-XXXXXX")" || exit 1
trap 'rm -rf -- "$WORK"' EXIT
echo "cross-implementation round trips: $SIGIL -> $PEER"

if [[ ! -x "$SIGIL" || ! -x "$PEER" ]]; then
	fail "both binaries exist" "SIGIL_BIN=$SIGIL SIGIL_PEER_BIN=$PEER"
	finish
fi
if cmp -s "$SIGIL" "$PEER"; then
	fail "the peer is a different build" "both are $SIGIL"
	finish
fi
pass "this binary and its peer are different builds"

printf '%s' 'cross-impl-test-not-for-production' >"$WORK/pw"
printf '%s' 'not-the-passphrase' >"$WORK/wrong"
printf '%s' '{"customer":"cross implementation","v":"1"}' >"$WORK/payload.json"

if "$SIGIL" keygen --out "$WORK/k.key" --hot-bundle-out "$WORK/k.hot" --passphrase-file "$WORK/pw" -q; then
	pass "this binary generates a key and its recovery bundle"
else
	fail "this binary generates a key and its recovery bundle"
	finish
fi

# Each step runs both binaries on the same input and compares the results.
for who in this peer; do
	if [[ "$who" == this ]]; then bin="$SIGIL"; else bin="$PEER"; fi
	"$bin" pubkey --key "$WORK/k.key" --passphrase-file "$WORK/pw" --out "$WORK/$who.pub" -q
	echo "$?" >"$WORK/$who.pubkey-rc"
	"$bin" sign "$WORK/payload.json" --key "$WORK/k.key" --passphrase-file "$WORK/pw" --out "$WORK/$who.sigil" -q
	echo "$?" >"$WORK/$who.sign-rc"
	"$bin" pubkey --key "$WORK/k.key" --passphrase-file "$WORK/wrong" -q >/dev/null 2>&1
	echo "$?" >"$WORK/$who.wrong-rc"
	"$bin" paper --key "$WORK/k.key" --hot-bundle "$WORK/k.hot" --pubkey "$ROOT/examples/license_vectors/test_beta.key.pub" \
		--label "cross implementation (TEST)" --date 2026-11-10 --out "$WORK/$who.pdf" -q
	echo "$?" >"$WORK/$who.paper-rc"
done
for step in pubkey sign wrong paper; do
	this_rc=$(<"$WORK/this.$step-rc")
	peer_rc=$(<"$WORK/peer.$step-rc")
	expected=0
	[[ "$step" == wrong ]] && expected=$this_rc
	if [[ "$this_rc" == "$peer_rc" && "$this_rc" == "$expected" ]]; then
		pass "$step exits $this_rc in both"
	else
		fail "$step exits the same way in both" "this=$this_rc peer=$peer_rc"
	fi
done
if [[ $(<"$WORK/this.wrong-rc") -ne 0 ]]; then
	pass "a wrong passphrase is refused by both"
else
	fail "a wrong passphrase is refused by both"
fi
if [[ -s "$WORK/this.pub" ]] && cmp -s "$WORK/this.pub" "$WORK/peer.pub"; then
	pass "the peer derives the same public key from this binary's keyfile"
else
	fail "the peer derives the same public key from this binary's keyfile"
fi
if [[ -s "$WORK/this.sigil" ]] && cmp -s "$WORK/this.sigil" "$WORK/peer.sigil"; then
	pass "both seal the payload into byte-identical envelopes"
else
	fail "both seal the payload into byte-identical envelopes"
fi
if [[ -s "$WORK/this.pdf" ]] && cmp -s "$WORK/this.pdf" "$WORK/peer.pdf"; then
	pass "both render byte-identical paper cold copies"
else
	fail "both render byte-identical paper cold copies"
fi

# The restored PEM is a private key: keep it in memory, never in a file.
this_pem=$("$SIGIL" hot-bundle open "$WORK/k.hot" --passphrase-file "$WORK/pw" 2>/dev/null)
this_rc=$?
peer_pem=$("$PEER" hot-bundle open "$WORK/k.hot" --passphrase-file "$WORK/pw" 2>/dev/null)
peer_rc=$?
if [[ $this_rc -eq 0 && $peer_rc -eq 0 && "$this_pem" == "-----BEGIN PRIVATE KEY-----"* && "$this_pem" == "$peer_pem" ]]; then
	pass "the peer restores the same PKCS#8 key from this binary's bundle"
else
	fail "the peer restores the same PKCS#8 key from this binary's bundle" "this=$this_rc peer=$peer_rc"
fi
unset this_pem peer_pem

# Verification across the pair, for the genuine envelope and a tampered one.
# Same exit code and byte-identical --json output from both.
sed 's/implementation/implementatioN/' "$WORK/this.sigil" >"$WORK/tampered.sigil"
if cmp -s "$WORK/this.sigil" "$WORK/tampered.sigil"; then
	fail "the tampered envelope differs from the original"
fi
for case in this tampered; do
	envelope="$WORK/$case.sigil"
	"$PEER" verify "$envelope" --pubkey "$WORK/this.pub" -q >"$WORK/peer-$case.out" 2>/dev/null
	peer_rc=$?
	"$SIGIL" verify "$envelope" --pubkey "$WORK/this.pub" -q >"$WORK/this-$case.out" 2>/dev/null
	this_rc=$?
	"$PEER" verify "$envelope" --pubkey "$WORK/this.pub" --json >"$WORK/peer-$case.json" 2>/dev/null
	"$SIGIL" verify "$envelope" --pubkey "$WORK/this.pub" --json >"$WORK/this-$case.json" 2>/dev/null
	if [[ "$case" == this ]]; then
		if [[ $peer_rc -eq 0 && $this_rc -eq 0 ]] && cmp -s "$WORK/peer-$case.out" "$WORK/payload.json"; then
			pass "the peer verifies this binary's envelope to the exact payload"
		else
			fail "the peer verifies this binary's envelope to the exact payload" "this=$this_rc peer=$peer_rc"
		fi
	elif [[ $peer_rc -eq 1 && $this_rc -eq 1 ]]; then
		pass "both refuse the tampered envelope as NOT AUTHENTIC (exit 1)"
	else
		fail "both refuse the tampered envelope as NOT AUTHENTIC (exit 1)" "this=$this_rc peer=$peer_rc"
	fi
	if [[ -s "$WORK/this-$case.json" ]] && cmp -s "$WORK/this-$case.json" "$WORK/peer-$case.json"; then
		pass "verify --json is byte-identical in both ($case envelope)"
	else
		fail "verify --json is byte-identical in both ($case envelope)"
	fi
done

finish
