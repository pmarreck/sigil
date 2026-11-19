#!/usr/bin/env bash
# The supported way for a product to build sigil's verifier for its own
# target: `zig build verify-lib`, wrapped by the flake as
# legacyPackages.<system>.verifyLibraryFor TARGET. validate_gui needs it for
# macOS, Windows and Linux. For every target the flake lists, this suite
# checks that the build:
#   - succeeded;
#   - installed exactly its static library (lib/libsigil.a, or lib/sigil.lib
#     on Windows) and include/sigil.h, the header byte for byte the
#     repository's own;
#   - left every function sigil.h declares named in the archive, and none of
#     the functions sigil_sign.h declares, so a product cannot mint a
#     license;
#   - for macOS, has 8-byte aligned, owner-readable members (Apple's linker
#     skips others; see macos_archive.sh).
#
# Names are read from the archive's bytes, which works for ELF, Mach-O and
# COFF alike (Mach-O prefixes an underscore). The function lists come from
# the headers through scripts/c-header-functions, so a new declaration joins
# the check without an edit here.
#
# The flake package verify-lib-results builds every target once per change
# to the Zig sources and records each build's exit status, log and installed
# tree; ./build links it as .nix-out/verify-libs. This suite judges those
# records. Missing records fail; nothing is built here.
#
# Controls: the same name scan must find every signing function in the
# signing library, both as ELF (zig-out) and as Mach-O (the macOS archive
# record), so a scan that finds nothing cannot pass.
#
# Per Mecha conventions: `set -u` only.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
R="${SIGIL_VERIFY_LIB_OUT:-$ROOT/.nix-out/verify-libs}"
MACOS="${SIGIL_MACOS_ARCHIVE_OUT:-$ROOT/.nix-out/macos-archives}"
ZIG_LIB="${SIGIL_ZIG_OUT:-$ROOT/zig-out}/lib"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() {
	FAIL=$((FAIL + 1))
	printf '  \033[31mFAIL\033[0m %s\n' "$1"
	if [[ $# -gt 1 ]]; then printf '       %s\n' "$2"; fi
	return 0
}
finish() { echo "$PASS passed, $FAIL failed"; exit "$FAIL"; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sigil-verifylib-XXXXXX")" || exit 1
trap 'rm -rf -- "$WORK"' EXIT

echo "verification library per target — $R"

if ! verify_fns=$(bash "$ROOT/scripts/c-header-functions" "$ROOT/include/sigil.h"); then
	fail "sigil.h declares functions" "$verify_fns"
	finish
fi
if ! sign_fns=$(bash "$ROOT/scripts/c-header-functions" "$ROOT/include/sigil_sign.h"); then
	fail "sigil_sign.h declares functions" "$sign_fns"
	finish
fi

# names_in ARCHIVE: every printable string in ARCHIVE, one per line, a
# leading underscore removed (Mach-O). Fails when the archive cannot be read.
names_in() {
	local text
	text=$(strings -a "$1") || return 1
	awk '{ sub(/^_/, ""); print }' <<<"$text"
}

# missing FUNCTIONS NAMES: the FUNCTIONS absent from NAMES, space-separated.
missing() {
	local fn out=""
	for fn in $1; do
		grep -qxF "$fn" <<<"$2" || out="$out $fn"
	done
	printf '%s' "$out"
}

# present FUNCTIONS NAMES: the FUNCTIONS found in NAMES, space-separated.
present() {
	local fn out=""
	for fn in $1; do
		grep -qxF "$fn" <<<"$2" && out="$out $fn"
	done
	printf '%s' "$out"
}

# Controls first: the scan must see signing functions where they exist.
for control in "ELF:$ZIG_LIB/libsigil_sign.a" "Mach-O:$MACOS/aarch64-macos/lib/libsigil_sign.a"; do
	format=${control%%:*}
	archive=${control#*:}
	if [[ ! -f "$archive" ]]; then
		fail "control ($format): the signing library exists to scan" "$archive"
	elif ! names=$(names_in "$archive"); then
		fail "control ($format): the signing library can be read" "$archive"
	else
		gone=$(missing "$sign_fns" "$names")
		if [[ -z "$gone" ]]; then
			pass "control ($format): the scan finds every signing function in the signing library"
		else
			fail "control ($format): the scan finds every signing function in the signing library" "missing:$gone"
		fi
	fi
done

if [[ ! -f "$R/targets" ]]; then
	fail "the record lists its targets" "no $R/targets (./build makes .nix-out/verify-libs)"
	finish
fi
mapfile -t targets <"$R/targets"
if [[ ${#targets[@]} -eq 0 ]]; then
	fail "the record lists its targets" "$R/targets is empty"
	finish
fi

for t in "${targets[@]}"; do
	rc=""
	[[ -f "$R/$t.rc" ]] && rc=$(<"$R/$t.rc")
	if [[ $rc != 0 ]]; then
		log_tail=$(tail -3 "$R/$t.log" 2>/dev/null) || log_tail="no log at $R/$t.log"
		fail "$t: verify-lib builds" "${log_tail//$'\n'/|}"
		continue
	fi
	pass "$t: verify-lib builds"

	if ! listing=$(find "$R/$t" \( -type f -o -type l \) -printf '%P\n'); then
		fail "$t: the installed tree can be listed" "$listing"
		continue
	fi
	tree=$(sort <<<"$listing")
	# The target's static library name, as Zig writes it: sigil.lib on
	# Windows (which MinGW's linker also finds for -lsigil), libsigil.a
	# elsewhere.
	case "$t" in
		*windows*) lib=lib/sigil.lib ;;
		*) lib=lib/libsigil.a ;;
	esac
	expected=$(printf '%s\n' include/sigil.h "$lib" | sort)
	if [[ "$tree" == "$expected" ]]; then
		pass "$t: installs exactly $lib and include/sigil.h"
	else
		fail "$t: installs exactly $lib and include/sigil.h" "${tree//$'\n'/ }"
	fi
	if cmp -s "$R/$t/include/sigil.h" "$ROOT/include/sigil.h"; then
		pass "$t: the installed sigil.h is the repository's"
	else
		fail "$t: the installed sigil.h is the repository's"
	fi

	archive="$R/$t/$lib"
	if [[ ! -f "$archive" ]]; then
		fail "$t: $lib exists"
		continue
	fi
	if ! names=$(names_in "$archive"); then
		fail "$t: $lib can be read"
		continue
	fi
	gone=$(missing "$verify_fns" "$names")
	if [[ -z "$gone" ]]; then
		pass "$t: names every function sigil.h declares"
	else
		fail "$t: names every function sigil.h declares" "missing:$gone"
	fi
	minted=$(present "$sign_fns" "$names")
	if [[ -z "$minted" ]]; then
		pass "$t: names no signing function"
	else
		fail "$t: names no signing function" "found:$minted"
	fi

	case "$t" in
		*macos*)
			if ! members=$(zig ar tvO "$archive" 2>&1); then
				fail "$t: zig ar lists the members" "$members"
				continue
			fi
			n=0
			bad=""
			while read -r mode _ _ _ _ _ _ name off; do
				case "$name" in __.SYMDEF*) continue ;; esac
				n=$((n + 1))
				((off % 8 == 0)) || bad="$bad $name@$off(misaligned)"
				[[ "$mode" == r* ]] || bad="$bad $name($mode unreadable)"
			done <<<"$members"
			if [[ $n -ge 1 && -z "$bad" ]]; then
				pass "$t: $n member(s), 8-byte aligned and owner-readable"
			else
				fail "$t: members 8-byte aligned and owner-readable" "n=$n$bad"
			fi
			;;
	esac
done

finish
