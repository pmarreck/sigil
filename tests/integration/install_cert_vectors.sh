#!/usr/bin/env bash
# Installation-certificate vectors (contract section 15): every certificate
# verifies under test-install-cert to its exact payload bytes and under no
# other test key; the manifest's license hashes match the real license
# vector bytes; its machine hashes are recomputed here with coreutils.
# NOT `set -e`.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SIGIL="${SIGIL_BIN:-$ROOT/zig-out/bin/sigil}"
V="$ROOT/examples/install_cert_vectors"; LV="$ROOT/examples/license_vectors"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ $# -gt 1 ]] && printf '       %s\n' "$2"; return 0; }
WORK="${TMPDIR:-/tmp}/sigil-icv-$$"; mkdir -p "$WORK" || exit 1
trap 'rm -rf "$WORK"' EXIT
M="$V/manifest.json"
echo "install-cert vectors — $V"

nv=$(jq '.vectors | length' "$M")
[[ "$nv" -ge 5 ]] && pass "manifest lists $nv vectors" || fail "manifest lists vectors" "$nv"
for ((i = 0; i < nv; i++)); do
	f=$(jq -r ".vectors[$i].file" "$M"); p=$(jq -r ".vectors[$i].payload" "$M")
	if "$SIGIL" verify "$V/$f" --pubkey "$V/test_install_cert.key.pub" -q > "$WORK/out" 2>/dev/null && cmp -s "$WORK/out" "$V/$p"; then
		pass "$f verifies under test-install-cert to its exact payload"
	else fail "$f verifies under test-install-cert to its exact payload"; fi
	for other in "$LV/test_beta.key.pub" "$LV/test_paid.key.pub"; do
		if "$SIGIL" verify "$V/$f" --pubkey "$other" -q >/dev/null 2>&1; then fail "$f must NOT verify under $(basename "$other")"
		else pass "$f refused under $(basename "$other")"; fi
	done
done

for name in beta_valid wrong_product; do
	h=$(sha256sum "$LV/$name.sigil"); h=${h%% *}
	want=$(jq -r ".licenses.$name" "$M")
	[[ "$h" == "$want" ]] && pass "license hash for $name matches the real envelope bytes" || fail "license hash for $name" "file $h manifest $want"
done

nk=$(jq '.machine_hash_kats | length' "$M")
for ((i = 0; i < nk; i++)); do
	prod=$(jq -r ".machine_hash_kats[$i].product" "$M")
	jq -j ".machine_hash_kats[$i].raw_id" "$M" > "$WORK/raw"
	norm=$(tr -d ' \t\r\n' < "$WORK/raw" | tr 'A-Z' 'a-z')
	{ printf 'mecha-install-v1%s' "$prod"; printf '\0'; printf '%s' "$norm"; } > "$WORK/pre"
	h=$(sha256sum "$WORK/pre"); h=${h%% *}
	want=$(jq -r ".machine_hash_kats[$i].machine" "$M")
	[[ "$h" == "$want" ]] && pass "machine-hash KAT $i recomputes with coreutils" || fail "machine-hash KAT $i" "got $h want $want"
done

echo ""
echo "$PASS passed, $FAIL failed"
exit $(( FAIL > 0 ? 1 : 0 ))
