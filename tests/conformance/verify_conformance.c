/* Conformance consumer for sigil_verify — the raw Ed25519-over-transcript
 * primitive.
 *
 * Why this file exists, twice over:
 *
 * 1. `sigil_verify` had NO C consumer. cli/main.c calls only
 *    sigil_verify_envelope, so the primitive shipped to customers was never
 *    exercised by our own dogfooding. An FFI export with no consumer is an
 *    untested export wearing a tested one's clothes.
 *
 * 2. It is built with STOCK `cc`, never `zig cc`. That is the point, not an
 *    implementation detail. `zig build` silently supplies compiler-rt and links
 *    the Zig way, so it cannot notice when libsigil.a becomes unlinkable by a
 *    customer's toolchain — which it was, for two independent reasons (a
 *    non-PIC archive against default-PIE gcc, and unresolved 128-bit soft-float
 *    symbols dragged in by std.json's number parser). Both were invisible to
 *    every test we had. This binary makes the customer's link path a gate.
 *
 * Two oracles, deliberately different in kind:
 *
 * - RFC 8032 §7.1 TEST 1, an oracle written by the IETF. Since 2026-08-11
 *   sigil signs a TRANSCRIPT, so this valid-per-the-standard raw signature
 *   must now be REJECTED — the check pins domain separation: no other Ed25519
 *   protocol's signature (SSH, JWT, pre-transcript sigil) is valid here. The
 *   Zig suite asserts the same property from the other side.
 * - A triple produced by sigil's own signer (the committed demo fixtures),
 *   which must VERIFY. This restores the sensitivity the RFC vector used to
 *   provide; without it, every rejection check below would pass against a
 *   verifier that rejects everything.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "sigil.h"

static int failures = 0;

static void check(int cond, const char *what) {
	if (cond) {
		printf("  ok   %s\n", what);
	} else {
		printf("  FAIL %s\n", what);
		failures++;
	}
}

/* Decode `hex` into `out`; returns 0 on success. */
static int unhex(const char *hex, unsigned char *out, size_t out_len) {
	if (strlen(hex) != out_len * 2) return -1;
	for (size_t i = 0; i < out_len; i++) {
		unsigned int byte;
		if (sscanf(hex + i * 2, "%2x", &byte) != 1) return -1;
		out[i] = (unsigned char)byte;
	}
	return 0;
}

static unsigned char *slurp(const char *path, size_t *len_out) {
	FILE *f = fopen(path, "rb");
	if (!f) return NULL;
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	if (n < 0) { fclose(f); return NULL; }
	unsigned char *buf = malloc((size_t)n ? (size_t)n : 1);
	if (!buf) { fclose(f); return NULL; }
	if (fread(buf, 1, (size_t)n, f) != (size_t)n) { fclose(f); free(buf); return NULL; }
	fclose(f);
	*len_out = (size_t)n;
	return buf;
}

int main(int argc, char **argv) {
	/* RFC 8032 §7.1, TEST 1: empty message. */
	static const char *PK_HEX =
		"d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";
	static const char *SIG_HEX =
		"e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
		"5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b";

	unsigned char rfc_pk[32], rfc_sig[64];

	if (argc != 4) {
		fprintf(stderr, "usage: %s <payload.bin> <sig.bin> <pubkey.bin>\n", argv[0]);
		fprintf(stderr, "       (the sigil-signed demo fixture triple)\n");
		return 1;
	}

	printf("sigil_verify conformance (stock cc)\n");

	check(sigil_public_key_len() == 32, "public key length is 32");
	check(sigil_signature_len() == 64, "signature length is 64");

	if (unhex(PK_HEX, rfc_pk, sizeof rfc_pk) != 0 ||
	    unhex(SIG_HEX, rfc_sig, sizeof rfc_sig) != 0) {
		printf("  FAIL could not decode the RFC vectors\n");
		return 1;
	}

	/* --- Domain separation: a signature that IS valid per RFC 8032 over the
	 *     raw message must NOT be a valid sigil signature, because sigil signs
	 *     the transcript. This is the property that stops any other Ed25519
	 *     protocol's output from being replayed into a license. --- */
	check(sigil_verify((const unsigned char *)"", 0, rfc_sig, rfc_pk) != SIGIL_OK,
	      "a valid RFC 8032 raw signature is rejected (domain separation)");

	/* --- The sigil-signed fixture triple. --- */
	size_t payload_len = 0, sig_len = 0, pk_len = 0;
	unsigned char *payload = slurp(argv[1], &payload_len);
	unsigned char *fix_sig = slurp(argv[2], &sig_len);
	unsigned char *fix_pk = slurp(argv[3], &pk_len);
	if (!payload || !fix_sig || sig_len != 64 || !fix_pk || pk_len != 32) {
		printf("  FAIL could not load the fixture triple (sig %zu, pk %zu)\n",
		       sig_len, pk_len);
		return failures + 1;
	}

	/* --- Sensitivity: sigil's own signature must verify. Every rejection
	 *     below is meaningful only because this one passes. --- */
	check(sigil_verify(payload, payload_len, fix_sig, fix_pk) == SIGIL_OK,
	      "the sigil-signed fixture verifies");

	/* --- Specificity: every corruption must be REJECTED. --- */
	{
		unsigned char bad[64];
		memcpy(bad, fix_sig, sizeof bad);
		bad[0] ^= 0x01;
		check(sigil_verify(payload, payload_len, bad, fix_pk) != SIGIL_OK,
		      "a signature with one flipped bit is rejected");

		memcpy(bad, fix_sig, sizeof bad);
		bad[63] ^= 0x80; /* high bit of s — the canonical-scalar boundary */
		check(sigil_verify(payload, payload_len, bad, fix_pk) != SIGIL_OK,
		      "a signature with a corrupted scalar is rejected");
	}
	{
		unsigned char badpk[32];
		memcpy(badpk, fix_pk, sizeof badpk);
		badpk[0] ^= 0x01;
		check(sigil_verify(payload, payload_len, fix_sig, badpk) != SIGIL_OK,
		      "the wrong public key is rejected");

		memset(badpk, 0, sizeof badpk);
		check(sigil_verify(payload, payload_len, fix_sig, badpk) != SIGIL_OK,
		      "an all-zero public key is rejected (a realistic embedder accident)");
	}
	{
		unsigned char *tampered = malloc(payload_len);
		memcpy(tampered, payload, payload_len);
		tampered[0] ^= 0x01;
		check(sigil_verify(tampered, payload_len, fix_sig, fix_pk) != SIGIL_OK,
		      "a payload with one flipped bit is rejected");
		free(tampered);
	}
	check(sigil_verify((const unsigned char *)"x", 1, fix_sig, fix_pk) != SIGIL_OK,
	      "a different message is rejected");

	/* --- NULL handling: the header promises only NULL is an argument error. --- */
	check(sigil_verify(NULL, 0, fix_sig, fix_pk) == SIGIL_ERR_NULL_ARGUMENT,
	      "NULL payload is an argument error, not a crash");
	check(sigil_verify((const unsigned char *)"", 0, NULL, fix_pk) == SIGIL_ERR_NULL_ARGUMENT,
	      "NULL signature is an argument error");
	check(sigil_verify((const unsigned char *)"", 0, fix_sig, NULL) == SIGIL_ERR_NULL_ARGUMENT,
	      "NULL public key is an argument error");

	free(payload);
	free(fix_sig);
	free(fix_pk);

	printf("\n%s\n", failures ? "FAILED" : "all conformance checks passed");
	return failures;
}
