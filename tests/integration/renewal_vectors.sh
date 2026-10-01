#!/usr/bin/env bash
# Offline-renewal vectors (contract 14.3): each file is canonical (jq -cS of
# itself is byte-identical), carries exactly the allowed keys, and every
# embedded envelope is the exact bytes of an existing vector and verifies
# under its own role key. NOT `set -e`.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SIGIL="${SIGIL_BIN:-$ROOT/zig-out/bin/sigil}"
V="$ROOT/examples/renewal_vectors"; LV="$ROOT/examples/license_vectors"; IV="$ROOT/examples/install_cert_vectors"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ $# -gt 1 ]] && printf '       %s\n' "$2"; return 0; }
WORK="${TMPDIR:-/tmp}/sigil-rv-$$"; mkdir -p "$WORK" || exit 1
trap 'rm -rf "$WORK"' EXIT
echo "renewal vectors — $V"

for f in request_activate bundle_cert_only bundle_license_and_cert; do
	jq -cS . "$V/$f.json" > "$WORK/canon"; tr -d '\n' < "$WORK/canon" > "$WORK/canon2"
	cmp -s "$WORK/canon2" "$V/$f.json" && pass "$f is canonical (jq -cS round-trips byte-identically)" || fail "$f is canonical"
done

# Peter 2026-10-01 17:20: embedded envelopes are printable-binary encoded,
# so the files contain no JSON escapes at all.
if ! command -v printable-binary >/dev/null 2>&1; then fail "printable-binary decoder on PATH (the independent oracle)"; fi
for f in request_activate bundle_cert_only bundle_license_and_cert; do
	if LC_ALL=C grep -q '\\' "$V/$f.json"; then fail "$f contains no backslash"; else pass "$f contains no backslash (no JSON escapes)"; fi
done

keys=$(jq -c 'keys' "$V/request_activate.json")
[[ "$keys" == '["installed_major","installed_minor","license","machine","operation","v"]' ]] && pass "request carries exactly the six keys" || fail "request keys" "$keys"
jq -j .license "$V/request_activate.json" | printable-binary -d > "$WORK/lic" 2>/dev/null
cmp -s "$WORK/lic" "$LV/beta_valid.sigil" && pass "request license is the exact beta_valid envelope" || fail "request license bytes"
m=$(jq -r .machine "$V/request_activate.json"); want=$(jq -r .machines.A "$IV/manifest.json")
[[ "$m" == "$want" ]] && pass "request machine is machine A" || fail "request machine"

for b in bundle_cert_only bundle_license_and_cert; do
	jq -j .install_cert "$V/$b.json" | printable-binary -d > "$WORK/cert" 2>/dev/null
	if "$SIGIL" verify "$WORK/cert" --pubkey "$IV/test_install_cert.key.pub" -q >/dev/null 2>&1 && cmp -s "$WORK/cert" "$IV/cert_valid.sigil"; then pass "$b install_cert is cert_valid and verifies"
	else fail "$b install_cert"; fi
done
[[ $(jq 'has("license")' "$V/bundle_cert_only.json") == false ]] && pass "cert-only bundle has no license key" || fail "cert-only bundle has no license key"
jq -j .license "$V/bundle_license_and_cert.json" | printable-binary -d > "$WORK/blic" 2>/dev/null
if "$SIGIL" verify "$WORK/blic" --pubkey "$LV/test_beta.key.pub" -q >/dev/null 2>&1 && cmp -s "$WORK/blic" "$LV/beta_valid.sigil"; then pass "bundle license is beta_valid and verifies"
else fail "bundle license"; fi

echo ""
echo "$PASS passed, $FAIL failed"
exit $(( FAIL > 0 ? 1 : 0 ))
