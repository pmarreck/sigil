#!/usr/bin/env bash
# Cross-implementation round trips and transcripts through the CLI.
#
# SIGIL_BIN is this frontend and library pair; SIGIL_PEER_BINS lists the
# others, colon-separated. For every peer:
#
# - What this binary makes, the peer reads identically, and both make the
#   same bytes from the same key and inputs (keys, envelopes, PEM, paper).
# - A table of invocations, successes and refusals alike, gives byte-identical
#   stdout, stderr and exit codes in both. This is what holds the Rust CLI to
#   the C CLI's messages, not just to its exit codes.
#
# ./test runs this once per pair with the other pairs as peers, so every
# direction runs. A missing peer fails; it never skips. Keys are TEST-ONLY
# and live in disposable scratch. NOT `set -e`.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SIGIL="${SIGIL_BIN:-$ROOT/zig-out/bin/sigil}"
PEERS="${SIGIL_PEER_BINS:-$ROOT/.nix-out/c-on-rust/bin/sigil}"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ $# -gt 1 ]] && printf '       %s\n' "$2"; return 0; }
finish() { printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; exit "$FAIL"; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sigil-cross-XXXXXX")" || exit 1
trap 'rm -rf -- "$WORK"' EXIT

IFS=: read -r -a peers <<<"$PEERS"
# The transcripts run inside scratch directories, so every binary is named by
# an absolute path.
absolute() { if [[ "$1" == /* ]]; then printf '%s' "$1"; else printf '%s/%s' "$PWD" "$1"; fi; }
SIGIL=$(absolute "$SIGIL")
for i in "${!peers[@]}"; do peers[i]=$(absolute "${peers[i]}"); done
if [[ ! -x "$SIGIL" || ${#peers[@]} -eq 0 ]]; then
	fail "this binary and at least one peer exist" "SIGIL_BIN=$SIGIL SIGIL_PEER_BINS=$PEERS"
	finish
fi
echo "cross-implementation: $SIGIL against ${#peers[@]} peer(s)"

printf '%s' 'cross-impl-test-not-for-production' >"$WORK/pw"
printf '%s' 'not-the-passphrase' >"$WORK/wrong"
: >"$WORK/empty"
printf '%s' '{"customer":"cross implementation","v":"1"}' >"$WORK/payload.json"
if "$SIGIL" keygen --out "$WORK/k.key" --hot-bundle-out "$WORK/k.hot" --passphrase-file "$WORK/pw" -q; then
	pass "this binary generates a key and its recovery bundle"
else
	fail "this binary generates a key and its recovery bundle"
	finish
fi

# ── Same bytes, read across the pair ────────────────────────────────────────
round_trip() {
	local peer="$1" who bin step this_rc peer_rc expected envelope case this_pem peer_pem
	for who in this peer; do
		if [[ "$who" == this ]]; then bin="$SIGIL"; else bin="$peer"; fi
		"$bin" pubkey --key "$WORK/k.key" --passphrase-file "$WORK/pw" --out "$WORK/$who.pub" -q
		echo "$?" >"$WORK/$who.pubkey-rc"
		"$bin" sign "$WORK/payload.json" --key "$WORK/k.key" --passphrase-file "$WORK/pw" --out "$WORK/$who.sigil" -q
		echo "$?" >"$WORK/$who.sign-rc"
		"$bin" pubkey --key "$WORK/k.key" --passphrase-file "$WORK/wrong" -q >/dev/null 2>&1
		echo "$?" >"$WORK/$who.wrong-rc"
		"$bin" paper --key "$WORK/k.key" --hot-bundle "$WORK/k.hot" --pubkey "$ROOT/examples/license_vectors/test_beta.key.pub" \
			--label "cross implementation (TEST)" --date 2026-11-10 --out "$WORK/$who.pdf" --force -q
		echo "$?" >"$WORK/$who.paper-rc"
	done
	for step in pubkey sign wrong paper; do
		this_rc=$(<"$WORK/this.$step-rc")
		peer_rc=$(<"$WORK/peer.$step-rc")
		expected=0
		[[ "$step" == wrong ]] && expected=1
		if [[ "$this_rc" != "$peer_rc" || "$this_rc" != "$expected" ]]; then
			fail "$step exits $expected in both" "this=$this_rc peer=$peer_rc"
			return
		fi
	done
	for artifact in pub sigil pdf; do
		if [[ ! -s "$WORK/this.$artifact" ]] || ! cmp -s "$WORK/this.$artifact" "$WORK/peer.$artifact"; then
			fail "both make the same .$artifact from this binary's key"
			return
		fi
	done
	# The restored PEM is a private key: keep it in memory, never in a file.
	this_pem=$("$SIGIL" hot-bundle open "$WORK/k.hot" --passphrase-file "$WORK/pw" 2>/dev/null)
	this_rc=$?
	peer_pem=$("$peer" hot-bundle open "$WORK/k.hot" --passphrase-file "$WORK/pw" 2>/dev/null)
	peer_rc=$?
	if [[ $this_rc -ne 0 || $peer_rc -ne 0 || "$this_pem" != "-----BEGIN PRIVATE KEY-----"* || "$this_pem" != "$peer_pem" ]]; then
		fail "the peer restores the same PKCS#8 key from this binary's bundle" "this=$this_rc peer=$peer_rc"
		return
	fi
	sed 's/implementation/implementatioN/' "$WORK/this.sigil" >"$WORK/tampered.sigil"
	for case in this tampered; do
		envelope="$WORK/$case.sigil"
		"$peer" verify "$envelope" --pubkey "$WORK/this.pub" -q >"$WORK/peer-$case.out" 2>/dev/null
		peer_rc=$?
		"$SIGIL" verify "$envelope" --pubkey "$WORK/this.pub" -q >"$WORK/this-$case.out" 2>/dev/null
		this_rc=$?
		expected=0
		[[ "$case" == tampered ]] && expected=1
		if [[ $peer_rc -ne $expected || $this_rc -ne $expected ]]; then
			fail "the $case envelope verifies with exit $expected in both" "this=$this_rc peer=$peer_rc"
			return
		fi
	done
	if ! cmp -s "$WORK/peer-this.out" "$WORK/payload.json"; then
		fail "the peer verifies this binary's envelope to the exact payload"
		return
	fi
	pass "key, public key, envelope, PEM and paper agree across the pair; each verifies the other"
}

# ── Same transcript: stdout, stderr and exit code ───────────────────────────
# Each binary runs in its own directory holding the same fixtures under the
# same relative names, so paths in messages match.
prepare() {
	local dir="$1"
	mkdir -p "$dir" || return 1
	cp "$WORK/k.key" "$WORK/k.hot" "$WORK/this.pub" "$WORK/this.sigil" "$WORK/tampered.sigil" \
		"$WORK/payload.json" "$WORK/pw" "$WORK/wrong" "$WORK/empty" "$dir/" || return 1
	cp "$WORK/k.key" "$dir/existing.key" || return 1
	printf 'not an envelope' >"$dir/garbage.txt"
	printf 'not a key' >"$dir/not-a-key.txt"
	printf 'one\ntwo\n' >"$dir/mismatch.in"
	printf '%s\n%s\n' 'prompted-test-pass' 'prompted-test-pass' >"$dir/prompted.in"
}

# Invocations, one per line: STDIN-FILE then the arguments. Fields are
# separated by spaces; '%' stands for a space inside an argument.
INVOCATIONS="/dev/null
/dev/null --help
/dev/null --about
/dev/null --version
/dev/null bogus
/dev/null --bogus
/dev/null verify
/dev/null verify this.sigil
/dev/null verify missing.sigil --pubkey this.pub
/dev/null verify this.sigil --pubkey not-a-key.txt
/dev/null verify this.sigil --pubkey this.pub
/dev/null verify this.sigil --pubkey this.pub --json
/dev/null verify this.sigil --pubkey this.pub --simple
/dev/null verify this.sigil --pubkey this.pub --out payload.out
/dev/null verify tampered.sigil --pubkey this.pub
/dev/null verify tampered.sigil --pubkey this.pub --json
/dev/null verify tampered.sigil --pubkey this.pub --simple
/dev/null verify garbage.txt --pubkey this.pub
/dev/null verify garbage.txt --pubkey this.pub --json
/dev/null verify this.sigil --pubkey
/dev/null verify this.sigil extra.sigil --pubkey this.pub
/dev/null verify -- --pubkey --pubkey this.pub
/dev/null verify /help
/dev/null sign payload.json
/dev/null sign payload.json --key k.key --passphrase-file pw
/dev/null sign payload.json --key k.key --passphrase-file pw --out signed.sigil
/dev/null sign payload.json --key k.key --passphrase-file wrong
/dev/null sign - --key k.key --passphrase-file -
/dev/null sign payload.json --key k.hot --passphrase-file pw
/dev/null sign payload.json --key k.key
/dev/null pubkey
/dev/null pubkey --pubkey this.pub
/dev/null pubkey --pubkey this.pub --format hex
/dev/null pubkey --pubkey this.pub --format c
/dev/null pubkey --pubkey this.pub --format zig
/dev/null pubkey --pubkey this.pub --format raw
/dev/null pubkey --pubkey this.pub --format bogus
/dev/null pubkey --key k.key --passphrase-file pw --format hex
/dev/null pubkey --key k.key --passphrase-file wrong
/dev/null pubkey --pubkey not-a-key.txt
/dev/null hot-bundle
/dev/null hot-bundle bogus
/dev/null hot-bundle --help
/dev/null hot-bundle open
/dev/null hot-bundle open k.key --passphrase-file pw
/dev/null hot-bundle open k.hot --passphrase-file wrong
/dev/null hot-bundle open k.hot --passphrase-file pw --out pem.txt
/dev/null hot-bundle open - --passphrase-file -
/dev/null paper
/dev/null paper --key k.key
/dev/null paper --key k.key --label role
/dev/null paper --key k.key --label role --out page.pdf --date 2026-13
/dev/null paper --key k.key --hot-bundle k.hot --label role%one --out page.pdf --date 2026-11-10
/dev/null paper --key k.key --label role --out page.pdf --date 2026-11-10
/dev/null paper --key k.key --pubkey not-a-key.txt --label role --out other.pdf --date 2026-11-10
/dev/null keygen
/dev/null keygen --out existing.key --passphrase-file pw
/dev/null keygen --out new.key --passphrase-file empty
/dev/null keygen --out new.key --passphrase-file pw
/dev/null keygen --out new.key --passphrase-file pw
mismatch.in keygen --out typed.key
prompted.in keygen --out prompted.key
/dev/null keygen --out prompted2.key"

# run_invocation BIN DIR N: run line N of the table in DIR, recording
# stdout, stderr and the exit code under DIR/.t/N.
run_invocation() {
	local bin="$1" dir="$2" n="$3" line input arg
	local -a fields=() args=()
	line=$(sed -n "${n}p" <<<"$INVOCATIONS")
	read -r -a fields <<<"$line"
	input="${fields[0]}"
	for arg in "${fields[@]:1}"; do args+=("${arg//%/ }"); done
	mkdir -p "$dir/.t"
	(cd "$dir" && NO_COLOR=1 "$bin" "${args[@]}" <"$input" >".t/$n.out" 2>".t/$n.err"; echo "$?" >".t/$n.rc")
}

transcripts() {
	local peer="$1" tag="$2" count n differ=""
	count=$(wc -l <<<"$INVOCATIONS")
	prepare "$WORK/t-this-$tag" || { fail "prepare transcript fixtures"; return; }
	prepare "$WORK/t-peer-$tag" || { fail "prepare transcript fixtures"; return; }
	for ((n = 1; n <= count; n++)); do
		run_invocation "$SIGIL" "$WORK/t-this-$tag" "$n"
		run_invocation "$peer" "$WORK/t-peer-$tag" "$n"
		for part in rc out err; do
			if ! cmp -s "$WORK/t-this-$tag/.t/$n.$part" "$WORK/t-peer-$tag/.t/$n.$part"; then
				differ="$differ
  line $n ($part): $(sed -n "${n}p" <<<"$INVOCATIONS")"
			fi
		done
	done
	# The files each wrote must match too, except fresh keys, which differ
	# by design and are compared by round trip above.
	for f in payload.out signed.sigil page.pdf; do
		if ! cmp -s "$WORK/t-this-$tag/$f" "$WORK/t-peer-$tag/$f"; then
			differ="$differ
  written file $f"
		fi
	done
	if [[ -z "$differ" ]]; then
		pass "all $count invocations give byte-identical stdout, stderr and exit codes"
	else
		fail "all $count invocations give byte-identical stdout, stderr and exit codes" "$differ"
	fi
}

tag=0
for peer in "${peers[@]}"; do
	tag=$((tag + 1))
	echo "peer $tag: $peer"
	if [[ ! -x "$peer" ]]; then
		fail "peer $tag exists" "$peer"
		continue
	fi
	if cmp -s "$SIGIL" "$peer"; then
		fail "peer $tag is a different build" "both are $SIGIL"
		continue
	fi
	round_trip "$peer"
	transcripts "$peer" "$tag"
done

finish
