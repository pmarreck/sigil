#ifndef SIGIL_H
#define SIGIL_H

#include <stddef.h>

/* sigil — verify Ed25519-signed documents.
 *
 * INVARIANT: the payload bytes are signed EXACTLY as supplied — never
 * canonicalized or re-serialized — which is why a JSON envelope carrying them
 * may be reformatted freely without breaking verification. The signature
 * covers the signing transcript: the fixed header
 * "sigil.transcript.v1" || u8(alg=1) || u64be(payload_len), then those verbatim
 * bytes. Verification here builds the transcript internally; callers pass the
 * payload alone. A signature over the bare payload (any other Ed25519
 * protocol's output) is NOT valid.
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

/* Render a public key as the one-line text form used by `.pub` files (a
 * "sigil-pubkey-v1 " prefix followed by the printable-binary value). On
 * SIGIL_ERR_BUFFER_TOO_SMALL, *out_len is the capacity required. */
int sigil_public_key_to_text(const unsigned char *public_key,
                             char *out,
                             size_t out_cap,
                             size_t *out_len);

/* Parse a public-key file body. `public_key_out` needs sigil_public_key_len()
 * bytes. Surrounding whitespace and a missing prefix are tolerated; anything
 * that is not exactly a key is refused rather than truncated into one. */
int sigil_public_key_from_text(const char *text,
                               size_t text_len,
                               unsigned char *public_key_out);

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
