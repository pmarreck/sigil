#ifndef SIGIL_SIGN_H
#define SIGIL_SIGN_H

#include <stddef.h>

/* sigil signing — mint keys and licenses.
 *
 * THIS HEADER IS NOT FOR PRODUCTS. It declares the contents of
 * libsigil_sign.a, which only the `sigil` CLI links. Mecha Validate and Mecha
 * Rotshield link libsigil.a and contain none of these symbols, so a shipped
 * binary cannot mint a license. tests/test_no_signing_symbols enforces that
 * with nm rather than trusting this comment.
 *
 * Note what is absent: nothing here returns a secret key or a seed. Signing
 * takes a keyfile plus a passphrase and returns a finished envelope, so key
 * material never becomes a buffer a caller could log, swap out, or write to
 * the wrong path.
 */

#ifdef __cplusplus
extern "C" {
#endif

/* Shared with sigil.h. */
#define SIGIL_OK                        0
#define SIGIL_ERR_NULL_ARGUMENT        -3
#define SIGIL_ERR_BUFFER_TOO_SMALL     -9
#define SIGIL_ERR_OUT_OF_MEMORY       -10

/* Signing-side codes continue the same numbering from -20, so a code never
 * means two different things depending on which library returned it. */
#define SIGIL_ERR_MALFORMED_KEYFILE   -20
#define SIGIL_ERR_UNSUPPORTED_KEYFILE -21
#define SIGIL_ERR_AUTH_FAILED         -22
#define SIGIL_ERR_BAD_KDF_PARAMS      -23
#define SIGIL_ERR_BAD_SEED            -24
#define SIGIL_ERR_EMPTY_PASSPHRASE    -25
#define SIGIL_ERR_NO_ENTROPY          -26

/* Generate a fresh key and write the passphrase-encrypted keyfile text into
 * `out`. The seed is drawn from the OS entropy source, used, and wiped; it is
 * never visible to the caller. Losing the keyfile or the passphrase means
 * losing the ability to sign — back both up.
 *
 * On SIGIL_ERR_BUFFER_TOO_SMALL, *out_len is the capacity required. */
int sigil_keygen(const char *passphrase,
                 size_t passphrase_len,
                 char *out,
                 size_t out_cap,
                 size_t *out_len);

/* Sign `payload` with the key in `keyfile` and write a finished envelope into
 * `out`. One call on purpose: unwrapping and signing separately would mean a
 * seed crossing this boundary. */
int sigil_seal(const char *keyfile,
               size_t keyfile_len,
               const char *passphrase,
               size_t passphrase_len,
               const unsigned char *payload,
               size_t payload_len,
               char *out,
               size_t out_cap,
               size_t *out_len);

/* Derive the public key from a keyfile. REQUIRES the passphrase: the key is
 * computed from the decrypted seed, not read from a stored field.
 *
 * It used to need no passphrase and read a `public` value out of the file.
 * That made the key a developer embeds in a shipped product attacker-
 * controlled — anyone who could write the keyfile chose what got printed. The
 * field is gone, so there is nothing left to splice.
 * `public_key_out` needs sigil_public_key_len() bytes. */
int sigil_keyfile_public_key(const char *keyfile,
                             size_t keyfile_len,
                             const char *passphrase,
                             size_t passphrase_len,
                             unsigned char *public_key_out);

/* Human-readable name for a code returned by this library. Never NULL. */
const char *sigil_sign_strerror(int code);

#ifdef __cplusplus
}
#endif

#endif /* SIGIL_SIGN_H */
