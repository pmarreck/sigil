/* JSON escaping, swept over the whole byte alphabet.
 *
 * The defect this prevents: `--json` spliced sigil_strerror() into a JSON
 * string literal unescaped, and one of those messages contains `"Ed25519"`,
 * so the error path emitted JSON that jq refuses to parse. A consumer of
 * --json fails at exactly the moment it most needs to read the reason.
 *
 * Swept over all 256 byte values rather than the one message that happened to
 * break, because the bug was a whole CLASS (any metacharacter in any message)
 * and a per-example test would only ever cover the examples someone thought
 * of. The CLI suite additionally pipes every --json invocation through jq,
 * which is the real parse oracle and one nobody here wrote.
 */

#include <stdio.h>
#include <string.h>

#include "sigil.h"
#include "json.h"

static int passed = 0;
static int failed = 0;

static void ok(const char *what) { printf("  ok   %s\n", what); passed++; }
static void bad(const char *what, const char *detail) {
	printf("  FAIL %s\n", what);
	if (detail) printf("       %s\n", detail);
	failed++;
}

/* Every byte that may appear RAW inside a JSON string per RFC 8259: anything
 * except '"', '\' and the C0 controls. */
static int legal_raw(unsigned char c) {
	return c != '"' && c != '\\' && c >= 0x20;
}

int main(void) {
	char out[64];
	char detail[256];

	/* 1. Sweep: every single byte, escaped, must contain no illegal raw byte
	 *    outside of a backslash escape. */
	int offenders = 0;
	for (int b = 1; b < 256; b++) {   /* 0 is the terminator, not content */
		char in[2] = { (char)b, '\0' };
		sigil_json_escape(out, sizeof out, in);

		for (size_t i = 0; out[i]; i++) {
			unsigned char c = (unsigned char)out[i];
			if (c == '\\') { i++; continue; }   /* skip the escaped char */
			if (!legal_raw(c)) {
				if (offenders < 3) {
					snprintf(detail, sizeof detail,
						"byte 0x%02x escaped to something containing raw 0x%02x", b, c);
					printf("       %s\n", detail);
				}
				offenders++;
				break;
			}
		}
	}
	if (offenders == 0) ok("all 255 non-NUL bytes escape to JSON-legal output");
	else {
		snprintf(detail, sizeof detail, "%d byte values produced illegal output", offenders);
		bad("all 255 non-NUL bytes escape to JSON-legal output", detail);
	}

	/* 2. The exact message that broke it. */
	sigil_json_escape(out, sizeof out, "sigtype is not \"Ed25519\"");
	if (strcmp(out, "sigtype is not \\\"Ed25519\\\"") == 0) {
		ok("the message that caused the bug escapes correctly");
	} else {
		snprintf(detail, sizeof detail, "got: %s", out);
		bad("the message that caused the bug escapes correctly", detail);
	}

	/* 3. Every real sigil_strerror message survives, which is what the CLI
	 *    actually emits. */
	const int codes[] = {
		SIGIL_OK, SIGIL_ERR_BAD_SIGNATURE, SIGIL_ERR_BAD_PUBLIC_KEY,
		SIGIL_ERR_NULL_ARGUMENT, SIGIL_ERR_MALFORMED_JSON, SIGIL_ERR_MISSING_FIELD,
		SIGIL_ERR_UNSUPPORTED_SIGTYPE, SIGIL_ERR_MALFORMED_ENCODING,
		SIGIL_ERR_BAD_SIGNATURE_LENGTH, SIGIL_ERR_BUFFER_TOO_SMALL,
		SIGIL_ERR_OUT_OF_MEMORY,
	};
	char big[512];
	int msg_bad = 0;
	for (size_t i = 0; i < sizeof codes / sizeof codes[0]; i++) {
		sigil_json_escape(big, sizeof big, sigil_strerror(codes[i]));
		for (size_t j = 0; big[j]; j++) {
			if (big[j] == '\\') { j++; continue; }
			if (!legal_raw((unsigned char)big[j])) { msg_bad++; break; }
		}
	}
	if (msg_bad == 0) ok("every sigil_strerror message escapes to JSON-legal output");
	else {
		snprintf(detail, sizeof detail, "%d message(s) still illegal", msg_bad);
		bad("every sigil_strerror message escapes to JSON-legal output", detail);
	}

	/* 4. Truncation reports like snprintf rather than overflowing. A short
	 *    buffer must still be NUL-terminated and must not write past cap. */
	char small[8];
	memset(small, 0x7f, sizeof small);
	size_t need = sigil_json_escape(small, 4, "aaaaaaaaaa");
	if (need == 10 && small[3] == '\0' && small[4] == 0x7f) {
		ok("truncation is snprintf-shaped and writes nothing past cap");
	} else {
		snprintf(detail, sizeof detail, "need=%zu small[3]=%d small[4]=%d",
			need, small[3], small[4]);
		bad("truncation is snprintf-shaped and writes nothing past cap", detail);
	}

	/* 5. A string needing no escaping is passed through unchanged, so the
	 *    escaper cannot pass by mangling everything. */
	sigil_json_escape(out, sizeof out, "ok");
	if (strcmp(out, "ok") == 0) ok("text needing no escaping is unchanged");
	else bad("text needing no escaping is unchanged", out);

	printf("\n%d passed, %d failed\n", passed, failed);
	return failed > 0 ? 1 : 0;
}
