#!/usr/bin/env bash
# Cross-implementation round trips and transcripts through the CLI, over
# every frontend and library pair at once.
#
# SIGIL_PAIR_BINS lists one binary per pair, colon-separated; the first is
# the reference. ./test exports all four (C or Rust CLI on the Zig or Rust
# libraries). This suite covers every pair in one run, so it deliberately
# does not take the single-binary variable the per-pair passes use: ./test
# runs it once, not once per pair.
#
# - Round trips: each pair generates a key pair, and every other pair must
#   derive the same public key, seal the same envelope, restore the same
#   PKCS#8 key and verify the maker's envelope (and refuse it tampered).
#   That is all twelve maker and reader directions, since a key's bytes come
#   from its maker.
# - Transcripts: each pair runs a table of invocations, successes and
#   refusals alike, and must give the reference pair's stdout, stderr, exit
#   codes and written files byte for byte. Byte identity is transitive, so
#   comparing each with the reference covers every pair.
#
# Makers and transcript runs execute concurrently, one job per pair, each in
# its own directory. A missing pair fails; it never skips. Keys are TEST-ONLY
# and live in disposable scratch. NOT `set -e`.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEFAULT_PAIRS="$ROOT/zig-out/bin/sigil:$ROOT/.nix-out/c-on-rust/bin/sigil"
DEFAULT_PAIRS="$DEFAULT_PAIRS:$ROOT/.nix-out/rust-cli-on-zig/bin/sigil:$ROOT/.nix-out/rust-cli-on-rust/bin/sigil"
PAIRS="${SIGIL_PAIR_BINS:-$DEFAULT_PAIRS}"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ $# -gt 1 ]] && printf '       %s\n' "$2"; return 0; }
finish() { printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; exit "$FAIL"; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sigil-cross-XXXXXX")" || exit 1
trap 'rm -rf -- "$WORK"' EXIT

IFS=: read -r -a bins <<<"$PAIRS"
# The transcripts run inside scratch directories, so every binary is named by
# an absolute path.
absolute() { if [[ "$1" == /* ]]; then printf '%s' "$1"; else printf '%s/%s' "$PWD" "$1"; fi; }
for i in "${!bins[@]}"; do bins[i]=$(absolute "${bins[i]}"); done
echo "cross-implementation: ${#bins[@]} pairs, reference ${bins[0]}"
if [[ ${#bins[@]} -lt 2 ]]; then
	fail "at least two pairs to compare" "SIGIL_PAIR_BINS=$PAIRS"
	finish
fi
for i in "${!bins[@]}"; do
	if [[ ! -x "${bins[i]}" ]]; then
		fail "pair $i exists" "${bins[i]}"
		finish
	fi
	for ((j = 0; j < i; j++)); do
		if cmp -s "${bins[i]}" "${bins[j]}"; then
			fail "pairs $j and $i are different builds" "both are ${bins[i]}"
			finish
		fi
	done
done
pass "${#bins[@]} distinct pairs"

printf '%s' 'cross-impl-test-not-for-production' >"$WORK/pw"
printf '%s' 'not-the-passphrase' >"$WORK/wrong"
: >"$WORK/empty"
printf '%s' '{"customer":"cross implementation","v":"1"}' >"$WORK/payload.json"

# ── Round trips ─────────────────────────────────────────────────────────────
# make_and_read I: pair I generates a key pair and its outputs; every other
# pair reads them. Writes one verdict file per reader: "ok", or why not.
make_and_read() {
	local i="$1" maker="${bins[$1]}" dir="$WORK/made-$1" j reader why maker_pem reader_pem rc
	mkdir -p "$dir"
	if ! "$maker" keygen --out "$dir/k.key" --hot-bundle-out "$dir/k.hot" --passphrase-file "$WORK/pw" -q \
		|| ! "$maker" pubkey --key "$dir/k.key" --passphrase-file "$WORK/pw" --out "$dir/maker.pub" -q \
		|| ! "$maker" sign "$WORK/payload.json" --key "$dir/k.key" --passphrase-file "$WORK/pw" --out "$dir/maker.sigil" -q; then
		echo "the maker could not generate, derive and seal" >"$dir/maker-failed"
		return
	fi
	sed 's/implementation/implementatioN/' "$dir/maker.sigil" >"$dir/tampered.sigil"
	# The restored PEM is a private key: keep it in memory, never in a file.
	maker_pem=$("$maker" hot-bundle open "$dir/k.hot" --passphrase-file "$WORK/pw" 2>/dev/null)
	for j in "${!bins[@]}"; do
		[[ "$j" == "$i" ]] && continue
		reader="${bins[$j]}"
		why=""
		if ! { "$reader" pubkey --key "$dir/k.key" --passphrase-file "$WORK/pw" --out "$dir/reader-$j.pub" -q \
			&& cmp -s "$dir/maker.pub" "$dir/reader-$j.pub"; }; then
			why="$why public key;"
		fi
		if ! { "$reader" sign "$WORK/payload.json" --key "$dir/k.key" --passphrase-file "$WORK/pw" --out "$dir/reader-$j.sigil" -q \
			&& cmp -s "$dir/maker.sigil" "$dir/reader-$j.sigil"; }; then
			why="$why envelope;"
		fi
		reader_pem=$("$reader" hot-bundle open "$dir/k.hot" --passphrase-file "$WORK/pw" 2>/dev/null)
		if [[ "$maker_pem" != "-----BEGIN PRIVATE KEY-----"* || "$reader_pem" != "$maker_pem" ]]; then
			why="$why PEM;"
		fi
		if ! { "$reader" verify "$dir/maker.sigil" --pubkey "$dir/maker.pub" -q >"$dir/reader-$j.out" 2>/dev/null \
			&& cmp -s "$dir/reader-$j.out" "$WORK/payload.json"; }; then
			why="$why verify;"
		fi
		"$reader" verify "$dir/tampered.sigil" --pubkey "$dir/maker.pub" -q >/dev/null 2>&1
		rc=$?
		if [[ $rc -ne 1 ]]; then why="$why tampered envelope exit $rc;"; fi
		echo "${why:-ok}" >"$dir/verdict-$j"
	done
}

for i in "${!bins[@]}"; do make_and_read "$i" & done
wait
for i in "${!bins[@]}"; do
	if [[ -f "$WORK/made-$i/maker-failed" ]]; then
		fail "pair $i generates a key pair, derives its public key and seals" "${bins[i]}"
		continue
	fi
	for j in "${!bins[@]}"; do
		[[ "$j" == "$i" ]] && continue
		verdict=$(<"$WORK/made-$i/verdict-$j")
		if [[ "$verdict" == ok ]]; then
			pass "a key pair made by pair $i reads identically in pair $j"
		else
			fail "a key pair made by pair $i reads identically in pair $j" "differs:$verdict"
		fi
	done
done

# ── Transcripts ─────────────────────────────────────────────────────────────
# Each pair runs in its own directory holding the reference maker's fixtures
# under the same relative names, so paths in messages match.
prepare() {
	local dir="$1" made="$WORK/made-0"
	mkdir -p "$dir" || return 1
	cp "$made/k.key" "$made/k.hot" "$made/tampered.sigil" "$WORK/payload.json" "$WORK/pw" "$WORK/wrong" \
		"$WORK/empty" "$dir/" || return 1
	cp "$made/maker.pub" "$dir/this.pub" || return 1
	cp "$made/maker.sigil" "$dir/this.sigil" || return 1
	cp "$made/k.key" "$dir/existing.key" || return 1
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
COUNT=$(wc -l <<<"$INVOCATIONS")

# run_table BIN DIR: every invocation in DIR, recording stdout, stderr and the
# exit code under DIR/.t/N.
run_table() {
	local bin="$1" dir="$2" n line arg
	local -a fields=() args=()
	mkdir -p "$dir/.t"
	for ((n = 1; n <= COUNT; n++)); do
		line=$(sed -n "${n}p" <<<"$INVOCATIONS")
		read -r -a fields <<<"$line"
		args=()
		for arg in "${fields[@]:1}"; do args+=("${arg//%/ }"); done
		(cd "$dir" && NO_COLOR=1 "$bin" "${args[@]}" <"${fields[0]}" >".t/$n.out" 2>".t/$n.err"; echo "$?" >".t/$n.rc")
	done
}

for i in "${!bins[@]}"; do
	if ! prepare "$WORK/t-$i"; then
		fail "prepare transcript fixtures for pair $i"
		finish
	fi
done
for i in "${!bins[@]}"; do run_table "${bins[i]}" "$WORK/t-$i" & done
wait
for ((i = 1; i < ${#bins[@]}; i++)); do
	differ=""
	for ((n = 1; n <= COUNT; n++)); do
		for part in rc out err; do
			if ! cmp -s "$WORK/t-0/.t/$n.$part" "$WORK/t-$i/.t/$n.$part"; then
				line=$(sed -n "${n}p" <<<"$INVOCATIONS")
				differ="$differ
  line $n ($part): $line"
			fi
		done
	done
	# Files the table writes must match too, except fresh keys, which differ
	# by design and are covered by the round trips.
	for f in payload.out signed.sigil page.pdf; do
		if ! cmp -s "$WORK/t-0/$f" "$WORK/t-$i/$f"; then
			differ="$differ
  written file $f"
		fi
	done
	if [[ -z "$differ" ]]; then
		pass "pair $i matches the reference on all $COUNT invocations: stdout, stderr, exit codes, files"
	else
		fail "pair $i matches the reference on all $COUNT invocations" "$differ"
	fi
done

finish
