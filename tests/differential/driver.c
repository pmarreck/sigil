/* Differential driver: one source, compiled once per sigil implementation.
 *
 * Both implementations export the same symbols, so they cannot share a
 * process. Each build of this driver prints a deterministic record of what
 * its library answers; tests/differential/run compares the two records byte
 * for byte. Any difference is a divergence between the implementations.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
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

/* NULL handling is part of the ABI: each pointer argument is refused on its
 * own, and a zero-length payload is legal only when its pointer is not NULL. */
static int cmd_verify_null(void) {
	unsigned char byte = 0;
	unsigned char sig[64] = {0};
	unsigned char key[32] = {0};
	printf("verify(NULL payload, len 0)=%d\n", sigil_verify(NULL, 0, sig, key));
	printf("verify(NULL payload, len 1)=%d\n", sigil_verify(NULL, 1, sig, key));
	printf("verify(NULL sig)=%d\n", sigil_verify(&byte, 1, NULL, key));
	printf("verify(NULL key)=%d\n", sigil_verify(&byte, 1, sig, NULL));
	printf("verify(all NULL)=%d\n", sigil_verify(NULL, 0, NULL, NULL));
	return 0;
}

static int hex_value(char c) {
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	return -1;
}

/* Decode lowercase hex of exactly `want` bytes (or any length when want is
 * 0) into a newly allocated buffer. Returns NULL on malformed input. */
static unsigned char *hex_decode(const char *hex, size_t want, size_t *len_out) {
	size_t digits = strlen(hex);
	if (digits % 2 != 0) return NULL;
	size_t len = digits / 2;
	if (want != 0 && len != want) return NULL;
	unsigned char *out = malloc(len + 1); /* +1 so a zero-length buffer is non-NULL */
	if (out == NULL) return NULL;
	for (size_t i = 0; i < len; i++) {
		int hi = hex_value(hex[2 * i]);
		int lo = hex_value(hex[2 * i + 1]);
		if (hi < 0 || lo < 0) {
			free(out);
			return NULL;
		}
		out[i] = (unsigned char)(hi << 4 | lo);
	}
	*len_out = len;
	return out;
}

/* Run sigil_verify over a corpus of tab-separated cases:
 * name, expected code, expected name, payload, signature, public key (hex).
 * Prints "name<TAB>code" per case; the caller compares. */
static int cmd_verify_cases(const char *path) {
	FILE *in = fopen(path, "r");
	if (in == NULL) {
		perror(path);
		return 66;
	}
	char line[8192];
	int status = 0;
	while (fgets(line, sizeof line, in) != NULL) {
		if (line[0] == '#' || line[0] == '\n') continue;
		line[strcspn(line, "\n")] = '\0';
		char *fields[6];
		int n = 0;
		for (char *cursor = line; n < 6; n++) {
			fields[n] = cursor;
			char *tab = strchr(cursor, '\t');
			if (tab == NULL) {
				n++;
				break;
			}
			*tab = '\0';
			cursor = tab + 1;
		}
		if (n != 6) {
			fprintf(stderr, "malformed case line: %s\n", fields[0]);
			status = 65;
			break;
		}
		size_t payload_len = 0, sig_len = 0, key_len = 0;
		unsigned char *payload = hex_decode(fields[3], 0, &payload_len);
		unsigned char *sig = hex_decode(fields[4], 64, &sig_len);
		unsigned char *key = hex_decode(fields[5], 32, &key_len);
		if (payload == NULL || sig == NULL || key == NULL) {
			fprintf(stderr, "malformed hex in case %s\n", fields[0]);
			status = 65;
		} else {
			printf("%s\t%d\n", fields[0], sigil_verify(payload, payload_len, sig, key));
		}
		free(payload);
		free(sig);
		free(key);
		if (status != 0) break;
	}
	if (fclose(in) != 0 && status == 0) status = 74;
	return status;
}

/* Read a whole file into a new buffer. */
static unsigned char *slurp(const char *path, size_t *len_out) {
	FILE *in = fopen(path, "rb");
	if (in == NULL) return NULL;
	size_t cap = 4096, len = 0;
	unsigned char *buf = malloc(cap);
	while (buf != NULL) {
		size_t got = fread(buf + len, 1, cap - len, in);
		len += got;
		if (len < cap) break;
		unsigned char *grown = realloc(buf, cap * 2);
		if (grown == NULL) {
			free(buf);
			buf = NULL;
			break;
		}
		buf = grown;
		cap *= 2;
	}
	if (ferror(in) && buf != NULL) {
		free(buf);
		buf = NULL;
	}
	if (fclose(in) != 0 && buf != NULL) {
		free(buf);
		buf = NULL;
	}
	*len_out = len;
	return buf;
}

/* FNV-1a, enough to compare payloads without printing them. */
static uint64_t fnv1a(const unsigned char *p, size_t n) {
	uint64_t h = 0xcbf29ce484222325ULL;
	for (size_t i = 0; i < n; i++) {
		h ^= p[i];
		h *= 0x100000001b3ULL;
	}
	return h;
}

static void print_hex(const unsigned char *p, size_t n) {
	for (size_t i = 0; i < n; i++) printf("%02x", p[i]);
}

/* One verdict record for an envelope: code, payload length and hash. The
 * output buffer is sized to the envelope, which the header promises suffices. */
static void envelope_record(const unsigned char *env, size_t env_len, const unsigned char *key) {
	unsigned char *out = malloc(env_len + 1);
	size_t out_len = (size_t)-1;
	int rc = sigil_verify_envelope((const char *)env, env_len, key, out, env_len, &out_len);
	printf("%d %zu %016llx\n", rc, rc == SIGIL_OK ? out_len : 0,
		rc == SIGIL_OK ? (unsigned long long)fnv1a(out, out_len) : 0ULL);
	free(out);
}

static int load_key(const char *path, unsigned char key[32]) {
	size_t text_len = 0;
	unsigned char *text = slurp(path, &text_len);
	if (text == NULL) {
		perror(path);
		return 66;
	}
	int rc = sigil_public_key_from_text((const char *)text, text_len, key);
	free(text);
	if (rc != SIGIL_OK) {
		fprintf(stderr, "%s: key text refused (%d)\n", path, rc);
		return 65;
	}
	return 0;
}

/* Verify one envelope file under one key file, then probe the output-buffer
 * contract: NULL pointers, a zero-capacity query and a one-short buffer. */
static int cmd_envelope(const char *env_path, const char *key_path) {
	unsigned char key[32];
	int rc = load_key(key_path, key);
	if (rc != 0) return rc;
	size_t env_len = 0;
	unsigned char *env = slurp(env_path, &env_len);
	if (env == NULL) {
		perror(env_path);
		return 66;
	}
	envelope_record(env, env_len, key);
	unsigned char small[1];
	size_t got = 0;
	printf("  null envelope %d\n", sigil_verify_envelope(NULL, env_len, key, small, 1, &got));
	printf("  null key %d\n", sigil_verify_envelope((const char *)env, env_len, NULL, small, 1, &got));
	printf("  null length %d\n", sigil_verify_envelope((const char *)env, env_len, key, small, 1, NULL));
	printf("  null out, cap 1 %d\n", sigil_verify_envelope((const char *)env, env_len, key, NULL, 1, &got));
	got = (size_t)-1;
	int q = sigil_verify_envelope((const char *)env, env_len, key, NULL, 0, &got);
	printf("  capacity query %d %zu\n", q, q == SIGIL_OK || q == SIGIL_ERR_BUFFER_TOO_SMALL ? got : 0);
	if (q == SIGIL_ERR_BUFFER_TOO_SMALL && got > 0) {
		size_t need = got;
		unsigned char *short_buf = malloc(need);
		memset(short_buf, 0xa5, need);
		int s = sigil_verify_envelope((const char *)env, env_len, key, short_buf, need - 1, &got);
		size_t untouched = 0;
		for (size_t i = 0; i < need; i++) untouched += short_buf[i] == 0xa5;
		printf("  one short %d %zu untouched=%zu\n", s, got, untouched);
		free(short_buf);
	}
	free(env);
	return 0;
}

/* Public-key text over keys covering every byte value, with the
 * output-buffer contract probed on each. */
static int cmd_pubkey_sweep(void) {
	for (int start = 0; start < 256; start += 32) {
		unsigned char key[32];
		for (int i = 0; i < 32; i++) key[i] = (unsigned char)(start + i);
		char text[256];
		size_t len = 0;
		int rc = sigil_public_key_to_text(key, text, sizeof text, &len);
		printf("to_text %d %zu ", rc, len);
		print_hex((const unsigned char *)text, rc == SIGIL_OK ? len : 0);
		printf("\n");
		size_t q = 0;
		printf("  query %d", sigil_public_key_to_text(key, NULL, 0, &q));
		printf(" %zu\n", q);
		printf("  null out, cap %zu %d\n", sizeof text, sigil_public_key_to_text(key, NULL, sizeof text, &q));
		printf("  one short %d\n", sigil_public_key_to_text(key, text, len - 1, &q));
		printf("  null key %d\n", sigil_public_key_to_text(NULL, text, sizeof text, &q));
		printf("  null length %d\n", sigil_public_key_to_text(key, text, sizeof text, NULL));
		unsigned char back[32];
		int b = sigil_public_key_from_text(text, len, back);
		printf("  from_text %d %d\n", b, b == SIGIL_OK && memcmp(back, key, 32) == 0);
	}
	unsigned char back[32];
	printf("from_text null text %d\n", sigil_public_key_from_text(NULL, 0, back));
	printf("from_text null out %d\n", sigil_public_key_from_text("x", 1, NULL));
	return 0;
}

/* splitmix64: a fixed, portable generator so both drivers see identical
 * mutations for the same seed. */
static uint64_t rng_state;
static uint64_t rng_next(void) {
	uint64_t z = (rng_state += 0x9e3779b97f4a7c15ULL);
	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
	z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
	return z ^ (z >> 31);
}
static size_t rng_below(size_t n) { return n == 0 ? 0 : (size_t)(rng_next() % n); }

/* Bytes chosen to hit the parser and decoder edges: JSON structure, transport
 * noise, UTF-8 leads and continuations, and ordinary glyph ASCII. */
static const unsigned char interesting[] = {
	'"', ':', ',', '{', '}', ' ', '\n', '\t', '\\', '>', 0x00, 0x7f,
	0x80, 0x82, 0xa2, 0xbf, 0xc0, 0xc2, 0xc3, 0xdf, 0xe0, 0xe2, 0xea, 0xed,
	0xef, 0xf0, 0xf4, 0xff, 'a', 'A', '0', '.', '@', '^', '_', 'd',
};

/* Apply one to three mutations to `buf` (length *len, capacity cap). */
static void mutate(unsigned char *buf, size_t *len, size_t cap) {
	int rounds = 1 + (int)rng_below(3);
	for (int r = 0; r < rounds; r++) {
		size_t n = *len;
		switch (rng_below(7)) {
		case 0: /* flip a bit */
			if (n > 0) buf[rng_below(n)] ^= (unsigned char)(1u << rng_below(8));
			break;
		case 1: /* overwrite with an interesting byte */
			if (n > 0) buf[rng_below(n)] = interesting[rng_below(sizeof interesting)];
			break;
		case 2: /* insert an interesting byte */
			if (n < cap) {
				size_t at = rng_below(n + 1);
				memmove(buf + at + 1, buf + at, n - at);
				buf[at] = interesting[rng_below(sizeof interesting)];
				*len = n + 1;
			}
			break;
		case 3: /* delete a byte */
			if (n > 0) {
				size_t at = rng_below(n);
				memmove(buf + at, buf + at + 1, n - at - 1);
				*len = n - 1;
			}
			break;
		case 4: /* truncate */
			*len = rng_below(n + 1);
			break;
		case 5: /* copy a short span elsewhere, duplicating fields or glyphs */
			if (n > 0) {
				size_t from = rng_below(n);
				size_t span = 1 + rng_below(n - from < 24 ? n - from : 24);
				if (n + span <= cap) {
					size_t at = rng_below(n + 1);
					unsigned char tmp[24];
					memcpy(tmp, buf + from, span);
					memmove(buf + at + span, buf + at, n - at);
					memcpy(buf + at, tmp, span);
					*len = n + span;
				}
			}
			break;
		default: /* swap two bytes */
			if (n > 1) {
				size_t a = rng_below(n), b = rng_below(n);
				unsigned char t = buf[a];
				buf[a] = buf[b];
				buf[b] = t;
			}
			break;
		}
	}
}

/* Seeded mutation fuzz over one envelope and one key text. Case 0 is the
 * unmutated input. Prints one verdict record per case. */
static int cmd_fuzz(const char *seed_text, const char *count_text, const char *env_path, const char *key_path) {
	unsigned char key[32];
	int rc = load_key(key_path, key);
	if (rc != 0) return rc;
	size_t env_len = 0, key_len = 0;
	unsigned char *env = slurp(env_path, &env_len);
	unsigned char *key_text = slurp(key_path, &key_len);
	if (env == NULL || key_text == NULL) {
		free(env);
		free(key_text);
		return 66;
	}
	rng_state = strtoull(seed_text, NULL, 10);
	long count = strtol(count_text, NULL, 10);
	size_t cap = env_len + 256;
	unsigned char *work = malloc(cap);
	size_t key_cap = key_len + 64;
	unsigned char *key_work = malloc(key_cap);
	for (long i = 0; i < count; i++) {
		size_t len = env_len;
		memcpy(work, env, env_len);
		if (i > 0) mutate(work, &len, cap);
		printf("e%ld ", i);
		envelope_record(work, len, key);

		size_t klen = key_len;
		memcpy(key_work, key_text, key_len);
		if (i > 0) mutate(key_work, &klen, key_cap);
		unsigned char parsed[32];
		int k = sigil_public_key_from_text((const char *)key_work, klen, parsed);
		printf("k%ld %d ", i, k);
		print_hex(parsed, k == SIGIL_OK ? 32 : 0);
		printf("\n");
	}
	free(work);
	free(key_work);
	free(env);
	free(key_text);
	return 0;
}

/* Read a list of paths, one per line, from `path`. */
static char **read_list(const char *path, size_t *count_out) {
	size_t len = 0;
	unsigned char *text = slurp(path, &len);
	if (text == NULL) return NULL;
	size_t cap = 16, count = 0;
	char **items = malloc(cap * sizeof *items);
	size_t start = 0;
	for (size_t i = 0; i <= len && items != NULL; i++) {
		if (i == len || text[i] == '\n') {
			if (i > start) {
				if (count == cap) {
					cap *= 2;
					char **grown = realloc(items, cap * sizeof *items);
					if (grown == NULL) break;
					items = grown;
				}
				items[count] = malloc(i - start + 1);
				memcpy(items[count], text + start, i - start);
				items[count][i - start] = '\0';
				count++;
			}
			start = i + 1;
		}
	}
	free(text);
	*count_out = count;
	return items;
}

static void free_list(char **items, size_t count) {
	for (size_t i = 0; i < count; i++) free(items[i]);
	free(items);
}

/* Every envelope under every key, in one process. */
static int cmd_envelope_all(const char *env_list, const char *key_list) {
	size_t env_count = 0, key_count = 0;
	char **envs = read_list(env_list, &env_count);
	char **keys = read_list(key_list, &key_count);
	int status = (envs == NULL || keys == NULL) ? 66 : 0;
	for (size_t e = 0; e < env_count && status == 0; e++) {
		for (size_t k = 0; k < key_count && status == 0; k++) {
			printf("== %s %s\n", envs[e], keys[k]);
			status = cmd_envelope(envs[e], keys[k]);
		}
	}
	if (envs != NULL) free_list(envs, env_count);
	if (keys != NULL) free_list(keys, key_count);
	return status;
}

/* Fuzz every envelope under every key, seeds counting up from 1. */
static int cmd_fuzz_all(const char *count_text, const char *env_list, const char *key_list) {
	size_t env_count = 0, key_count = 0;
	char **envs = read_list(env_list, &env_count);
	char **keys = read_list(key_list, &key_count);
	int status = (envs == NULL || keys == NULL) ? 66 : 0;
	unsigned long seed = 1;
	for (size_t e = 0; e < env_count && status == 0; e++) {
		for (size_t k = 0; k < key_count && status == 0; k++) {
			char seed_text[32];
			snprintf(seed_text, sizeof seed_text, "%lu", seed++);
			printf("== seed %s %s %s\n", seed_text, envs[e], keys[k]);
			status = cmd_fuzz(seed_text, count_text, envs[e], keys[k]);
		}
	}
	if (envs != NULL) free_list(envs, env_count);
	if (keys != NULL) free_list(keys, key_count);
	return status;
}

int main(int argc, char **argv) {
	if (argc == 2 && strcmp(argv[1], "meta") == 0) return cmd_meta();
	if (argc == 2 && strcmp(argv[1], "verify-null") == 0) return cmd_verify_null();
	if (argc == 3 && strcmp(argv[1], "verify-cases") == 0) return cmd_verify_cases(argv[2]);
	if (argc == 4 && strcmp(argv[1], "envelope") == 0) return cmd_envelope(argv[2], argv[3]);
	if (argc == 2 && strcmp(argv[1], "pubkey-sweep") == 0) return cmd_pubkey_sweep();
	if (argc == 6 && strcmp(argv[1], "fuzz") == 0) return cmd_fuzz(argv[2], argv[3], argv[4], argv[5]);
	if (argc == 4 && strcmp(argv[1], "envelope-all") == 0) return cmd_envelope_all(argv[2], argv[3]);
	if (argc == 5 && strcmp(argv[1], "fuzz-all") == 0) return cmd_fuzz_all(argv[2], argv[3], argv[4]);
	fprintf(stderr, "usage: %s meta | verify-null | verify-cases FILE | envelope ENV KEY | envelope-all ENVS KEYS\n"
		"       | pubkey-sweep | fuzz SEED COUNT ENV KEY | fuzz-all COUNT ENVS KEYS (ENVS and KEYS list one path per line)\n",
		argc > 0 ? argv[0] : "driver");
	return 64;
}
