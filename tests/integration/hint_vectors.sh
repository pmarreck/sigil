#!/usr/bin/env bash
# Device-hint vectors (contract section 15.1): the committed manifest is
# exactly what the generator produces; every hint is recomputed here from its
# hand-written normalized value with coreutils; same (product, kind,
# normalized) means same hint and a different product means a different hint.
# NOT `set -e`.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
V="$ROOT/examples/hint_vectors"; M="$V/manifest.json"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ $# -gt 1 ]] && printf '       %s\n' "$2"; return 0; }
WORK="${TMPDIR:-/tmp}/sigil-hint-$$"; mkdir -p "$WORK" || exit 1
trap 'rm -rf "$WORK"' EXIT
echo "hint vectors — $V"

cp "$V/generate" "$WORK/generate"
if bash "$WORK/generate" && cmp -s "$WORK/manifest.json" "$M"; then pass "regeneration is byte-identical to the committed manifest"
else fail "regeneration is byte-identical to the committed manifest"; fi

hint() {
	local h
	h=$( { printf 'mecha-hint-v1%s' "$1"; printf '\0'; printf '%s' "$2"; printf '\0'; printf '%s' "$3"; } | sha256sum)
	printf '%s' "${h%% *}"
}
nk=$(jq '.kats | length' "$M"); nr=$(jq '.rejects | length' "$M")
[[ "$nk" -ge 14 && "$nr" -ge 12 ]] && pass "manifest has $nk known answers and $nr rejects" || fail "manifest sizes" "$nk/$nr"
for kind in disk mac tpm; do
	c=$(jq --arg k "$kind" '[.kats[] | select(.kind == $k)] | length' "$M")
	r=$(jq --arg k "$kind" '[.rejects[] | select(.kind == $k)] | length' "$M")
	[[ "$c" -ge 1 && "$r" -ge 1 ]] && pass "kind $kind has known answers and rejects" || fail "kind $kind coverage" "$c/$r"
done
bad=0
for ((i = 0; i < nk; i++)); do
	read -r p k n h < <(jq -r ".kats[$i] | \"\(.product) \(.kind) \(.normalized) \(.hint)\"" "$M")
	[[ "$(hint "$p" "$k" "$n")" == "$h" && "$h" =~ ^[0-9a-f]{64}$ ]] || { bad=$((bad + 1)); echo "       kat $i ($k) mismatch"; }
done
[[ $bad -eq 0 ]] && pass "all $nk hints recompute with coreutils" || fail "hints recompute" "$bad bad"
# Equivalence classes: equal (product, kind, normalized) <=> equal hint.
classes=$(jq -r '[.kats[] | "\(.product)|\(.kind)|\(.normalized)"] | unique | length' "$M")
hints=$(jq -r '[.kats[].hint] | unique | length' "$M")
[[ "$classes" -eq "$hints" ]] && pass "$classes distinct inputs give $hints distinct hints" || fail "input classes vs hints" "$classes vs $hints"
# Every rejected input is unambiguous: none collides with a known-answer raw input.
coll=$(jq '[.rejects[] as $r | .kats[] | select(.kind == $r.kind and .raw_hex == $r.raw_hex)] | length' "$M")
[[ "$coll" -eq 0 ]] && pass "no reject shares a raw input with a known answer" || fail "reject/KAT overlap" "$coll"

echo "$PASS passed, $FAIL failed"
exit "$FAIL"
