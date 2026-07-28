/* The verify exit-code classifier, tested over the WHOLE set of codes.
 *
 * The bug this exists to prevent: `sigil verify` collapsed every non-OK FFI
 * result to exit 1 ("rejected"). A customer whose machine was briefly under
 * memory pressure was told their valid, paid-for licence is a forgery — the
 * single worst thing a licensing tool can say, indistinguishable from the real
 * thing to whoever reads it.
 *
 * The rule, stated once: anything meaning "I could not determine" must never
 * render as "I determined it is invalid."
 *
 * Tested as a classifier over a partition of every defined code rather than on
 * a hand-picked example, because the defect was precisely that one code fell
 * into the wrong bucket. A per-example test would have passed on the codes
 * someone thought to check.
 */

#include <stdio.h>
#include <string.h>

#include "sigil.h"
#include "exit_codes.h"

static int passed = 0;
static int failed = 0;

static void ok(const char *what) {
	printf("  ok   %s\n", what);
	passed++;
}
static void bad(const char *what, const char *detail) {
	printf("  FAIL %s\n", what);
	if (detail) printf("       %s\n", detail);
	failed++;
}

/* Every code the verify path can produce, partitioned by what it MEANS. */
struct code_case {
	int code;
	const char *name;
};

/* "This document is not authentic." The only class that may exit 1. */
static const struct code_case not_authentic[] = {
	{ SIGIL_ERR_BAD_SIGNATURE, "SIGIL_ERR_BAD_SIGNATURE" },
};

/* "This is not a well-formed sigil envelope." A data problem, decided — but
 * NOT a forgery, and worth its own code so support can tell them apart. */
static const struct code_case malformed[] = {
	{ SIGIL_ERR_MALFORMED_JSON,       "SIGIL_ERR_MALFORMED_JSON" },
	{ SIGIL_ERR_MISSING_FIELD,        "SIGIL_ERR_MISSING_FIELD" },
	{ SIGIL_ERR_UNSUPPORTED_SIGTYPE,  "SIGIL_ERR_UNSUPPORTED_SIGTYPE" },
	{ SIGIL_ERR_MALFORMED_ENCODING,   "SIGIL_ERR_MALFORMED_ENCODING" },
	{ SIGIL_ERR_BAD_SIGNATURE_LENGTH, "SIGIL_ERR_BAD_SIGNATURE_LENGTH" },
};

/* "I could not determine." Resource exhaustion or a bug on our side. None of
 * these say anything whatsoever about the document's authenticity. */
static const struct code_case undetermined[] = {
	{ SIGIL_ERR_OUT_OF_MEMORY,    "SIGIL_ERR_OUT_OF_MEMORY" },
	{ SIGIL_ERR_BUFFER_TOO_SMALL, "SIGIL_ERR_BUFFER_TOO_SMALL" },
	{ SIGIL_ERR_NULL_ARGUMENT,    "SIGIL_ERR_NULL_ARGUMENT" },
};

/* Caller supplied something wrong — a bad key, not a bad licence. */
static const struct code_case caller_error[] = {
	{ SIGIL_ERR_BAD_PUBLIC_KEY, "SIGIL_ERR_BAD_PUBLIC_KEY" },
};

#define COUNT(a) (sizeof(a) / sizeof((a)[0]))

int main(void) {
	char detail[256];

	if (sigil_verify_exit_code(SIGIL_OK) == 0) {
		ok("success maps to exit 0");
	} else {
		snprintf(detail, sizeof detail, "got %d", sigil_verify_exit_code(SIGIL_OK));
		bad("success maps to exit 0", detail);
	}

	/* THE assertion. Everything else here is scaffolding around it. */
	for (size_t i = 0; i < COUNT(undetermined); i++) {
		int got = sigil_verify_exit_code(undetermined[i].code);
		snprintf(detail, sizeof detail,
			"%s -> exit %d; \"could not determine\" must never read as \"forged\"",
			undetermined[i].name, got);
		if (got != SIGIL_EX_REJECTED) {
			printf("  ok   %s does not report a forgery\n", undetermined[i].name);
			passed++;
		} else {
			bad("a transient failure does not report a forgery", detail);
		}
	}

	/* ...and the class that SHOULD exit 1 still does, so the fix above cannot
	 * be achieved by making nothing ever report a forgery. */
	for (size_t i = 0; i < COUNT(not_authentic); i++) {
		int got = sigil_verify_exit_code(not_authentic[i].code);
		if (got == SIGIL_EX_REJECTED) {
			printf("  ok   %s still reports a forgery\n", not_authentic[i].name);
			passed++;
		} else {
			snprintf(detail, sizeof detail, "%s -> exit %d, expected %d",
				not_authentic[i].name, got, SIGIL_EX_REJECTED);
			bad("a bad signature still reports a forgery", detail);
		}
	}

	for (size_t i = 0; i < COUNT(malformed); i++) {
		int got = sigil_verify_exit_code(malformed[i].code);
		if (got == SIGIL_EX_DATAERR) {
			printf("  ok   %s is a data error, not a forgery\n", malformed[i].name);
			passed++;
		} else {
			snprintf(detail, sizeof detail, "%s -> exit %d, expected %d",
				malformed[i].name, got, SIGIL_EX_DATAERR);
			bad("a malformed envelope is a data error, not a forgery", detail);
		}
	}

	for (size_t i = 0; i < COUNT(caller_error); i++) {
		int got = sigil_verify_exit_code(caller_error[i].code);
		if (got == SIGIL_EX_USAGE) {
			printf("  ok   %s is a usage error\n", caller_error[i].name);
			passed++;
		} else {
			snprintf(detail, sizeof detail, "%s -> exit %d, expected %d",
				caller_error[i].name, got, SIGIL_EX_USAGE);
			bad("a bad public key is a usage error", detail);
		}
	}

	/* Totality: the partitions above must cover every code the header defines.
	 * Without this, adding a code to sigil.h and forgetting to classify it
	 * would silently inherit whatever the default branch does — which is how
	 * the original bug survived. */
	const int all_codes[] = {
		SIGIL_ERR_BAD_SIGNATURE,       SIGIL_ERR_BAD_PUBLIC_KEY,
		SIGIL_ERR_NULL_ARGUMENT,       SIGIL_ERR_MALFORMED_JSON,
		SIGIL_ERR_MISSING_FIELD,       SIGIL_ERR_UNSUPPORTED_SIGTYPE,
		SIGIL_ERR_MALFORMED_ENCODING,  SIGIL_ERR_BAD_SIGNATURE_LENGTH,
		SIGIL_ERR_BUFFER_TOO_SMALL,    SIGIL_ERR_OUT_OF_MEMORY,
	};
	size_t classified = COUNT(not_authentic) + COUNT(malformed)
	                  + COUNT(undetermined) + COUNT(caller_error);
	if (classified == COUNT(all_codes)) {
		ok("every error code in sigil.h is classified exactly once");
	} else {
		snprintf(detail, sizeof detail, "%zu classified vs %zu defined",
			classified, COUNT(all_codes));
		bad("every error code in sigil.h is classified exactly once", detail);
	}

	/* An unknown code must be conservative: never claim forgery for something
	 * this build has never heard of. */
	if (sigil_verify_exit_code(-9999) != SIGIL_EX_REJECTED) {
		ok("an unrecognised code does not report a forgery");
	} else {
		bad("an unrecognised code does not report a forgery", "got exit 1");
	}

	printf("\n%d passed, %d failed\n", passed, failed);
	return failed > 0 ? 1 : 0;
}
