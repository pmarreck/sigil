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
 */

#define SIGIL_OK                  0
#define SIGIL_ERR_BAD_SIGNATURE  -1
#define SIGIL_ERR_BAD_PUBLIC_KEY -2
#define SIGIL_ERR_NULL_ARGUMENT  -3

/* Verify a detached signature. Returns SIGIL_OK (0) on success, negative
 * otherwise. `sig` must be sigil_signature_len() bytes and `public_key` must be
 * sigil_public_key_len() bytes. A zero-length payload is legal. */
int sigil_verify(const unsigned char *payload,
                 size_t payload_len,
                 const unsigned char *sig,
                 const unsigned char *public_key);

const char *sigil_version(void);
size_t sigil_signature_len(void);
size_t sigil_public_key_len(void);

#endif /* SIGIL_H */
