#ifndef SIGIL_H
#define SIGIL_H

#include <stddef.h>

/* sigil — verify Ed25519-signed documents.
 *
 * INVARIANT: the signature covers the payload bytes EXACTLY as supplied. sigil
 * never canonicalizes or re-serializes, which is why a JSON envelope carrying
 * these bytes may be reformatted freely without breaking verification.
 *
 * Verify BEFORE parsing. Never interpret bytes you have not authenticated.
 *
 * Envelope (transport only, never signed):
 *   {"data":"<printable-binary of payload>","sigtype":"Ed25519",
 *    "sig":"<printable-binary of the raw 64-byte signature>"}
 *
 * No function here allocates on the caller's behalf or traps; every failure is
 * a negative return code, because an FFI boundary that panics takes the host
 * application down with it.
 */

#ifdef __cplusplus
extern "C" {
#endif

#define SIGIL_OK                       0
#define SIGIL_ERR_BAD_SIGNATURE       -1
#define SIGIL_ERR_BAD_PUBLIC_KEY      -2
#define SIGIL_ERR_NULL_ARGUMENT       -3
#define SIGIL_ERR_MALFORMED_JSON      -4
#define SIGIL_ERR_MISSING_FIELD       -5
#define SIGIL_ERR_UNSUPPORTED_SIGTYPE -6
#define SIGIL_ERR_MALFORMED_ENCODING  -7
#define SIGIL_ERR_BAD_SIGNATURE_LENGTH -8
#define SIGIL_ERR_BUFFER_TOO_SMALL    -9
#define SIGIL_ERR_OUT_OF_MEMORY      -10

/* Verify a detached signature over raw bytes. Returns SIGIL_OK (0) on success,
 * negative otherwise. `sig` must be sigil_signature_len() bytes and
 * `public_key` must be sigil_public_key_len() bytes. A zero-length payload is
 * legal; only NULL is an argument error. */
int sigil_verify(const unsigned char *payload,
                 size_t payload_len,
                 const unsigned char *sig,
                 const unsigned char *public_key);

/* Verify a JSON envelope and copy the AUTHENTICATED payload into `payload_out`.
 *
 * There is no way to obtain payload bytes from this API without them having
 * verified first — that is how "verify before parsing" is enforced against
 * callers who never read this comment.
 *
 * On SIGIL_OK, *payload_len_out is the payload length. On
 * SIGIL_ERR_BUFFER_TOO_SMALL it is the capacity required and `payload_out` is
 * left untouched. printable-binary only ever expands, so a buffer of
 * `envelope_len` bytes always suffices and a caller may size it in one pass. */
int sigil_verify_envelope(const char *envelope,
                          size_t envelope_len,
                          const unsigned char *public_key,
                          unsigned char *payload_out,
                          size_t payload_out_cap,
                          size_t *payload_len_out);

/* Human-readable name for any code above. Never NULL, so it can be spliced
 * straight into an error message without a null check. */
const char *sigil_strerror(int code);

const char *sigil_version(void);
size_t sigil_signature_len(void);
size_t sigil_public_key_len(void);

#ifdef __cplusplus
}
#endif

#endif /* SIGIL_H */
