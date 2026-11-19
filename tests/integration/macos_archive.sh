#!/usr/bin/env bash
# macOS static libraries must be consumable by Apple's toolchain (ld64,
# libtool): every object member 8-byte aligned and owner-readable. Zig's own
# archiver wrote libsigil_zcu.o at offset 0x18c with mode 0, which Apple
# clang/libtool silently ignored (validate_gui, 2026-10-06). Checks the
# INSTALLED archives of both Mac architectures with `zig ar tvO`.
#
# The flake package macos-archive-results cross-builds both targets once per
# change to the Zig sources and records each build's exit status, log and
# installed tree; ./build links it as .nix-out/macos-archives. This suite
# judges those records. There is no build here and no fallback: missing
# results fail. NOT `set -e`.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
R="${SIGIL_MACOS_ARCHIVE_OUT:-$ROOT/.nix-out/macos-archives}"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ $# -gt 1 ]] && printf '       %s\n' "$2"; return 0; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sigil-macar-XXXXXX")" || exit 1
trap 'rm -rf -- "$WORK"' EXIT
echo "macOS archives — Apple-consumable members — $R"
for t in aarch64-macos x86_64-macos; do
	rc=""
	[[ -f "$R/$t.rc" ]] && rc=$(<"$R/$t.rc")
	if [[ $rc == 0 ]]; then
		pass "cross-build for $t"
	else
		log_tail=$(tail -3 "$R/$t.log" 2>/dev/null) || log_tail="no recorded build at $R/$t (./build makes .nix-out/macos-archives)"
		fail "cross-build for $t" "${log_tail//$'\n'/|}"
		continue
	fi
	for a in libsigil.a libsigil_sign.a; do
		f="$R/$t/lib/$a"
		if [[ ! -f "$f" ]]; then fail "$t $a installed"; continue; fi
		zig ar tvO "$f" > "$WORK/members" 2>&1
		n=0; bad=""
		while read -r mode _ _ _ _ _ _ name off; do
			case "$name" in __.SYMDEF*) continue ;; esac
			n=$((n + 1))
			(( off % 8 == 0 )) || bad="$bad $name@$off(misaligned)"
			[[ "$mode" == r* ]] || bad="$bad $name($mode unreadable)"
		done < "$WORK/members"
		if [[ $n -ge 1 && -z "$bad" ]]; then pass "$t $a: $n object member(s), 8-byte aligned and owner-readable"
		else fail "$t $a: Apple-consumable members" "n=$n$bad"; fi
	done
done
echo "$PASS passed, $FAIL failed"
exit "$FAIL"
