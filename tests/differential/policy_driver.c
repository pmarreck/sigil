/* Differential driver for mecha_policy: one source, compiled once against
 * the Zig library and once against the Rust one. Each command prints a
 * deterministic record of what the linked library answers;
 * tests/differential/policy compares the two records and checks the
 * manifest rows against their hand-written expectations.
 *
 * Inputs are tab-separated files with byte strings in lowercase hex, so any
 * byte value can reach the library.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mecha_policy.h"

static int hex_value(char c) {
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	return -1;
}

/* Decode hex into a new NUL-terminated buffer (the NUL is not counted). */
static char *unhex(const char *hex, size_t *len_out) {
	size_t digits = strlen(hex);
	if (digits % 2 != 0) return NULL;
	size_t len = digits / 2;
	char *out = malloc(len + 1);
	if (out == NULL) return NULL;
	for (size_t i = 0; i < len; i++) {
		int hi = hex_value(hex[2 * i]), lo = hex_value(hex[2 * i + 1]);
		if (hi < 0 || lo < 0) {
			free(out);
			return NULL;
		}
		out[i] = (char)(hi << 4 | lo);
	}
	out[len] = '\0';
	*len_out = len;
	return out;
}

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

/* Split a line in place on tabs. Returns the field count. */
static int split_tabs(char *line, char **fields, int max) {
	int n = 0;
	char *cursor = line;
	while (n < max) {
		fields[n++] = cursor;
		char *tab = strchr(cursor, '\t');
		if (tab == NULL) break;
		*tab = '\0';
		cursor = tab + 1;
	}
	return n;
}

/* "-" in a TSV column means NULL. */
static const char *nullable(const char *field) { return strcmp(field, "-") == 0 ? NULL : field; }

static void print_decision(int32_t code) {
	if (code >= 0)
		printf("%d %s\n", code, mecha_policy_reason_name((uint8_t)code));
	else
		printf("%d\n", code);
}

static void print_install(int32_t code) {
	if (code >= 0)
		printf("%d %s\n", code, mecha_policy_install_reason_name((uint8_t)code));
	else
		printf("%d\n", code);
}

static int cmd_meta(void) {
	printf("abi=%u version=%s\n", mecha_policy_abi_version(), mecha_policy_version());
	for (int code = 0; code < 256; code++) {
		printf("reason[%d]=%s install[%d]=%s\n", code, mecha_policy_reason_name((uint8_t)code), code,
			mecha_policy_install_reason_name((uint8_t)code));
	}
	return 0;
}

typedef int (*row_fn)(char **fields, int n);

static int each_row(const char *path, row_fn fn) {
	FILE *in = fopen(path, "r");
	if (in == NULL) {
		perror(path);
		return 66;
	}
	char line[16384];
	int status = 0;
	while (status == 0 && fgets(line, sizeof line, in) != NULL) {
		if (line[0] == '#' || line[0] == '\n') continue;
		line[strcspn(line, "\n")] = '\0';
		char *fields[16];
		status = fn(fields, split_tabs(line, fields, 16));
	}
	if (fclose(in) != 0 && status == 0) status = 74;
	return status;
}

/* payload_path role product major minor now high_water operation */
static int decide_row(char **f, int n) {
	if (n < 8) return 65;
	size_t len = 0;
	unsigned char *payload = slurp(f[0], &len);
	if (payload == NULL) return 66;
	print_decision(mecha_policy_decide(payload, len, (uint8_t)atoi(f[1]), f[2], (uint32_t)strtoul(f[3], NULL, 10),
		(uint32_t)strtoul(f[4], NULL, 10), f[5], nullable(f[6]), nullable(f[7])));
	free(payload);
	return 0;
}

/* cert_path product license_sha256 machine now high_water */
static int install_row(char **f, int n) {
	if (n < 6) return 65;
	size_t len = 0;
	unsigned char *cert = slurp(f[0], &len);
	if (cert == NULL) return 66;
	print_install(mecha_policy_install_decide(cert, len, f[1], f[2], f[3], f[4], nullable(f[5])));
	free(cert);
	return 0;
}

/* product raw_hex */
static int machine_row(char **f, int n) {
	if (n < 2) return 65;
	size_t len = 0;
	char *raw = unhex(f[1], &len);
	if (raw == NULL) return 65;
	char out[65];
	memset(out, 'x', sizeof out);
	mecha_policy_machine_hash(f[0], (const uint8_t *)raw, len, out);
	printf("%.64s nul=%d\n", out, out[64] == '\0');
	free(raw);
	return 0;
}

static int kind_code(const char *kind) {
	if (strcmp(kind, "disk") == 0) return MECHA_POLICY_HINT_DISK;
	if (strcmp(kind, "mac") == 0) return MECHA_POLICY_HINT_MAC;
	if (strcmp(kind, "tpm") == 0) return MECHA_POLICY_HINT_TPM;
	return atoi(kind);
}

/* product_hex kind raw_hex */
static int hint_row(char **f, int n) {
	if (n < 3) return 65;
	size_t product_len = 0, raw_len = 0;
	char *product = unhex(f[0], &product_len);
	char *raw = unhex(f[2], &raw_len);
	if (product == NULL || raw == NULL) {
		free(product);
		free(raw);
		return 65;
	}
	char out[64];
	int32_t rc = mecha_policy_hint_hash((const uint8_t *)product, product_len, (uint8_t)kind_code(f[1]),
		(const uint8_t *)raw, raw_len, out, sizeof out);
	printf("%d %.*s\n", rc, rc == 64 ? 64 : 0, out);
	free(product);
	free(raw);
	return 0;
}

/* The decide parameter grid over one payload: every role (including an
 * unknown one), both products, versions on each side of the vectors'
 * ceilings, dates on each side of their expiries plus an impossible and an
 * empty date, high-water marks before and after, and operations. Each axis
 * holds only values that change some outcome, which keeps the grid small
 * enough to run on every commit. */
static const char *const grid_products[] = {"mecha-validate", "mecha-rotshield"};
static const uint32_t grid_majors[] = {0, 1, 2};
static const uint32_t grid_minors[] = {3, 4};
static const char *const grid_nows[] = {"2026-10-17", "2026-10-18", "2026-02-29", ""};
static const char *const grid_marks[] = {NULL, "2027-01-01", "garbage"};
static const char *const grid_ops[] = {NULL, "verify", "full"};
#define COUNT(a) (sizeof(a) / sizeof((a)[0]))

static int cmd_decide_grid(const char *list_path) {
	FILE *list = fopen(list_path, "r");
	if (list == NULL) return 66;
	char path[4096];
	while (fgets(path, sizeof path, list) != NULL) {
		path[strcspn(path, "\n")] = '\0';
		size_t len = 0;
		unsigned char *payload = slurp(path, &len);
		if (payload == NULL) {
			fclose(list);
			return 66;
		}
		printf("== %s\n", path);
		for (int role = 0; role <= 2; role++)
			for (size_t p = 0; p < COUNT(grid_products); p++)
				for (size_t a = 0; a < COUNT(grid_majors); a++)
					for (size_t b = 0; b < COUNT(grid_minors); b++) {
						for (size_t d = 0; d < COUNT(grid_nows); d++)
							for (size_t m = 0; m < COUNT(grid_marks); m++)
								for (size_t o = 0; o < COUNT(grid_ops); o++)
									printf("%d ", mecha_policy_decide(payload, len, (uint8_t)role, grid_products[p],
										grid_majors[a], grid_minors[b], grid_nows[d], grid_marks[m], grid_ops[o]));
						printf("\n");
					}
		free(payload);
	}
	fclose(list);
	return 0;
}

/* Install-decide grid over one certificate: products, the hashes it binds and
 * others (including malformed ones), dates and high-water marks. */
static int cmd_install_grid(const char *list_path, const char *hashes_path) {
	size_t hashes_len = 0;
	char *hashes = (char *)slurp(hashes_path, &hashes_len);
	if (hashes == NULL) return 66;
	char *hash_list[64];
	int hash_count = 0;
	for (char *line = strtok(hashes, "\n"); line != NULL && hash_count < 64; line = strtok(NULL, "\n"))
		hash_list[hash_count++] = line;
	FILE *list = fopen(list_path, "r");
	if (list == NULL) {
		free(hashes);
		return 66;
	}
	char path[4096];
	while (fgets(path, sizeof path, list) != NULL) {
		path[strcspn(path, "\n")] = '\0';
		size_t len = 0;
		unsigned char *cert = slurp(path, &len);
		if (cert == NULL) break;
		printf("== %s\n", path);
		for (size_t p = 0; p < COUNT(grid_products); p++)
			for (int l = 0; l < hash_count; l++) {
				for (int h = 0; h < hash_count; h++)
					for (size_t d = 0; d < COUNT(grid_nows); d++)
						for (size_t m = 0; m < COUNT(grid_marks); m++)
							printf("%d ", mecha_policy_install_decide(cert, len, grid_products[p], hash_list[l],
								hash_list[h], grid_nows[d], grid_marks[m]));
				printf("\n");
			}
		free(cert);
	}
	fclose(list);
	free(hashes);
	return 0;
}

/* Machine and hint hashing over normalization edges, plus the hint ABI's
 * argument contract. */
static int cmd_hash_sweep(void) {
	static const char *const raws[] = {
		"", " ", "ABC", "abc", " \tAbC\r\n", "\x00\x01", "MiXeD-Case_123", "\xc3\x89", "a b", "\v x \f",
	};
	static const char *const products[] = {"mecha-validate", "mecha-rotshield", ""};
	for (size_t p = 0; p < COUNT(products); p++)
		for (size_t r = 0; r < COUNT(raws); r++) {
			size_t len = r == 5 ? 2 : strlen(raws[r]);
			char out[65];
			mecha_policy_machine_hash(products[p], (const uint8_t *)raws[r], len, out);
			printf("machine %zu %zu %.64s %d\n", p, r, out, out[64] == '\0');
		}
	static const char *const values[] = {
		"", "  ", "S4EWNX0R123456K", " serial ", "00:1a:2b:3c:4d:5e", "00-1A-2B-3C-4D-5E", "001a.2b3c.4d5e",
		"02:1a:2b:3c:4d:5e", "01:00:5e:00:00:01", "00:00:00:00:00:00", "00:1a:2b:3c:4d", "00:1a:2b:3c:4d:5e:6f",
		"00:1a:2b:3c:4d:5g", "00 1a 2b 3c 4d 5e", "\x00\xff\x10", "AbCdEf012345", "abcdef01234",
	};
	static const char *const hint_products[] = {"mecha-validate", "", "mecha\x00x"};
	static const size_t hint_product_lens[] = {14, 0, 7};
	for (size_t p = 0; p < COUNT(hint_products); p++)
		for (int kind = 0; kind <= 3; kind++)
			for (size_t v = 0; v < COUNT(values); v++) {
				char out[64];
				size_t len = v == 14 ? 3 : strlen(values[v]);
				int32_t rc = mecha_policy_hint_hash((const uint8_t *)hint_products[p], hint_product_lens[p], (uint8_t)kind,
					(const uint8_t *)values[v], len, out, sizeof out);
				printf("hint %zu %d %zu %d %.*s\n", p, kind, v, rc, rc == 64 ? 64 : 0, out);
			}
	char out[64];
	printf("hint null product %d\n", mecha_policy_hint_hash(NULL, 0, 0, (const uint8_t *)"x", 1, out, 64));
	printf("hint null out %d\n", mecha_policy_hint_hash((const uint8_t *)"p", 1, 0, (const uint8_t *)"x", 1, NULL, 64));
	printf("hint null value len 1 %d\n", mecha_policy_hint_hash((const uint8_t *)"p", 1, 0, NULL, 1, out, 64));
	printf("hint null value len 0 %d\n", mecha_policy_hint_hash((const uint8_t *)"p", 1, 0, NULL, 0, out, 64));
	printf("hint null value len 0 tpm %d\n", mecha_policy_hint_hash((const uint8_t *)"p", 1, 2, NULL, 0, out, 64));
	printf("hint cap 63 %d\n", mecha_policy_hint_hash((const uint8_t *)"p", 1, 0, (const uint8_t *)"x", 1, out, 63));
	printf("hint kind 9 cap 0 %d\n", mecha_policy_hint_hash((const uint8_t *)"p", 1, 9, (const uint8_t *)"x", 1, out, 0));
	return 0;
}

/* Exhaust the version-number fields over every string of length 0 to 4 on the
 * alphabet "019_+-": v1 max_major (parsed permissively, with signs and digit
 * separators) and v2 max_major and max_minor (canonical digits only). Each
 * string is decided at app versions below, at and above the values it might
 * mean. Random mutation rarely lands inside these fields; this does not
 * depend on luck. */
static int cmd_numeric_sweep(void) {
	static const char alphabet[] = "019_+-";
	static const uint32_t majors[] = {0, 1, 9, 10, 19};
	char value[8];
	char payload[1024];
	for (int len = 0; len <= 4; len++) {
		int combos = 1;
		for (int i = 0; i < len; i++) combos *= 6;
		for (int c = 0; c < combos; c++) {
			int k = c;
			for (int i = 0; i < len; i++) {
				value[i] = alphabet[k % 6];
				k /= 6;
			}
			value[len] = '\0';
			printf("%s|", value);
			int n = snprintf(payload, sizeof payload,
				"{\"customer_email\":\"t@example.com\",\"customer_name_canonical\":\"t\",\"expiry\":\"2026-10-17\","
				"\"features\":\"full\",\"max_major\":\"%s\",\"offline_days\":\"365\",\"payment_provider\":\"beta\","
				"\"payment_ref\":\"b\",\"product\":\"mecha-validate\",\"purchase_date\":\"2026-09-17\",\"v\":\"1\"}",
				value);
			for (size_t m = 0; m < COUNT(majors); m++)
				printf(" %d", mecha_policy_decide((const uint8_t *)payload, (size_t)n, 0, "mecha-validate", majors[m], 0,
					"2026-09-17", NULL, NULL));
			for (int field = 0; field < 2; field++) {
				n = snprintf(payload, sizeof payload,
					"{\"customer_email\":\"t@example.com\",\"customer_name_canonical\":\"t\",\"expiry\":\"2026-10-17\","
					"\"features\":\"full\",\"max_major\":\"%s\",\"max_minor\":\"%s\",\"offline_days\":\"365\","
					"\"payment_provider\":\"paddle\",\"payment_ref\":\"p\",\"product\":\"mecha-validate\","
					"\"purchase_date\":\"2026-09-17\",\"v\":\"2\"}",
					field == 0 ? value : "1", field == 0 ? "3" : value);
				for (size_t m = 0; m < COUNT(majors); m++)
					for (uint32_t minor = 0; minor <= 10; minor += 5)
						printf(" %d", mecha_policy_decide((const uint8_t *)payload, (size_t)n, 1, "mecha-validate", majors[m],
							minor, "2026-09-17", NULL, NULL));
			}
			printf("\n");
		}
	}
	return 0;
}

static uint64_t rng_state;
static uint64_t rng_next(void) {
	uint64_t z = (rng_state += 0x9e3779b97f4a7c15ULL);
	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
	z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
	return z ^ (z >> 31);
}
static size_t rng_below(size_t n) { return n == 0 ? 0 : (size_t)(rng_next() % n); }

/* Fragments that reach the JSON and schema edges: escapes, surrogates,
 * whitespace, structure, null, numbers, signs and separators in digits, and
 * UTF-8 that is invalid or encodes surrogates. */
static const char *const tokens[] = {
	"\"", "\\", "\\u0076", "\\u00", "\\ud800", "\\udc00", "\\ud800\\udc00", "\\/", "\\n", " ", "\t", "\n", "\r",
	"\x0b", "\x0c", "{", "}", ",", ":", "null", "1", "+1", "-0", "1_0", "0", "01", "true", "[]", "\xef\xbb\xbf",
	"\xc0\x80", "\xed\xa0\x80", "\xff", "\x7f", "\x01", "\"v\":\"1\"", "\"v\":\"2\"", "\"expiry\":null",
	"\"max_minor\":\"0\"", "-", "2026-02-29", "beta", "paddle", "comp", "demo", "full",
};

static void mutate(unsigned char *buf, size_t *len, size_t cap) {
	int rounds = 1 + (int)rng_below(3);
	for (int r = 0; r < rounds; r++) {
		size_t n = *len;
		switch (rng_below(6)) {
		case 0:
			if (n > 0) buf[rng_below(n)] ^= (unsigned char)(1u << rng_below(8));
			break;
		case 1: { /* insert a token */
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
		case 2: /* delete a short span */
			if (n > 0) {
				size_t at = rng_below(n), span = 1 + rng_below(n - at < 8 ? n - at : 8);
				memmove(buf + at, buf + at + span, n - at - span);
				*len = n - span;
			}
			break;
		case 3: /* duplicate a span (fields, keys, digits) */
			if (n > 0) {
				size_t from = rng_below(n), span = 1 + rng_below(n - from < 40 ? n - from : 40);
				if (n + span <= cap) {
					unsigned char tmp[40];
					size_t at = rng_below(n + 1);
					memcpy(tmp, buf + from, span);
					memmove(buf + at + span, buf + at, n - at);
					memcpy(buf + at, tmp, span);
					*len = n + span;
				}
			}
			break;
		case 4: /* replace a byte with a digit, letter or structure byte */
			if (n > 0) buf[rng_below(n)] = (unsigned char)"0123456789abcdef\":,{}-_+ \\"[rng_below(26)];
			break;
		default:
			*len = rng_below(n + 1);
			break;
		}
	}
}

/* Seeded fuzz of one license payload through decide (both roles, fixed
 * request) or one certificate through install decide. */
static int cmd_fuzz(const char *mode, const char *seed, const char *count_text, const char *path, const char *license,
	const char *machine) {
	size_t len = 0;
	unsigned char *orig = slurp(path, &len);
	if (orig == NULL) return 66;
	size_t cap = len + 512;
	unsigned char *work = malloc(cap);
	rng_state = strtoull(seed, NULL, 10);
	long count = strtol(count_text, NULL, 10);
	int install = strcmp(mode, "install") == 0;
	for (long i = 0; i < count; i++) {
		size_t n = len;
		memcpy(work, orig, len);
		if (i > 0) mutate(work, &n, cap);
		if (install) {
			printf("i%ld %d\n", i,
				mecha_policy_install_decide(work, n, "mecha-validate", license, machine, "2026-09-17", NULL));
		} else {
			printf("d%ld %d %d %d\n", i,
				mecha_policy_decide(work, n, 0, "mecha-validate", 1, 3, "2026-09-17", NULL, NULL),
				mecha_policy_decide(work, n, 1, "mecha-validate", 1, 3, "2026-09-17", "2026-01-01", "verify"),
				mecha_policy_decide(work, n, 1, "mecha-rotshield", 2, 0, "2026-10-17", NULL, "full"));
		}
	}
	free(work);
	free(orig);
	return 0;
}

int main(int argc, char **argv) {
	if (argc == 2 && strcmp(argv[1], "meta") == 0) return cmd_meta();
	if (argc == 3 && strcmp(argv[1], "decide-tsv") == 0) return each_row(argv[2], decide_row);
	if (argc == 3 && strcmp(argv[1], "install-tsv") == 0) return each_row(argv[2], install_row);
	if (argc == 3 && strcmp(argv[1], "machine-tsv") == 0) return each_row(argv[2], machine_row);
	if (argc == 3 && strcmp(argv[1], "hint-tsv") == 0) return each_row(argv[2], hint_row);
	if (argc == 3 && strcmp(argv[1], "decide-grid") == 0) return cmd_decide_grid(argv[2]);
	if (argc == 4 && strcmp(argv[1], "install-grid") == 0) return cmd_install_grid(argv[2], argv[3]);
	if (argc == 2 && strcmp(argv[1], "hash-sweep") == 0) return cmd_hash_sweep();
	if (argc == 2 && strcmp(argv[1], "numeric-sweep") == 0) return cmd_numeric_sweep();
	if (argc == 8 && strcmp(argv[1], "fuzz") == 0) return cmd_fuzz(argv[2], argv[3], argv[4], argv[5], argv[6], argv[7]);
	fprintf(stderr,
		"usage: %s meta | decide-tsv F | install-tsv F | machine-tsv F | hint-tsv F | decide-grid LIST\n"
		"       | install-grid LIST HASHES | hash-sweep | numeric-sweep | fuzz decide|install SEED COUNT FILE LICENSE MACHINE\n",
		argc > 0 ? argv[0] : "policy_driver");
	return 64;
}
