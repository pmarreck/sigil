/* Differential driver: one source, compiled once per sigil implementation.
 *
 * Both implementations export the same symbols, so they cannot share a
 * process. Each build of this driver prints a deterministic record of what
 * its library answers; tests/differential/run compares the two records byte
 * for byte. Any difference is a divergence between the implementations.
 */
#include <stdio.h>
#include <string.h>

#include "sigil.h"

/* Exhaust a finite domain rather than sample it: every code the header
 * defines, plus a margin on both sides for the "unknown error" fallback. */
#define CODE_MIN (-40)
#define CODE_MAX 8

static int cmd_meta(void) {
	printf("version=%s\n", sigil_version());
	printf("signature_len=%zu\n", sigil_signature_len());
	printf("public_key_len=%zu\n", sigil_public_key_len());
	for (int code = CODE_MAX; code >= CODE_MIN; code--) {
		const char *msg = sigil_strerror(code);
		if (msg == NULL) {
			fprintf(stderr, "sigil_strerror(%d) returned NULL\n", code);
			return 1;
		}
		printf("strerror[%d]=%s\n", code, msg);
	}
	return 0;
}

int main(int argc, char **argv) {
	if (argc == 2 && strcmp(argv[1], "meta") == 0) return cmd_meta();
	fprintf(stderr, "usage: %s meta\n", argc > 0 ? argv[0] : "driver");
	return 64;
}
