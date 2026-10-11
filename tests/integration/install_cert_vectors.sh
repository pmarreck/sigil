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

for name in $(jq -r ".licenses | keys[]" "$M"); do
	lf="$LV/$name.sigil"; [[ -f "$lf" ]] || lf="$ROOT/examples/license_vectors_v2/$name.sigil"
	h=$(sha256sum "$lf" 2>/dev/null); h=${h%% *}
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

# Every machine label resolves to a coreutils-computed KAT, so a label can
# never carry a hash the generator did not derive from a raw id.
for label in $(jq -r '.machines | keys[]' "$M"); do
	h=$(jq -r ".machines[\"$label\"]" "$M")
	if jq -e --arg h "$h" 'any(.machine_hash_kats[]; .machine == $h)' "$M" >/dev/null; then pass "machine label $label is a KAT hash"
	else fail "machine label $label is a KAT hash" "$h"; fi
done

# Each positive eval names a certificate whose payload binds exactly that
# product, license envelope and machine; each product has such a control.
for prod in mecha-validate mecha-rotshield; do
	n=$(jq --arg p "$prod" '[.vectors[].evals[] | select(.expect == "install_cert_valid" and .product == $p)] | length' "$M")
	[[ "$n" -ge 1 ]] && pass "$prod has $n positive certificate evals" || fail "$prod has a positive certificate eval"
done
n=$(jq '[.vectors[].evals[] | select(.expect == "install_cert_valid" and .product == "mecha-rotshield" and .license == "v2_rotshield_valid")] | length' "$M")
[[ "$n" -ge 1 ]] && pass "the paid v2 RotShield grant has a matching certificate" || fail "the paid v2 RotShield grant has a matching certificate"
for ((i = 0; i < nv; i++)); do
	p=$(jq -r ".vectors[$i].payload" "$M")
	while IFS='|' read -r prod lic mach; do
		[[ -z "$prod" ]] && continue
		got=$(jq -r '[.product, .license_sha256, .machine] | join("|")' "$V/$p")
		want="$prod|$(jq -r ".licenses[\"$lic\"]" "$M")|$(jq -r ".machines[\"$mach\"]" "$M")"
		[[ "$got" == "$want" ]] && pass "$p binds its positive eval ($prod, $lic, $mach)" || fail "$p binds its positive eval" "got $got want $want"
	done < <(jq -r ".vectors[$i].evals[] | select(.expect == \"install_cert_valid\") | [.product, .license, .machine] | join(\"|\")" "$M" | sort -u)
done

# PKCS#8 TEST seeds for WebCrypto issuers (the commerce Worker cannot open
# sealed keyfiles): RFC 8410 DER shape, and openssl -- an implementation sigil
# did not write -- derives from each seed the public key sigil derives from the
# committed .pub. A seed that does not belong to its role fails here.
for pair in "$V/test_install_cert" "$LV/test_beta" "$LV/test_paid"; do
	role=$(basename "$pair"); pem="$pair.pkcs8.pem"
	if [[ ! -f "$pem" ]]; then fail "$role.pkcs8.pem exists"; continue; fi
	prefix=$(sed -n '2p' "$pem" | base64 -d 2>/dev/null | head -c 16 | od -An -tx1 | tr -d ' \n')
	len=$(sed -n '2p' "$pem" | base64 -d 2>/dev/null | wc -c)
	[[ "$len" == 48 && "$prefix" == 302e020100300506032b657004220420 ]] && pass "$role.pkcs8.pem is Ed25519 PKCS#8 (RFC 8410)" || fail "$role.pkcs8.pem shape" "len=$len prefix=$prefix"
	got=$(openssl pkey -in "$pem" -pubout -outform DER 2>/dev/null | tail -c 32 | od -An -tx1 | tr -d ' \n')
	want=$("$SIGIL" pubkey --pubkey "$pair.key.pub" --format hex 2>/dev/null)
	[[ -n "$want" && "$got" == "$want" ]] && pass "$role.pkcs8.pem seed derives the $role public key (openssl)" || fail "$role.pkcs8.pem seed derives the $role public key" "openssl=$got sigil=$want"
done

echo ""
echo "$PASS passed, $FAIL failed"
exit $(( FAIL > 0 ? 1 : 0 ))
