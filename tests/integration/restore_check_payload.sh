#!/usr/bin/env bash
# The isolated-restore payload (custody section 2 (ii)(b), runbook section 3
# (iii)) is signed by REAL production keys, so it must never be anything an
# app could accept: no license shape and no certificate shape. Checked here
# as a classifier over the keys every license and certificate parser
# requires. NOT `set -e`.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
P="$ROOT/examples/restore_check/payload.json"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ $# -gt 1 ]] && printf '       %s\n' "$2"; return 0; }
echo "restore-check payload — $P"
if [[ ! -f "$P" ]]; then fail "restore-check payload exists"; echo "$PASS passed, $FAIL failed"; exit 1; fi
jq -e . "$P" >/dev/null 2>&1 && pass "payload is JSON" || fail "payload is JSON"
for k in product max_major expiry purchase_date payment_provider customer_email cert_id machine license_sha256 issued; do
	if [[ $(jq --arg k "$k" 'has($k)' "$P") == false ]]; then pass "payload carries no '$k' (no license or certificate parser can accept it)"
	else fail "payload must not carry '$k'"; fi
done
[[ $(jq -r .purpose "$P") == "mecha-restore-check" ]] && pass "payload names its purpose" || fail "payload names its purpose"
jq -cS . "$P" | tr -d '\n' > "${TMPDIR:-/tmp}/rc-canon-$$"
cmp -s "${TMPDIR:-/tmp}/rc-canon-$$" "$P" && pass "payload is canonical (jq -cS)" || fail "payload is canonical (jq -cS)"
rm -f "${TMPDIR:-/tmp}/rc-canon-$$"
echo "$PASS passed, $FAIL failed"
exit "$FAIL"
