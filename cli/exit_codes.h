#ifndef SIGIL_CLI_EXIT_CODES_H
#define SIGIL_CLI_EXIT_CODES_H

#include "sigil.h"

/* Turning an FFI result into a process exit code.
 *
 * Header-only and pure so it can be tested directly. It used to be a single
 * `status = EX_REJECTED;` covering every failure, which meant a customer whose
 * machine was briefly out of memory was told their valid, paid-for license was
 * a forgery. Transient resource failure and cryptographic rejection are
 * different KINDS of event and must not share an exit path.
 *
 * The rule: anything meaning "I could not determine" must never render as
 * "I determined it is invalid."
 *
 * sysexits.h conventions, so scripts can branch on them:
 *   0  verified
 *   1  the document is not authentic — the signature does not check out
 *   64 usage: the caller passed something wrong (a bad public key)
 *   65 data: the input is not a well-formed sigil envelope
 *   70 internal: a bug on our side
 *   75 temporary: retry may succeed (out of memory)
 */

#define SIGIL_EX_OK        0
#define SIGIL_EX_REJECTED  1
#define SIGIL_EX_USAGE     64
#define SIGIL_EX_DATAERR   65
#define SIGIL_EX_SOFTWARE  70
#define SIGIL_EX_TEMPFAIL  75

static inline int sigil_verify_exit_code(int ffi_code) {
	switch (ffi_code) {
	case SIGIL_OK:
		return SIGIL_EX_OK;

	/* The only result that means "this document is not authentic". */
	case SIGIL_ERR_BAD_SIGNATURE:
		return SIGIL_EX_REJECTED;

	/* Decided, but a format problem rather than a forgery. Support needs to
	 * tell "you sent me a screenshot" apart from "someone edited your
	 * license", and so does anyone reading a CI log. */
	case SIGIL_ERR_MALFORMED_JSON:
	case SIGIL_ERR_MISSING_FIELD:
	case SIGIL_ERR_UNSUPPORTED_SIGTYPE:
	case SIGIL_ERR_MALFORMED_ENCODING:
	case SIGIL_ERR_BAD_SIGNATURE_LENGTH:
		return SIGIL_EX_DATAERR;

	/* The caller handed us something wrong. Not the document's fault. */
	case SIGIL_ERR_BAD_PUBLIC_KEY:
		return SIGIL_EX_USAGE;

	/* Transient. The license may well be perfectly good; we could not tell.
	 * Retrying is a reasonable thing for a caller to do. */
	case SIGIL_ERR_OUT_OF_MEMORY:
		return SIGIL_EX_TEMPFAIL;

	/* Our bug: the CLI sizes this buffer itself and passes non-NULL. */
	case SIGIL_ERR_BUFFER_TOO_SMALL:
	case SIGIL_ERR_NULL_ARGUMENT:
		return SIGIL_EX_SOFTWARE;

	/* A code from a newer libsigil than this CLI knows about. Be conservative:
	 * never accuse a document of forgery on the strength of a result we do not
	 * understand. */
	default:
		return SIGIL_EX_SOFTWARE;
	}
}

#endif /* SIGIL_CLI_EXIT_CODES_H */
