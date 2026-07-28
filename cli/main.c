/* sigil CLI — deliberately written in C.
 *
 * C physically cannot @import the Zig core, so this binary is forced through the
 * same FFI boundary that Mecha Validate and Mecha Rotshield will use. The
 * constraint is the point: a bypass is inexpressible rather than merely
 * discouraged. */

#include <stdio.h>
#include <string.h>
#include "sigil.h"

/* Explicitly-requested help is the requested OUTPUT and goes to stdout; usage
 * printed because an invocation was malformed is a DIAGNOSTIC and goes to
 * stderr. Callers pass the stream that matches their situation. */
static int usage(FILE *out) {
	fprintf(out,
		"Usage: sigil <command>\n"
		"\n"
		"Commands:\n"
		"  --about        one-line description, version, platform\n"
		"  -h, --help     this help\n"
		"\n"
		"Verification of a license envelope is not wired up yet; the FFI it will\n"
		"call (sigil_verify) is implemented and tested. See PLAN.md.\n");
	return 64; /* EX_USAGE */
}

int main(int argc, char *argv[]) {
	if (argc < 2) return usage(stderr);

	if (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0) {
		usage(stdout);
		return 0;
	}
	if (strcmp(argv[1], "--about") == 0) {
		printf("sigil %s — verify Ed25519-signed documents (%s/%s)\n",
			sigil_version(),
#if defined(__linux__)
			"linux",
#elif defined(__APPLE__)
			"macos",
#elif defined(_WIN32)
			"windows",
#else
			"unknown",
#endif
#if defined(__x86_64__) || defined(_M_X64)
			"x86_64"
#elif defined(__aarch64__) || defined(_M_ARM64)
			"aarch64"
#else
			"unknown"
#endif
		);
		return 0;
	}

	fprintf(stderr, "sigil: unknown command: %s\n", argv[1]);
	return usage(stderr);
}
