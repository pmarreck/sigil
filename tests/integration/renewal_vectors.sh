#!/usr/bin/env bash
# Offline-renewal vectors (contract 14.3): each file is canonical (jq -cS of
# itself is byte-identical), carries exactly the allowed keys, and every
# embedded envelope is the exact bytes of an existing vector and verifies
# under its own role key. NOT `set -e`.
#
# Every jq and decoder step is checked: a failed step yields a marker or an
# unwritten file, which then fails its comparison instead of matching.
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

# q JQ_ARGS...: jq's output, or a marker no expected value equals.
q() { jq "$@" 2>/dev/null || echo "(jq failed)"; }
# canon FILE OUT: jq -cS of FILE into OUT without its newline. Compact output
# escapes newlines inside strings, so the terminator is the only one.
canon() { local c; c=$(jq -cS . "$1") || return 1; printf '%s' "$c" > "$2"; }
# canon_del FILE KEY OUT: FILE without KEY, in canonical form.
canon_del() { local c; c=$(jq -cS "del(.$2)" "$1") || return 1; printf '%s' "$c" > "$3"; }
# decode FILE FIELD OUT: the printable-binary encoded FIELD of FILE, decoded
# into OUT. The encoding goes through a file: a here-string would append a
# newline, which the decoder would turn into a byte.
decode() {
	local enc
	enc=$(jq -j ".$2" "$1") || return 1
	printf '%s' "$enc" > "$3.enc" || return 1
	printable-binary -d < "$3.enc" > "$3" 2>/dev/null
}

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
decode "$V/request_activate.json" license "$WORK/lic" && cmp -s "$WORK/lic" "$LV/beta_valid.sigil" \
	&& pass "request license is the exact beta_valid envelope" || fail "request license bytes"
m=$(jq -r .machine "$V/request_activate.json"); want=$(jq -r .machines.A "$IV/manifest.json")
[[ "$m" == "$want" ]] && pass "request machine is machine A" || fail "request machine"

for b in bundle_cert_only bundle_license_and_cert; do
	if decode "$V/$b.json" install_cert "$WORK/cert" \
		&& "$SIGIL" verify "$WORK/cert" --pubkey "$IV/test_install_cert.key.pub" -q >/dev/null 2>&1 && cmp -s "$WORK/cert" "$IV/cert_valid.sigil"; then pass "$b install_cert is cert_valid and verifies"
	else fail "$b install_cert"; fi
done
has_license=$(q 'has("license")' "$V/bundle_cert_only.json")
[[ $has_license == false ]] && pass "cert-only bundle has no license key" || fail "cert-only bundle has no license key"
if decode "$V/bundle_license_and_cert.json" license "$WORK/blic" \
	&& "$SIGIL" verify "$WORK/blic" --pubkey "$LV/test_beta.key.pub" -q >/dev/null 2>&1 && cmp -s "$WORK/blic" "$LV/beta_valid.sigil"; then pass "bundle license is beta_valid and verifies"
else fail "bundle license"; fi


# Contract 15.1: the request may carry an optional `hints` object (disk, mac,
# tpm; each a 64-hex hint from examples/hint_vectors for the license's own
# product). Canonical form sorts the nested keys too.
H="$V/request_activate_hints.json"; HV="$ROOT/examples/hint_vectors/manifest.json"
if [[ -f "$H" ]]; then
	canon "$H" "$WORK/hcanon" && cmp -s "$WORK/hcanon" "$H" && pass "request_activate_hints is canonical (nested keys sorted)" || fail "request_activate_hints is canonical"
	LC_ALL=C grep -q '\\' "$H" && fail "request_activate_hints contains no backslash" || pass "request_activate_hints contains no backslash"
	k=$(jq -c 'keys' "$H")
	[[ "$k" == '["hints","installed_major","installed_minor","license","machine","operation","v"]' ]] && pass "hints request carries exactly seven keys" || fail "hints request keys" "$k"
	hk=$(jq -c '.hints | keys' "$H")
	[[ "$hk" == '["disk","mac","tpm"]' ]] && pass "hints object holds disk, mac and tpm" || fail "hints keys" "$hk"
	nhex=$(q '[.hints[] | select(type == "string" and test("^[0-9a-f]{64}$"))] | length' "$H")
	[[ $nhex == 3 ]] && pass "every hint is 64 lowercase hex" || fail "hint value shapes" "$nhex"
	if decode "$H" license "$WORK/hlic" \
		&& "$SIGIL" verify "$WORK/hlic" --pubkey "$LV/test_beta.key.pub" -q > "$WORK/hpayload" 2>/dev/null \
		&& prod=$(jq -r .product "$WORK/hpayload"); then
		:
	else
		prod="(the hints request's license is unreadable)"
	fi
	for kind in disk mac tpm; do
		v=$(jq -r ".hints.$kind" "$H")
		n=$(jq --arg p "$prod" --arg k "$kind" --arg v "$v" '[.kats[] | select(.product == $p and .kind == $k and .hint == $v)] | length' "$HV")
		[[ "$n" -ge 1 ]] && pass "hints.$kind is a $prod known answer from hint_vectors" || fail "hints.$kind is a $prod known answer" "$v"
	done
	canon_del "$H" hints "$WORK/nohints" && cmp -s "$WORK/nohints" "$V/request_activate.json" && pass "removing hints yields request_activate byte-identically" || fail "hints request differs only by hints"
else
	fail "request_activate_hints.json exists"
fi

# Contract 15.2: a bundle may carry an optional unsigned `displaced` object
# naming only the displaced device's first-activation date.
BD="$V/bundle_cert_displaced.json"
if [[ -f "$BD" ]]; then
	canon "$BD" "$WORK/bdcanon" && cmp -s "$WORK/bdcanon" "$BD" && pass "bundle_cert_displaced is canonical" || fail "bundle_cert_displaced is canonical"
	bdkeys=$(q -c 'keys' "$BD")
	[[ $bdkeys == '["displaced","install_cert","v"]' ]] && pass "displaced bundle carries exactly displaced, install_cert, v" || fail "displaced bundle keys" "$bdkeys"
	dkeys=$(q -c '.displaced | keys' "$BD")
	[[ $dkeys == '["first_activated"]' ]] && pass "displaced names nothing but first_activated" || fail "displaced keys" "$dkeys"
	jq -e '.displaced.first_activated | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")' "$BD" >/dev/null && pass "first_activated is a YYYY-MM-DD date" || fail "first_activated shape"
	canon_del "$BD" displaced "$WORK/bdno" && cmp -s "$WORK/bdno" "$V/bundle_cert_only.json" && pass "removing displaced yields bundle_cert_only byte-identically" || fail "displaced bundle differs only by displaced"
else
	fail "bundle_cert_displaced.json exists"
fi

# Contract 15.2: an optional `usage` object, {epoch: UUIDv7, scanned_bytes:
# canonical decimal u64}, canonical under jq -cS like `hints`.
U="$V/request_activate_usage.json"
if [[ -f "$U" ]]; then
	canon "$U" "$WORK/ucanon" && cmp -s "$WORK/ucanon" "$U" && pass "request_activate_usage is canonical" || fail "request_activate_usage is canonical"
	ukeys=$(q -c 'keys' "$U")
	[[ $ukeys == '["installed_major","installed_minor","license","machine","operation","usage","v"]' ]] && pass "usage request carries exactly seven keys" || fail "usage request keys" "$ukeys"
	usage_keys=$(q -c '.usage | keys' "$U")
	[[ $usage_keys == '["epoch","scanned_bytes"]' ]] && pass "usage holds exactly epoch and scanned_bytes" || fail "usage keys" "$usage_keys"
	jq -e '.usage.epoch | test("^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")' "$U" >/dev/null && pass "epoch is a lowercase UUIDv7" || fail "epoch shape"
	sb=$(jq -r '.usage.scanned_bytes' "$U")
	# shellcheck disable=SC2071  # equal-length digit strings order lexicographically as numbers; -lt overflows past 2^63
	if [[ "$sb" =~ ^(0|[1-9][0-9]*)$ ]] && { [[ ${#sb} -lt 20 ]] || [[ ${#sb} -eq 20 && "$sb" < "18446744073709551616" ]]; }; then pass "scanned_bytes is a canonical decimal u64"
	else fail "scanned_bytes shape" "$sb"; fi
	canon_del "$U" usage "$WORK/uno" && cmp -s "$WORK/uno" "$V/request_activate.json" && pass "removing usage yields request_activate byte-identically" || fail "usage request differs only by usage"
else
	fail "request_activate_usage.json exists"
fi

# Contract 14.4: a renew/migrate bundle carries the v2 license AND a fresh
# certificate bound to exactly that license on the same machine.
RB="$V/bundle_renew_v2.json"; L2="$ROOT/examples/license_vectors_v2"
if [[ -f "$RB" ]]; then
	canon "$RB" "$WORK/rbcanon" && cmp -s "$WORK/rbcanon" "$RB" && pass "bundle_renew_v2 is canonical" || fail "bundle_renew_v2 is canonical"
	rbkeys=$(q -c keys "$RB")
	[[ $rbkeys == '["install_cert","license","v"]' ]] && pass "renew bundle carries install_cert, license, v" || fail "renew bundle keys" "$rbkeys"
	decode "$RB" license "$WORK/rlic" && cmp -s "$WORK/rlic" "$L2/v2_valid.sigil" && pass "renew bundle license is the exact v2_valid envelope" || fail "renew bundle license bytes"
	if decode "$RB" install_cert "$WORK/rcert" \
		&& "$SIGIL" verify "$WORK/rcert" --pubkey "$IV/test_install_cert.key.pub" -q > "$WORK/rcert.json" 2>/dev/null; then pass "renew bundle certificate verifies under test-install-cert"
	else fail "renew bundle certificate verifies under test-install-cert"; fi
	lh=$(sha256sum "$WORK/rlic") || lh="(hash failed)"
	lh=${lh%% *}
	bound_lh=$(q -r .license_sha256 "$WORK/rcert.json")
	[[ $bound_lh == "$lh" ]] && pass "the certificate binds the SHA-256 of the bundled v2 license" || fail "certificate license binding" "$bound_lh"
	bound_m=$(q -r .machine "$WORK/rcert.json"); machine_a=$(q -r .machines.A "$IV/manifest.json")
	[[ $bound_m == "$machine_a" ]] && pass "the certificate binds machine A" || fail "certificate machine" "$bound_m"
	lexp=$(jq -r .expiry "$L2/v2_valid.payload.json"); cexp=$(jq -r .expiry "$WORK/rcert.json")
	[[ ! "$cexp" > "$lexp" ]] && pass "certificate expiry $cexp is not after the license expiry $lexp" || fail "certificate outlives license"
else
	fail "bundle_renew_v2.json exists"
fi
echo ""
echo "$PASS passed, $FAIL failed"
exit $(( FAIL > 0 ? 1 : 0 ))
