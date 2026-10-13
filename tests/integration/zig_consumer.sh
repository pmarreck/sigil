#!/usr/bin/env bash
# Downstream Zig consumer contract: `b.dependency("sigil").artifact("sigil")`
# resolves to the static VERIFIER library on every shipped target (Linux,
# macOS, Windows), a product links the C ABI through it, and the linked
# product carries no signing code. Built by tests/zig_consumer, which depends
# on this checkout by path. NOT `set -e`.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
C="$ROOT/tests/zig_consumer"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ $# -gt 1 ]] && printf '%s\n' "$2" | tail -5 | sed 's/^/       /'; return 0; }
WORK="${TMPDIR:-/tmp}/sigil-zc-$$"; mkdir -p "$WORK" || exit 1
trap 'rm -rf "$WORK"' EXIT
echo "downstream Zig consumer — $C"
# Reuse the producer's already-fetched packages: the Nix sandbox has no network,
# and the consumer must not grow its own zig-pkg/ in the source tree.
PKG=(); [[ -d "$ROOT/zig-pkg" ]] && PKG=(--system "$ROOT/zig-pkg")
zb() { (cd "$C" && zig build "${PKG[@]}" --cache-dir "$WORK/cache" --prefix "$WORK/out" "$@" 2>&1); }

for t in x86_64-linux-gnu aarch64-linux-gnu aarch64-macos x86_64-windows-gnu aarch64-windows-gnu; do
	out=$(zb resolve -Dtarget=$t); rc=$?
	[[ $rc -eq 0 ]] && pass "artifact(\"sigil\") is the static verifier for $t" || fail "artifact(\"sigil\") resolves for $t" "$out"
done

D="$ROOT/examples/demo"
exe="$WORK/out/bin/verify_conformance"
out=$(zb install); rc=$?
# Inside a Nix sandbox the FHS loader path Zig writes does not exist; repoint
# it at the stdenv loader, as the flake does for the unit-test binaries.
if [[ $rc -eq 0 && -n "${NIX_CC:-}" && -f "$NIX_CC/nix-support/dynamic-linker" ]] && command -v patchelf >/dev/null \
	&& interp=$(patchelf --print-interpreter "$exe" 2>/dev/null) && [[ ! -e "$interp" ]]; then
	patchelf --set-interpreter "$(cat "$NIX_CC/nix-support/dynamic-linker")" "$exe" 2>/dev/null
fi
[[ $rc -eq 0 ]] && out=$("$exe" "$D/payload.bin" "$D/sig.bin" "$D/pubkey.bin" 2>&1); rc=$?
if [[ $rc -eq 0 ]] && grep -q '^  ok' <<<"$out" && ! grep -q 'FAIL' <<<"$out"; then
	pass "C conformance program linked through artifact(\"sigil\") passes ($(grep -c '^  ok' <<<"$out") checks)"
else fail "C conformance program linked through artifact(\"sigil\")" "$out"; fi

# Forbidden: every function the signing header exports that the verifier
# header does not. Positive half: nm must see the verifier's own sigil_verify.
forbidden=$(comm -23 <(grep -oE '\bsigil_[a-z_]+ *\(' "$ROOT/include/sigil_sign.h" | tr -d ' (' | sort -u) \
	<(grep -oE '\bsigil_[a-z_]+ *\(' "$ROOT/include/sigil.h" | tr -d ' (' | sort -u))
if [[ -f "$exe" && -n "$forbidden" ]]; then
	defined=$(nm --defined-only "$exe" 2>/dev/null | awk '{print $NF}')
	grep -qx 'sigil_verify' <<<"$defined" && pass "nm sees sigil_verify in the linked consumer" || fail "nm sees sigil_verify in the linked consumer"
	leaked=$(grep -xF -f <(printf '%s\n' "$forbidden") <<<"$defined")
	[[ -z "$leaked" ]] && pass "the linked consumer defines none of $(wc -l <<<"$forbidden") signing exports" || fail "the linked consumer defines no signing exports" "$leaked"
else fail "consumer executable installed and signing export list derived" "$exe"; fi

echo ""
echo "$PASS passed, $FAIL failed"
exit $(( FAIL > 0 ? 1 : 0 ))
