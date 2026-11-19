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
	if tr -d ' \t\r\n' < "$WORK/raw" > "$WORK/trimmed" && tr 'A-Z' 'a-z' < "$WORK/trimmed" > "$WORK/norm"; then
		norm=$(<"$WORK/norm")
	else
		norm="(normalization failed)"
	fi
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
# product, license envelope and machine. Each product the contract names (its
# own line, so a product added there without vectors fails here) has such a
# control bound to a paid v2 grant, and every positive eval's license is a
# grant for the eval's own product.
license_payload() {
	if [[ -f "$LV/$1.payload.json" ]]; then printf '%s' "$LV/$1.payload.json"
	else printf '%s' "$ROOT/examples/license_vectors_v2/$1.payload.json"; fi
}
if products=$(bash "$ROOT/scripts/contract-products"); then
	nprod=$(wc -l <<<"$products")
	pass "the contract names $nprod products"
else
	fail "read the contract's product identifiers"; products=""
fi
for prod in $products; do
	n=$(jq --arg p "$prod" '[.vectors[].evals[] | select(.expect == "install_cert_valid" and .product == $p)] | length' "$M")
	[[ "$n" -ge 1 ]] && pass "$prod has $n positive certificate evals" || fail "$prod has a positive certificate eval"
	paid=0
	# A failed jq lists no licenses, so the paid check below fails.
	lics=$(jq -r --arg p "$prod" '.vectors[].evals[] | select(.expect == "install_cert_valid" and .product == $p) | .license' "$M") || lics=""
	lics=$(sort -u <<<"$lics")
	while IFS= read -r lic; do
		[[ -z "$lic" ]] && continue
		lpf=$(license_payload "$lic")
		shape=$(jq -r '[.v, .payment_provider] | join("/")' "$lpf" 2>/dev/null)
		[[ "$shape" == "2/paddle" ]] && paid=1
	done <<<"$lics"
	[[ $paid == 1 ]] && pass "$prod: a certificate admits a paid v2 grant" || fail "$prod: a certificate admits a paid v2 grant"
done
if positives=$(jq -r '.vectors[].evals[] | select(.expect == "install_cert_valid") | [.product, .license] | join("|")' "$M"); then
	positives=$(sort -u <<<"$positives")
else
	fail "list the positive certificate evals"; positives=""
fi
while IFS='|' read -r prod lic; do
	[[ -z "$prod" ]] && continue
	lpf=$(license_payload "$lic")
	lp=$(jq -r .product "$lpf" 2>/dev/null)
	[[ "$lp" == "$prod" ]] && pass "positive $prod eval binds a $prod grant ($lic)" || fail "positive $prod eval binds a $prod grant ($lic)" "license product: $lp"
done <<<"$positives"
for ((i = 0; i < nv; i++)); do
	p=$(jq -r ".vectors[$i].payload" "$M")
	if bound=$(jq -r ".vectors[$i].evals[] | select(.expect == \"install_cert_valid\") | [.product, .license, .machine] | join(\"|\")" "$M"); then
		bound=$(sort -u <<<"$bound")
	else
		fail "list the positive evals of vector $i"; bound=""
	fi
	while IFS='|' read -r prod lic mach; do
		[[ -z "$prod" ]] && continue
		got=$(jq -r '[.product, .license_sha256, .machine] | join("|")' "$V/$p")
		lh=$(jq -r ".licenses[\"$lic\"]" "$M") || lh="(jq failed)"
		mh=$(jq -r ".machines[\"$mach\"]" "$M") || mh="(jq failed)"
		want="$prod|$lh|$mh"
		[[ "$got" == "$want" ]] && pass "$p binds its positive eval ($prod, $lic, $mach)" || fail "$p binds its positive eval" "got $got want $want"
	done <<<"$bound"
done

# PKCS#8 TEST seeds for WebCrypto issuers (the commerce Worker cannot open
# sealed keyfiles): RFC 8410 DER shape, and openssl -- an implementation sigil
# did not write -- derives from each seed the public key sigil derives from the
# committed .pub. A seed that does not belong to its role fails here.
for pair in "$V/test_install_cert" "$LV/test_beta" "$LV/test_paid"; do
	role=$(basename "$pair"); pem="$pair.pkcs8.pem"
	if [[ ! -f "$pem" ]]; then fail "$role.pkcs8.pem exists"; continue; fi
	# The DER is binary, so it is decoded once into a file, each step checked.
	if b64=$(sed -n '2p' "$pem") && base64 -d <<<"$b64" >"$WORK/$role.der" 2>/dev/null \
		&& len=$(wc -c <"$WORK/$role.der") && prefix=$(od -An -tx1 -N16 "$WORK/$role.der"); then
		len=${len//[[:space:]]/}
		prefix=${prefix//[[:space:]]/}
	else
		len="(decode failed)"; prefix=""
	fi
	[[ "$len" == 48 && "$prefix" == 302e020100300506032b657004220420 ]] && pass "$role.pkcs8.pem is Ed25519 PKCS#8 (RFC 8410)" || fail "$role.pkcs8.pem shape" "len=$len prefix=$prefix"
	# The public key is the last 32 bytes of openssl's SubjectPublicKeyInfo.
	spki="$WORK/$role.spki"
	if openssl pkey -in "$pem" -pubout -outform DER -out "$spki" 2>/dev/null \
		&& spki_len=$(wc -c <"$spki") && (( spki_len >= 32 )) \
		&& got=$(od -An -tx1 -v -j $((spki_len - 32)) "$spki"); then
		got=${got//[[:space:]]/}
	else
		got="(openssl failed)"
	fi
	want=$("$SIGIL" pubkey --pubkey "$pair.key.pub" --format hex 2>/dev/null)
	[[ -n "$want" && "$got" == "$want" ]] && pass "$role.pkcs8.pem seed derives the $role public key (openssl)" || fail "$role.pkcs8.pem seed derives the $role public key" "openssl=$got sigil=$want"
done

echo ""
echo "$PASS passed, $FAIL failed"
exit $(( FAIL > 0 ? 1 : 0 ))
