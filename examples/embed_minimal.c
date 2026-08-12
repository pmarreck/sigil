/* The smallest useful sigil embedder: verify a license, print its payload.
 *
 * This is the exact call sequence a product (Mecha Validate's GUI, RotShield)
 * makes at startup. Everything a consumer links is libsigil.a + sigil.h —
 * verification only; the signing symbols do not exist in that library, so a
 * shipped binary cannot mint a license even by accident.
 *
 *   cc -o embed_minimal embed_minimal.c -I../include -L../zig-out/lib -lsigil
 *   ./embed_minimal demo/license.sigil demo/demo.key.pub
 *
 * In a real product the public key is EMBEDDED (see `sigil pubkey --format c`)
 * rather than read from a file — a key loaded from a user-writable path lets
 * anyone substitute their own. It is a file here only so the example runs
 * against the demo fixtures without editing.
 *
 * The payload comes back ONLY after the signature verifies — there is no API
 * to get unverified bytes — so parsing it (JSON, TOML, whatever the issuer
 * chose) is safe by construction. Exit codes: 0 verified, 1 not authentic,
 * 2 usage/IO.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sigil.h"

static char *slurp(const char *path, size_t *len_out) {
	FILE *f = fopen(path, "rb");
	if (!f) return NULL;
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	if (n < 0) { fclose(f); return NULL; }
	char *buf = malloc((size_t)n + 1);
	if (!buf) { fclose(f); return NULL; }
	if (fread(buf, 1, (size_t)n, f) != (size_t)n) { fclose(f); free(buf); return NULL; }
	fclose(f);
	buf[n] = '\0';
	*len_out = (size_t)n;
	return buf;
}

int main(int argc, char **argv) {
	if (argc != 3) {
		fprintf(stderr, "usage: %s <license.sigil> <key.pub>\n", argv[0]);
		return 2;
	}

	size_t env_len = 0, pub_len = 0;
	char *envelope = slurp(argv[1], &env_len);
	char *pub_text = slurp(argv[2], &pub_len);
	if (!envelope || !pub_text) {
		fprintf(stderr, "could not read input files\n");
		return 2;
	}

	unsigned char public_key[32];
	int rc = sigil_public_key_from_text(pub_text, pub_len, public_key);
	if (rc != SIGIL_OK) {
		fprintf(stderr, "bad public key: %s\n", sigil_strerror(rc));
		return 2;
	}

	/* printable-binary only ever expands, so envelope_len always suffices. */
	unsigned char *payload = malloc(env_len);
	size_t payload_len = 0;
	rc = sigil_verify_envelope(envelope, env_len, public_key,
	                           payload, env_len, &payload_len);
	if (rc != SIGIL_OK) {
		fprintf(stderr, "NOT AUTHENTIC: %s\n", sigil_strerror(rc));
		return 1;
	}

	/* Only now are these bytes trustworthy. */
	fwrite(payload, 1, payload_len, stdout);
	fputc('\n', stdout);

	free(payload);
	free(envelope);
	free(pub_text);
	return 0;
}
