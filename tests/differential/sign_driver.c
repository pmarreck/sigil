/* Differential driver for the signing library (sigil_sign.h): one source,
 * linked once against the Zig libsigil_sign.a and once against the Rust one.
 * Every command prints a deterministic record; tests/differential/sign
 * compares the two. Key generation uses real entropy, so the script checks
 * it by round trip: a key made by either implementation must open and sign
 * identically in both.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sigil_sign.h"

static unsigned char *slurp(const char *path, size_t *len_out) {
	FILE *in = fopen(path, "rb");
	if (in == NULL) return NULL;
	size_t cap = 4096, len = 0;
	unsigned char *buf = malloc(cap);
	while (buf != NULL) {
		len += fread(buf + len, 1, cap - len, in);
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
	if (fclose(in) != 0 && buf != NULL) {
		free(buf);
		buf = NULL;
	}
	*len_out = len;
	return buf;
}

static int spill(const char *path, const char *bytes, size_t len) {
	FILE *out = fopen(path, "wb");
	if (out == NULL) return 73;
	size_t wrote = fwrite(bytes, 1, len, out);
	if (fclose(out) != 0 || wrote != len) return 74;
	return 0;
}

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

#define COUNT(a) (sizeof(a) / sizeof((a)[0]))
#define BIG (1u << 20)

static int cmd_meta(void) {
	for (int code = 8; code >= -40; code--) printf("strerror[%d]=%s\n", code, sigil_sign_strerror(code));
	return 0;
}

/* Public key, sealed envelopes over several payloads, a wrong passphrase,
 * and the buffer and NULL contracts, for one keyfile. */
static int cmd_keyfile(const char *key_path, const char *pass_path) {
	size_t key_len = 0, pass_len = 0;
	char *key = (char *)slurp(key_path, &key_len);
	char *pass = (char *)slurp(pass_path, &pass_len);
	if (key == NULL || pass == NULL) {
		free(key);
		free(pass);
		return 66;
	}
	unsigned char pk[32];
	int rc = sigil_keyfile_public_key(key, key_len, pass, pass_len, pk);
	printf("pubkey %d ", rc);
	print_hex(pk, rc == 0 ? 32 : 0);
	printf("\n");

	static const char *const payloads[] = {"", "{\"v\":\"1\"}", "\x00\x01\x02\xff", "line one\nline two\n"};
	static const size_t payload_lens[] = {0, 9, 4, 18};
	char *out = malloc(BIG);
	for (size_t i = 0; i < COUNT(payloads); i++) {
		size_t n = 0;
		rc = sigil_seal(key, key_len, pass, pass_len, (const unsigned char *)payloads[i], payload_lens[i], out, BIG, &n);
		printf("seal %zu %d %zu ", i, rc, rc == 0 ? n : 0);
		print_hex((const unsigned char *)out, rc == 0 ? n : 0);
		printf("\n");
	}
	size_t n = 0, query = 0;
	rc = sigil_seal(key, key_len, pass, pass_len, (const unsigned char *)"x", 1, NULL, 0, &query);
	printf("seal query %d %zu\n", rc, query);
	if (query > 0) printf("seal one short %d\n", sigil_seal(key, key_len, pass, pass_len, (const unsigned char *)"x", 1, out, query - 1, &n));
	printf("seal null out %d\n", sigil_seal(key, key_len, pass, pass_len, (const unsigned char *)"x", 1, NULL, BIG, &n));
	printf("seal null keyfile %d\n", sigil_seal(NULL, 0, pass, pass_len, (const unsigned char *)"x", 1, out, BIG, &n));
	printf("seal null passphrase %d\n", sigil_seal(key, key_len, NULL, 0, (const unsigned char *)"x", 1, out, BIG, &n));
	printf("seal null payload %d\n", sigil_seal(key, key_len, pass, pass_len, NULL, 0, out, BIG, &n));
	printf("seal null length %d\n", sigil_seal(key, key_len, pass, pass_len, (const unsigned char *)"x", 1, out, BIG, NULL));
	printf("seal wrong passphrase %d\n", sigil_seal(key, key_len, "wrong", 5, (const unsigned char *)"x", 1, out, BIG, &n));
	printf("pubkey null out %d\n", sigil_keyfile_public_key(key, key_len, pass, pass_len, NULL));
	printf("pubkey null keyfile %d\n", sigil_keyfile_public_key(NULL, 0, pass, pass_len, pk));
	printf("open keyfile as bundle %d\n", sigil_hot_bundle_open(key, key_len, pass, pass_len, out, BIG, &n));
	free(out);
	free(key);
	free(pass);
	return 0;
}

/* Seal one payload file and write the envelope to stdout unchanged, so the
 * harness can compare it with a committed vector. */
static int cmd_seal(const char *key_path, const char *pass_path, const char *payload_path) {
	size_t key_len = 0, pass_len = 0, payload_len = 0;
	char *key = (char *)slurp(key_path, &key_len);
	char *pass = (char *)slurp(pass_path, &pass_len);
	unsigned char *payload = slurp(payload_path, &payload_len);
	int rc = 66;
	if (key != NULL && pass != NULL && payload != NULL) {
		char *out = malloc(BIG);
		size_t n = 0;
		rc = sigil_seal(key, key_len, pass, pass_len, payload, payload_len, out, BIG, &n);
		if (rc == 0 && fwrite(out, 1, n, stdout) != n) rc = 74;
		if (rc != 0) fprintf(stderr, "seal: %d %s\n", rc, sigil_sign_strerror(rc));
		free(out);
	}
	free(key);
	free(pass);
	free(payload);
	return rc == 0 ? 0 : 1;
}

/* Everything a freshly generated key pair must support: its public key, a
 * seal of a fixed payload, and (unless BUNDLE is "-") the bundle's PEM. The
 * harness runs both implementations on keys each one generated. */
static int cmd_custody(const char *key_path, const char *bundle_path, const char *pass_path) {
	size_t key_len = 0, pass_len = 0;
	char *key = (char *)slurp(key_path, &key_len);
	char *pass = (char *)slurp(pass_path, &pass_len);
	if (key == NULL || pass == NULL) {
		free(key);
		free(pass);
		return 66;
	}
	unsigned char pk[32];
	int rc = sigil_keyfile_public_key(key, key_len, pass, pass_len, pk);
	printf("pubkey %d ", rc);
	print_hex(pk, rc == 0 ? 32 : 0);
	printf("\n");
	char *out = malloc(BIG);
	size_t n = 0;
	rc = sigil_seal(key, key_len, pass, pass_len, (const unsigned char *)"{\"v\":\"1\"}", 9, out, BIG, &n);
	printf("seal %d ", rc);
	print_hex((const unsigned char *)out, rc == 0 ? n : 0);
	printf("\n");
	if (strcmp(bundle_path, "-") != 0) {
		size_t len = 0;
		char *bundle = (char *)slurp(bundle_path, &len);
		rc = bundle == NULL ? 66 : sigil_hot_bundle_open(bundle, len, pass, pass_len, out, BIG, &n);
		printf("open %d %zu %016llx\n", rc, rc == 0 ? n : 0, rc == 0 ? (unsigned long long)fnv1a((unsigned char *)out, n) : 0ULL);
		free(bundle);
	}
	free(out);
	free(key);
	free(pass);
	return 0;
}

/* PEM from one hot bundle, plus the NULL contract and refusals. */
static int cmd_bundle(const char *bundle_path, const char *pass_path) {
	size_t len = 0, pass_len = 0;
	char *bundle = (char *)slurp(bundle_path, &len);
	char *pass = (char *)slurp(pass_path, &pass_len);
	if (bundle == NULL || pass == NULL) {
		free(bundle);
		free(pass);
		return 66;
	}
	char *out = malloc(BIG);
	size_t n = 0;
	int rc = sigil_hot_bundle_open(bundle, len, pass, pass_len, out, BIG, &n);
	printf("open %d %zu ", rc, rc == 0 ? n : 0);
	print_hex((const unsigned char *)out, rc == 0 ? n : 0);
	printf("\n");
	size_t query = 0;
	printf("open query %d", sigil_hot_bundle_open(bundle, len, pass, pass_len, NULL, 0, &query));
	printf(" %zu\n", query);
	printf("open wrong passphrase %d\n", sigil_hot_bundle_open(bundle, len, "wrong", 5, out, BIG, &n));
	printf("open null bundle %d\n", sigil_hot_bundle_open(NULL, 0, pass, pass_len, out, BIG, &n));
	printf("open null length %d\n", sigil_hot_bundle_open(bundle, len, pass, pass_len, out, BIG, NULL));
	unsigned char pk[32];
	printf("bundle as keyfile %d\n", sigil_keyfile_public_key(bundle, len, pass, pass_len, pk));
	free(out);
	free(bundle);
	free(pass);
	return 0;
}

/* Generate keys with this implementation and write them for the other to
 * read. Prints only what does not depend on the entropy drawn. */
static int cmd_keygen(const char *key_out, const char *bundle_out, const char *pass) {
	size_t pass_len = strlen(pass);
	char *k = malloc(BIG), *b = malloc(BIG);
	size_t kn = 0, bn = 0;
	int rc = sigil_keygen_with_recovery(pass, pass_len, k, BIG, &kn, b, BIG, &bn);
	printf("keygen_with_recovery %d\n", rc);
	if (rc == 0) rc = spill(key_out, k, kn);
	if (rc == 0) rc = spill(bundle_out, b, bn);
	size_t n = 0;
	char *single = malloc(BIG);
	int s = sigil_keygen(pass, pass_len, single, BIG, &n);
	printf("keygen %d\n", s);
	if (rc == 0 && s == 0) {
		char path[4096];
		snprintf(path, sizeof path, "%s.single", key_out);
		rc = spill(path, single, n);
	}
	printf("keygen empty passphrase %d\n", sigil_keygen("", 0, single, BIG, &n));
	printf("keygen null passphrase %d\n", sigil_keygen(NULL, 0, single, BIG, &n));
	printf("keygen null length %d\n", sigil_keygen(pass, pass_len, single, BIG, NULL));
	printf("recovery empty passphrase %d\n", sigil_keygen_with_recovery("", 0, k, BIG, &kn, b, BIG, &bn));
	printf("recovery null lengths %d\n", sigil_keygen_with_recovery(pass, pass_len, k, BIG, NULL, b, BIG, &bn));
	size_t qk = 0, qb = 0;
	int q = sigil_keygen_with_recovery(pass, pass_len, NULL, 0, &qk, NULL, 0, &qb);
	printf("recovery query %d nonzero=%d\n", q, qk > 0 && qb > 0);
	free(k);
	free(b);
	free(single);
	return rc;
}

/* Public-key derivation over a list of keyfile paths, one per line: the
 * hand-written variant table the harness builds around the strict parser. */
static int cmd_pubkeys(const char *pass_path, const char *list_path) {
	size_t pass_len = 0;
	char *pass = (char *)slurp(pass_path, &pass_len);
	FILE *list = fopen(list_path, "r");
	if (pass == NULL || list == NULL) {
		free(pass);
		if (list != NULL) fclose(list);
		return 66;
	}
	char path[4096];
	int rc = 0;
	while (rc == 0 && fgets(path, sizeof path, list) != NULL) {
		path[strcspn(path, "\n")] = '\0';
		size_t len = 0;
		char *key = (char *)slurp(path, &len);
		if (key == NULL) {
			rc = 66;
			break;
		}
		unsigned char pk[32];
		int got = sigil_keyfile_public_key(key, len, pass, pass_len, pk);
		printf("%s %d%s", strrchr(path, '/') != NULL ? strrchr(path, '/') + 1 : path, got, got == 0 ? " " : "");
		print_hex(pk, got == 0 ? 32 : 0);
		printf("\n");
		free(key);
	}
	fclose(list);
	free(pass);
	return rc;
}

static uint64_t rng_state;
static uint64_t rng_next(void) {
	uint64_t z = (rng_state += 0x9e3779b97f4a7c15ULL);
	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
	z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
	return z ^ (z >> 31);
}
static size_t rng_below(size_t n) { return n == 0 ? 0 : (size_t)(rng_next() % n); }

/* No backslash and no digits: a mutation must not be able to spell an
 * expensive KDF parameter, directly or through an escaped key. */
static const char *const tokens[] = {
	"\"", ":", ",", "{", "}", "[", "]", " ", "\n", "\t", "null", "true", "\"x\":", "\"public\":\"w\",",
	"\"sigil\":\"secret-key-v1\",", "\"sigil\":\"hot-bundle-v1\",", "\"kdf\":\"scrypt\",", "\xc2\xb7", "\xe2\x90\xa3",
	"\xc2", "\xe2\x90", "\xff", "-", ".", "e",
};

static void mutate(unsigned char *buf, size_t *len, size_t cap) {
	int rounds = 1 + (int)rng_below(3);
	for (int r = 0; r < rounds; r++) {
		size_t n = *len;
		switch (rng_below(5)) {
		case 0: /* flip a bit outside ASCII digits and backslash */
			if (n > 0) {
				size_t at = rng_below(n);
				unsigned char v = buf[at] ^ (unsigned char)(1u << rng_below(8));
				if (!(v >= '0' && v <= '9') && v != '\\') buf[at] = v;
			}
			break;
		case 1: {
			const char *t = tokens[rng_below(COUNT(tokens))];
			size_t tl = strlen(t);
			if (n + tl <= cap) {
				size_t at = rng_below(n + 1);
				memmove(buf + at + tl, buf + at, n - at);
				memcpy(buf + at, t, tl);
				*len = n + tl;
			}
			break;
		}
		case 2:
			if (n > 0) {
				size_t at = rng_below(n), span = 1 + rng_below(n - at < 6 ? n - at : 6);
				memmove(buf + at, buf + at + span, n - at - span);
				*len = n - span;
			}
			break;
		case 3:
			if (n > 0) {
				size_t from = rng_below(n), span = 1 + rng_below(n - from < 30 ? n - from : 30);
				if (n + span <= cap) {
					unsigned char tmp[30];
					size_t at = rng_below(n + 1);
					memcpy(tmp, buf + from, span);
					memmove(buf + at + span, buf + at, n - at);
					memcpy(buf + at, tmp, span);
					*len = n + span;
				}
			}
			break;
		default:
			*len = rng_below(n + 1);
			break;
		}
	}
}

/* Refuse to run a case whose KDF would be expensive: duplicated spans can
 * still move a large digit run next to "m", "t" or "p". */
static int cheap_enough(const unsigned char *buf, size_t len) {
	static const char *const keys[] = {"\"t\":", "\"m\":", "\"p\":"};
	static const unsigned long limits[] = {4, 4096, 64};
	for (size_t k = 0; k < COUNT(keys); k++) {
		size_t kl = strlen(keys[k]);
		for (size_t i = 0; i + kl <= len; i++) {
			if (memcmp(buf + i, keys[k], kl) != 0) continue;
			size_t j = i + kl;
			while (j < len && (buf[j] == ' ' || buf[j] == '\t' || buf[j] == '\n' || buf[j] == '\r')) j++;
			unsigned long v = 0;
			int digits = 0;
			while (j < len && buf[j] >= '0' && buf[j] <= '9' && digits < 12) v = v * 10 + (unsigned long)(buf[j++] - '0'), digits++;
			if (digits >= 12 || v > limits[k]) return 0;
		}
	}
	return 1;
}

/* Seeded mutations of one keyfile (public-key derivation) or bundle (PEM). */
static int cmd_fuzz(const char *mode, const char *seed, const char *count_text, const char *path, const char *pass_path) {
	size_t len = 0, pass_len = 0;
	unsigned char *orig = slurp(path, &len);
	char *pass = (char *)slurp(pass_path, &pass_len);
	if (orig == NULL || pass == NULL) {
		free(orig);
		free(pass);
		return 66;
	}
	rng_state = strtoull(seed, NULL, 10);
	long count = strtol(count_text, NULL, 10);
	size_t cap = len + 512;
	unsigned char *work = malloc(cap);
	char *out = malloc(BIG);
	int bundle = strcmp(mode, "bundle") == 0;
	for (long i = 0; i < count; i++) {
		size_t n = len;
		memcpy(work, orig, len);
		if (i > 0) mutate(work, &n, cap);
		if (!cheap_enough(work, n)) {
			printf("%ld skip\n", i);
			continue;
		}
		if (bundle) {
			size_t pem = 0;
			int rc = sigil_hot_bundle_open((const char *)work, n, pass, pass_len, out, BIG, &pem);
			printf("%ld %d %016llx\n", i, rc, rc == 0 ? (unsigned long long)fnv1a((unsigned char *)out, pem) : 0ULL);
		} else {
			unsigned char pk[32];
			int rc = sigil_keyfile_public_key((const char *)work, n, pass, pass_len, pk);
			printf("%ld %d ", i, rc);
			print_hex(pk, rc == 0 ? 32 : 0);
			printf("\n");
		}
	}
	free(work);
	free(out);
	free(orig);
	free(pass);
	return 0;
}

/* Paper cold copies over artifact sizes that walk the QR versions, labels
 * that need PDF escaping and wrapping, both kinds, with and without a
 * public key, several artifacts per document, plus the argument contract. */
static int cmd_paper(const char *fixture_path) {
	size_t fixture_len = 0;
	unsigned char *fixture = slurp(fixture_path, &fixture_len);
	if (fixture == NULL) return 66;
	unsigned char *bytes = malloc(1200);
	for (size_t i = 0; i < 1200; i++) bytes[i] = (unsigned char)(i * 131 + 7);
	unsigned char pk[32];
	for (int i = 0; i < 32; i++) pk[i] = (unsigned char)(0xa0 + i);
	char *out = malloc(8u << 20);
	static const char *const labels[] = {
		"Mecha Validate beta-license (TEST)", "",
		"A label (with parens) and \\ a backslash, long enough that the title has to wrap onto a second line here",
	};
	/* Every size to 40, then a stride, then the QR capacity edge: the bytes are
	 * hex-encoded and version 40 at level M holds 2331 bytes, so 1165 fits. */
	for (size_t len = 0; len <= 1167; len = len < 40 ? len + 1 : len < 1144 ? len + 23 : len < 1164 ? 1164 : len + 1) {
		sigil_paper_artifact a = {
			.kind = (int)(len % 2), .label = labels[len % COUNT(labels)], .filename = "role.key",
			.bytes = bytes, .bytes_len = len, .pubkey = len % 3 == 0 ? pk : NULL,
		};
		size_t n = 0;
		int rc = sigil_paper_render(&a, 1, "2026-11-10", out, 8u << 20, &n);
		printf("paper %zu %d %zu %016llx\n", len, rc, rc == 0 ? n : 0,
			rc == 0 ? (unsigned long long)fnv1a((unsigned char *)out, n) : 0ULL);
	}
	sigil_paper_artifact three[3] = {
		{.kind = SIGIL_PAPER_KEYFILE, .label = "role one", .filename = "one.key", .bytes = fixture, .bytes_len = fixture_len, .pubkey = pk},
		{.kind = SIGIL_PAPER_HOT_BUNDLE, .label = "role one", .filename = "one.hot.sealed", .bytes = fixture, .bytes_len = fixture_len, .pubkey = NULL},
		{.kind = 7, .label = "unknown kind is a keyfile", .filename = "x", .bytes = bytes, .bytes_len = 64, .pubkey = NULL},
	};
	size_t n = 0;
	int rc = sigil_paper_render(three, 3, "1999-01-01", out, 8u << 20, &n);
	printf("paper three %d %zu %016llx\n", rc, rc == 0 ? n : 0, rc == 0 ? (unsigned long long)fnv1a((unsigned char *)out, n) : 0ULL);
	size_t query = 0;
	printf("paper query %d", sigil_paper_render(three, 1, "2026-11-10", NULL, 0, &query));
	printf(" %zu\n", query);
	printf("paper null out %d\n", sigil_paper_render(three, 1, "2026-11-10", NULL, 8u << 20, &n));
	printf("paper null artifacts %d\n", sigil_paper_render(NULL, 1, "2026-11-10", out, 8u << 20, &n));
	printf("paper zero count %d\n", sigil_paper_render(three, 0, "2026-11-10", out, 8u << 20, &n));
	printf("paper null date %d\n", sigil_paper_render(three, 1, NULL, out, 8u << 20, &n));
	printf("paper null length %d\n", sigil_paper_render(three, 1, "2026-11-10", out, 8u << 20, NULL));
	sigil_paper_artifact bad = three[0];
	bad.label = NULL;
	printf("paper null label %d\n", sigil_paper_render(&bad, 1, "2026-11-10", out, 8u << 20, &n));
	bad = three[0];
	bad.bytes = NULL;
	printf("paper null bytes %d\n", sigil_paper_render(&bad, 1, "2026-11-10", out, 8u << 20, &n));
	free(out);
	free(bytes);
	free(fixture);
	return 0;
}

/* Write one rendered PDF to a file, for inspecting a divergence. */
static int cmd_paper_dump(const char *len_text, const char *out_path) {
	size_t len = (size_t)strtoul(len_text, NULL, 10);
	unsigned char *bytes = malloc(len + 1);
	for (size_t i = 0; i < len; i++) bytes[i] = (unsigned char)(i * 131 + 7);
	sigil_paper_artifact a = {.kind = 0, .label = "dump", .filename = "role.key", .bytes = bytes, .bytes_len = len, .pubkey = NULL};
	char *out = malloc(8u << 20);
	size_t n = 0;
	int rc = sigil_paper_render(&a, 1, "2026-11-10", out, 8u << 20, &n);
	if (rc == 0) rc = spill(out_path, out, n);
	free(out);
	free(bytes);
	return rc;
}

int main(int argc, char **argv) {
	if (argc == 2 && strcmp(argv[1], "meta") == 0) return cmd_meta();
	if (argc == 4 && strcmp(argv[1], "keyfile") == 0) return cmd_keyfile(argv[2], argv[3]);
	if (argc == 5 && strcmp(argv[1], "seal") == 0) return cmd_seal(argv[2], argv[3], argv[4]);
	if (argc == 4 && strcmp(argv[1], "bundle") == 0) return cmd_bundle(argv[2], argv[3]);
	if (argc == 5 && strcmp(argv[1], "keygen") == 0) return cmd_keygen(argv[2], argv[3], argv[4]);
	if (argc == 5 && strcmp(argv[1], "custody") == 0) return cmd_custody(argv[2], argv[3], argv[4]);
	if (argc == 4 && strcmp(argv[1], "pubkeys") == 0) return cmd_pubkeys(argv[2], argv[3]);
	if (argc == 7 && strcmp(argv[1], "fuzz") == 0) return cmd_fuzz(argv[2], argv[3], argv[4], argv[5], argv[6]);
	if (argc == 3 && strcmp(argv[1], "paper") == 0) return cmd_paper(argv[2]);
	if (argc == 4 && strcmp(argv[1], "paper-dump") == 0) return cmd_paper_dump(argv[2], argv[3]);
	fprintf(stderr,
		"usage: %s meta | keyfile KEY PASSFILE | seal KEY PASSFILE PAYLOAD | bundle BUNDLE PASSFILE\n"
		"       | keygen KEYOUT BUNDLEOUT PASS | custody KEY BUNDLE|- PASSFILE\n"
		"       | pubkeys PASSFILE LIST | fuzz keyfile|bundle SEED COUNT FILE PASSFILE\n"
		"       | paper FIXTURE | paper-dump LEN OUT\n",
		argc > 0 ? argv[0] : "sign_driver");
	return 64;
}
