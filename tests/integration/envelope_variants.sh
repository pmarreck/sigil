#!/usr/bin/env bash
# Envelope variants (docs/DESIGN.md, "Envelope bytes are not an identifier"):
# one signed license has many valid envelope byte strings, and a few
# look-alikes must be refused. Each variant is built in scratch from a
# committed test license; the expected verdicts are written here by hand.
#
#   accepted, to the exact signed payload, though the file differs:
#     ASCII noise inserted, a line fold inside a multi-byte glyph, the
#     fields reordered, an unknown extra field
#   refused as malformed (exit 65):
#     a duplicated field, a lead byte aliased to another glyph's (not
#     valid UTF-8)
#   refused as not authentic (exit 1):
#     a \u escape: its backslash is stripped as noise and the rest decodes
#     into extra payload bytes
#
# Reads SIGIL_BIN, so ./test runs it against every CLI and library pair.
# NOT `set -e`.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SIGIL="${SIGIL_BIN:-$ROOT/zig-out/bin/sigil}"
E="$ROOT/examples/license_vectors/beta_valid.sigil"
PAYLOAD="$ROOT/examples/license_vectors/beta_valid.payload.json"
KEY="$ROOT/examples/license_vectors/test_beta.key.pub"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ $# -gt 1 ]] && printf '       %s\n' "$2"; return 0; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sigil-envvar-XXXXXX")" || exit 1
trap 'rm -rf -- "$WORK"' EXIT
echo "envelope variants — $SIGIL"

# offset_of BYTE_REGEX: the byte offset of the first match in the envelope.
offset_of() {
	local m
	m=$(LC_ALL=C grep -obUaP -m1 "$1" "$E") || return 1
	m=${m%%$'\n'*}
	printf '%s\n' "${m%%:*}"
}
# splice OUT OFFSET BYTES: the envelope with BYTES written at OFFSET, either
# inserted (insert) or replacing one byte (replace).
splice() {
	local out=$1 off=$2 mode=$3 bytes=$4 rest
	if [[ $mode == insert ]]; then rest=$((off + 1)); else rest=$((off + 2)); fi
	{ head -c "$off" "$E" && printf '%b' "$bytes" && tail -c "+$rest" "$E"; } >"$out"
}

if [[ ! -x "$SIGIL" || ! -f "$E" ]]; then
	fail "the sigil binary and the test license exist" "$SIGIL $E"
	echo "$PASS passed, $FAIL failed"; exit 1
fi
if "$SIGIL" verify "$E" --pubkey "$KEY" -q >"$WORK/base.out" 2>/dev/null && cmp -s "$WORK/base.out" "$PAYLOAD"; then
	pass "control: the minted envelope verifies to its payload"
else
	fail "control: the minted envelope verifies to its payload"
fi

# Build the variants. Each construction is checked, so a failed build fails
# its own check below rather than testing the unmodified envelope.
built=1
sed 's/,/ ,\n> \t/g' "$E" >"$WORK/noise.sigil" || built=0
if lead=$(offset_of '[\xc2-\xf4]'); then
	splice "$WORK/fold.sigil" $((lead + 1)) insert '\n' || built=0
else
	built=0
fi
if reordered=$(jq -c '{sig, sigtype, data}' "$E"); then printf '%s' "$reordered" >"$WORK/reorder.sigil" || built=0; else built=0; fi
if extra=$(jq -c '. + {"note":"anything"}' "$E"); then printf '%s' "$extra" >"$WORK/extra.sigil" || built=0; else built=0; fi
sed 's/"sigtype"/"sigtype":"Ed25519","sigtype"/' "$E" >"$WORK/duplicate.sigil" || built=0
sed 's/"data":"/"data":"\\u0041/' "$E" >"$WORK/escape.sigil" || built=0
if c2=$(offset_of '\xc2'); then
	splice "$WORK/alias.sigil" "$c2" replace '\x82' || built=0
else
	built=0
fi
if [[ $built == 1 ]]; then pass "every variant was built"; else fail "every variant was built"; fi

minted=$(sha256sum "$E") || minted="(hash failed)"
minted=${minted%% *}
for v in noise fold reorder extra; do
	h=$(sha256sum "$WORK/$v.sigil") || h="(hash failed)"
	h=${h%% *}
	if [[ ! -s "$WORK/$v.sigil" || $h == "$minted" ]]; then
		fail "$v: a distinct envelope" "same bytes as the minted envelope, so the check would be vacuous"
	elif "$SIGIL" verify "$WORK/$v.sigil" --pubkey "$KEY" -q >"$WORK/$v.out" 2>/dev/null && cmp -s "$WORK/$v.out" "$PAYLOAD"; then
		pass "$v: a distinct envelope that verifies to the exact signed payload"
	else
		fail "$v: a distinct envelope that verifies to the exact signed payload"
	fi
done
for spec in duplicate:65:malformed alias:65:malformed escape:1:"not authentic"; do
	IFS=: read -r v want why <<<"$spec"
	"$SIGIL" verify "$WORK/$v.sigil" --pubkey "$KEY" -q >/dev/null 2>&1
	rc=$?
	if [[ ! -s "$WORK/$v.sigil" ]] || cmp -s "$WORK/$v.sigil" "$E"; then
		fail "$v: refused as $why" "the variant is empty or equals the minted envelope"
	elif [[ $rc == "$want" ]]; then
		pass "$v: refused as $why (exit $want)"
	else
		fail "$v: refused as $why (exit $want)" "exit $rc"
	fi
done

echo "$PASS passed, $FAIL failed"
exit "$FAIL"
