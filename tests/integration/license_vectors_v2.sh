#!/usr/bin/env bash
# Payload v2 vectors (contract section 14): every envelope verifies under the
# role the manifest names, to its exact payload bytes, and under no other
# test key; every eval carries app_minor and a known decision; regeneration is
# byte-identical; the frozen v1 set is untouched. NOT `set -e`.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SIGIL="${SIGIL_BIN:-$ROOT/zig-out/bin/sigil}"
V="$ROOT/examples/license_vectors_v2"; M="$V/manifest.json"; V1="$ROOT/examples/license_vectors"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ $# -gt 1 ]] && printf '       %s\n' "$2"; return 0; }
WORK="${TMPDIR:-/tmp}/sigil-lv2-$$"; mkdir -p "$WORK" || exit 1
trap 'rm -rf "$WORK"' EXIT
echo "license vectors v2 — $V"

[[ $(jq -r .schema "$M") == "mecha-license-vectors/2" ]] && pass "schema is mecha-license-vectors/2" || fail "schema"
pub() { case "$1" in test-beta) echo "$V1/test_beta.key.pub" ;; test-paid) echo "$V1/test_paid.key.pub" ;; esac; }
other() { case "$1" in test-beta) echo test-paid ;; test-paid) echo test-beta ;; esac; }
nv=$(jq '.vectors | length' "$M")
[[ "$nv" -ge 12 ]] && pass "manifest lists $nv vectors" || fail "manifest size" "$nv"
for ((i = 0; i < nv; i++)); do
	f=$(jq -r ".vectors[$i].file" "$M"); p=$(jq -r ".vectors[$i].payload" "$M"); r=$(jq -r ".vectors[$i].signed_by_role" "$M")
	if "$SIGIL" verify "$V/$f" --pubkey "$(pub "$r")" -q > "$WORK/out" 2>/dev/null && cmp -s "$WORK/out" "$V/$p"; then pass "$f verifies under $r to its exact payload"
	else fail "$f verifies under $r to its exact payload"; fi
	if "$SIGIL" verify "$V/$f" --pubkey "$(pub "$(other "$r")")" -q >/dev/null 2>&1; then fail "$f must not verify under $(other "$r")"
	else pass "$f refused under $(other "$r")"; fi
done
known='["authorized","malformed","wrong_product","expired","version_ceiling","class_key_mismatch","clock_rollback","operation_not_granted"]'
bad=$(jq --argjson k "$known" '[.vectors[].policy_evals[] | select((.app_minor | type) != "number" or (.app_major | type) != "number" or (.expect as $x | $k | index($x)) == null)] | length' "$M")
[[ "$bad" -eq 0 ]] && pass "every eval carries integer app_major and app_minor and a known decision" || fail "eval shape" "$bad bad"
for kind in authorized version_ceiling expired malformed class_key_mismatch wrong_product; do
	c=$(jq --arg k "$kind" '[.vectors[].policy_evals[] | select(.expect == $k)] | length' "$M")
	[[ "$c" -ge 1 ]] && pass "at least one eval expects $kind" || fail "coverage: $kind"
done
# v2 payloads say v 2 and carry max_minor; the frozen v1 set does not change.
for f in v2_valid v2_leap; do
	[[ $(jq -r '.v + "/" + .max_minor' "$V/$f.payload.json") =~ ^2/[0-9]+$ ]] && pass "$f is a v2 payload with max_minor" || fail "$f v2 shape"
done
# Each product has a paid v2 grant admitted at its own ceiling and refused
# one minor and one major above it; authorized evals name the payload's own
# product.
for prod in mecha-validate mecha-rotshield; do
	q='[.vectors[] | select(.signed_by_role == "test-paid" and (.file | startswith("v2_"))) as $v
		| ($v.payload) as $p | $v.policy_evals[] | select(.product == $prod) | . + {payload: $p}]'
	rows=$(jq -c --arg prod "$prod" "$q" "$M")
	ok=1
	while IFS='|' read -r payload ma mi x; do
		mm=$(jq -r '.max_major + "|" + .max_minor + "|" + .product' "$V/$payload")
		IFS='|' read -r pma pmi pprod <<< "$mm"
		case "$x" in
			authorized) [[ "$pprod" == "$prod" ]] || ok=0
				[[ "$ma" == "$pma" && "$mi" == "$pmi" ]] && seen_at=1 ;;
			version_ceiling)
				[[ "$ma" == "$pma" && "$mi" == $((pmi + 1)) ]] && seen_minor=1
				[[ "$ma" == $((pma + 1)) ]] && seen_major=1 ;;
		esac
	done < <(jq -r '.[] | [.payload, .app_major, .app_minor, .expect] | join("|")' <<< "$rows")
	[[ ${seen_at:-0} == 1 ]] && pass "$prod: paid v2 grant admitted at its own ceiling" || fail "$prod: paid v2 grant admitted at its own ceiling"
	[[ ${seen_minor:-0} == 1 ]] && pass "$prod: refused one minor above the ceiling" || fail "$prod: refused one minor above the ceiling"
	[[ ${seen_major:-0} == 1 ]] && pass "$prod: refused one major above the ceiling" || fail "$prod: refused one major above the ceiling"
	[[ $ok == 1 ]] && pass "$prod: authorized evals name the payload's product" || fail "$prod: an authorized eval names another product"
	unset seen_at seen_minor seen_major
done
before=$(cd "$V" && sha256sum ./*.sigil ./*.payload.json manifest.json | sha256sum)
v1before=$(cd "$V1" && sha256sum ./*.sigil manifest.json | sha256sum)
bash "$V/generate" >/dev/null 2>&1
after=$(cd "$V" && sha256sum ./*.sigil ./*.payload.json manifest.json | sha256sum)
v1after=$(cd "$V1" && sha256sum ./*.sigil manifest.json | sha256sum)
[[ "$before" == "$after" ]] && pass "regeneration is byte-identical" || fail "regeneration is byte-identical"
[[ "$v1before" == "$v1after" ]] && pass "the frozen v1 set is untouched" || fail "the frozen v1 set changed"
echo "$PASS passed, $FAIL failed"
exit "$FAIL"
