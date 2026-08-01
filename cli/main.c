/* sigil CLI — deliberately written in C.
 *
 * C physically cannot @import the Zig core, so this binary is forced through the
 * same FFI boundary that Mecha Validate and Mecha Rotshield will use. The
 * constraint is the point: a bypass is inexpressible rather than merely
 * discouraged.
 *
 * All I/O lives here. The Zig side is pure; everything that touches a file
 * descriptor, a terminal or the clock is below this line.
 */

/* Built as strict -std=c11, which hides POSIX declarations (fileno, isatty,
 * termios). Ask for them explicitly rather than relaxing to gnu11, so anything
 * genuinely non-portable that creeps in still gets caught. */
#if !defined(_WIN32)
#define _POSIX_C_SOURCE 200809L
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <errno.h>

#if defined(_WIN32)
#include <io.h>
#include <conio.h>
#define isatty _isatty
#define fileno _fileno
#else
#include <unistd.h>
#include <termios.h>
#include <fcntl.h>
#include <sys/stat.h>
#endif

#include "sigil.h"
#include "sigil_sign.h"
#include "exit_codes.h"
#include "json.h"

/* sysexits.h conventions, spelled out so scripts can rely on them. */
#define EX_OK        0
#define EX_REJECTED  1   /* the answer is "no": bad signature, wrong passphrase */
#define EX_USAGE     64
#define EX_NOINPUT   66
#define EX_IOERR     74

/* Internal sentinel, never a process exit code: the parser handled --help or
 * --about itself and the subcommand should stop without doing any work. Kept
 * negative so it cannot collide with a real sysexits value. */
#define EX_HELP_REQUESTED (-1)

/* write_all flags. Named because `write_all(p, b, n, 1, 0)` at a call site
 * tells a reader nothing about which 1 and which 0. */
#define WRITE_EXCLUSIVE 1u  /* fail if it already exists (O_EXCL) */
#define WRITE_SECRET    2u  /* create 0600, not 0644: key material */

#define MAX_INPUT (16u * 1024u * 1024u)   /* a license is bytes; this is mercy */

/* ── Presentation ───────────────────────────────────────────────────────── */

static int use_color = 0;   /* resolved in main from isatty + switches */
static int simple = 0;
static int quiet = 0;

#define C_OK   (use_color ? "\033[32m" : "")
#define C_BAD  (use_color ? "\033[31m" : "")
#define C_DIM  (use_color ? "\033[2m"  : "")
#define C_OFF  (use_color ? "\033[0m"  : "")

static const char *mark_ok(void)  { return simple ? "OK"     : "\xe2\x9c\x93"; }
static const char *mark_bad(void) { return simple ? "FAILED" : "\xe2\x9c\x97"; }

/* Status goes to stderr so stdout stays pipeable data. */
static void note(const char *fmt, ...) {
	if (quiet) return;
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
}

static void die_usage(const char *msg, const char *arg) {
	if (arg) fprintf(stderr, "sigil: %s: %s\n", msg, arg);
	else fprintf(stderr, "sigil: %s\n", msg);
	fprintf(stderr, "Try 'sigil --help'.\n");
}

/* ── Paths ──────────────────────────────────────────────────────────────── */

/* "-" and "@stdin" mean standard input; "-", "@stdout", "@stderr" likewise on
 * the way out. Every path-taking option honours these. */
static int is_stdin_path(const char *p) {
	return strcmp(p, "-") == 0 || strcmp(p, "@stdin") == 0;
}
static FILE *resolve_out(const char *p) {
	if (strcmp(p, "-") == 0 || strcmp(p, "@stdout") == 0) return stdout;
	if (strcmp(p, "@stderr") == 0) return stderr;
	return NULL;
}

/* Read a whole file (or stdin) into a NUL-terminated heap buffer. The NUL is
 * past the reported length so text callers can treat it as a C string while
 * binary callers still get an exact length. */
static int read_all(const char *path, unsigned char **out, size_t *out_len) {
	FILE *f = is_stdin_path(path) ? stdin : fopen(path, "rb");
	if (!f) {
		fprintf(stderr, "sigil: cannot read %s: %s\n", path, strerror(errno));
		return EX_NOINPUT;
	}

	size_t cap = 65536, len = 0;
	unsigned char *buf = malloc(cap);
	if (!buf) { if (f != stdin) fclose(f); fputs("sigil: out of memory\n", stderr); return EX_IOERR; }

	for (;;) {
		if (len == cap) {
			if (cap >= MAX_INPUT) {
				fprintf(stderr, "sigil: %s is larger than %u bytes\n", path, MAX_INPUT);
				free(buf); if (f != stdin) fclose(f);
				return EX_IOERR;
			}
			size_t ncap = cap * 2;
			unsigned char *nb = realloc(buf, ncap);
			if (!nb) { free(buf); if (f != stdin) fclose(f); fputs("sigil: out of memory\n", stderr); return EX_IOERR; }
			buf = nb; cap = ncap;
		}
		size_t n = fread(buf + len, 1, cap - len, f);
		len += n;
		if (n == 0) break;
	}
	int bad = ferror(f);
	if (f != stdin) fclose(f);
	if (bad) { free(buf); fprintf(stderr, "sigil: error reading %s\n", path); return EX_IOERR; }

	unsigned char *nb = realloc(buf, len + 1);
	if (nb) buf = nb;
	buf[len] = '\0';
	*out = buf;
	*out_len = len;
	return EX_OK;
}

/* Write bytes to a path, honoring @stdout/@stderr/-. See WRITE_EXCLUSIVE and
 * WRITE_SECRET for what the flags mean. */
static int write_all(const char *path, const void *buf, size_t len, int flags) {
	const int exclusive   = (flags & WRITE_EXCLUSIVE) != 0;
	const int secret_mode = (flags & WRITE_SECRET) != 0;
	FILE *f = resolve_out(path);
	int close_it = 0;
	if (!f) {
		/* One open(2) decides existence AND mode.
		 *
		 * The previous version probed with fopen("rb") and then opened for
		 * writing, which is a TOCTOU: the file can appear between the two
		 * calls and get clobbered anyway — and the thing being clobbered is a
		 * signing key with no other copy. O_EXCL makes the kernel do the
		 * check atomically.
		 *
		 * It also fixes the mode. fopen() creates 0666 & ~umask, so a secret
		 * key landed at 0644 under a normal umask and 0666 under a permissive
		 * one: readable by every account on the machine. Encryption at rest
		 * still applies, but it means an attacker needs only the passphrase
		 * and nothing else. Passing the mode to open(2) does not consult the
		 * umask for the bits it denies. */
#if defined(_WIN32)
		f = fopen(path, exclusive ? "wbx" : "wb");
#else
		const int open_flags = O_WRONLY | O_CREAT | O_TRUNC | (exclusive ? O_EXCL : 0);
		const mode_t mode = secret_mode ? 0600 : 0644;
		int fd = open(path, open_flags, mode);
		if (fd < 0 && errno == EEXIST) {
			fprintf(stderr, "sigil: %s already exists; refusing to overwrite it.\n", path);
			fprintf(stderr, "       Losing a signing key is unrecoverable. Move it aside, or pass --force.\n");
			return EX_IOERR;
		}
		/* --force reuses the same open(2) so the mode is still explicit, and
		 * an existing 0644 file gets tightened rather than inherited. */
		if (fd >= 0 && secret_mode && fchmod(fd, 0600) != 0) {
			fprintf(stderr, "sigil: cannot restrict permissions on %s: %s\n",
				path, strerror(errno));
			close(fd);
			return EX_IOERR;
		}
		f = (fd >= 0) ? fdopen(fd, "wb") : NULL;
		if (!f && fd >= 0) close(fd);
#endif
		if (!f) {
			fprintf(stderr, "sigil: cannot write %s: %s\n", path, strerror(errno));
			return EX_IOERR;
		}
		close_it = 1;
	}
	size_t n = len ? fwrite(buf, 1, len, f) : 0;
	int bad = (n != len) || ferror(f);
	if (close_it) bad |= (fclose(f) != 0);
	else bad |= (fflush(f) != 0);
	if (bad) { fprintf(stderr, "sigil: error writing %s\n", path); return EX_IOERR; }
	return EX_OK;
}

/* ── Passphrases ────────────────────────────────────────────────────────── */

static void wipe(void *p, size_t n) {
	volatile unsigned char *v = (volatile unsigned char *)p;
	while (n--) *v++ = 0;
}

static void chomp(char *s, size_t *len) {
	while (*len && (s[*len - 1] == '\n' || s[*len - 1] == '\r')) s[--(*len)] = '\0';
}

/* Read a passphrase without echoing it. Falls back to a plain read when stdin
 * is not a terminal, so `echo pw | sigil sign ...` works in a pipeline. */
static int prompt_passphrase(const char *prompt, char *buf, size_t cap, size_t *out_len) {
	fputs(prompt, stderr);
	fflush(stderr);

	int restore = 0;
#if !defined(_WIN32)
	struct termios old, quiet_term;
	if (isatty(fileno(stdin)) && tcgetattr(fileno(stdin), &old) == 0) {
		quiet_term = old;
		quiet_term.c_lflag &= ~(tcflag_t)ECHO;
		if (tcsetattr(fileno(stdin), TCSAFLUSH, &quiet_term) == 0) restore = 1;
	}
#endif
	char *got = fgets(buf, (int)cap, stdin);
#if !defined(_WIN32)
	if (restore) tcsetattr(fileno(stdin), TCSAFLUSH, &old);
#endif
	fputs("\n", stderr);

	if (!got) { fputs("sigil: no passphrase supplied\n", stderr); return EX_NOINPUT; }
	*out_len = strlen(buf);
	chomp(buf, out_len);
	return EX_OK;
}

/* Either from --passphrase-file (which may be "-"/"@stdin") or interactively. */
static int obtain_passphrase(const char *pass_file, const char *prompt,
                             char **out, size_t *out_len) {
	if (pass_file) {
		unsigned char *raw = NULL;
		size_t n = 0;
		int rc = read_all(pass_file, &raw, &n);
		if (rc != EX_OK) return rc;
		chomp((char *)raw, &n);
		*out = (char *)raw;
		*out_len = n;
		return EX_OK;
	}
	char *buf = malloc(1024);
	if (!buf) { fputs("sigil: out of memory\n", stderr); return EX_IOERR; }
	size_t n = 0;
	int rc = prompt_passphrase(prompt, buf, 1024, &n);
	if (rc != EX_OK) { free(buf); return rc; }
	*out = buf;
	*out_len = n;
	return EX_OK;
}

/* ── Help ───────────────────────────────────────────────────────────────── */

static int usage(FILE *out) {
	fprintf(out,
		"Usage: sigil <command> [options]\n"
		"\n"
		"Verify and mint Ed25519-signed documents. The signature covers the payload\n"
		"bytes exactly as supplied, so the JSON envelope may be reformatted freely.\n"
		"\n"
		"Commands:\n"
		"  verify <envelope> --pubkey <path>   check a signature; payload to stdout\n"
		"  sign <payload> --key <keyfile>      sign bytes into an envelope\n"
		"  keygen --out <keyfile>              mint a new signing key\n"
		"  pubkey --key <keyfile>              print the public key to embed\n"
		"\n"
		"Common options:\n"
		"  -o, --out <path>       where to write; '-'/'@stdout' for standard output\n"
		"      --passphrase-file <path>   read the passphrase instead of prompting\n"
		"      --json             machine-readable result on stdout\n"
		"  -q, --quiet            no status output; rely on the exit code\n"
		"      --no-color         never emit ANSI color\n"
		"      --simple           plain ASCII, no color, no symbols\n"
		"  -h, --help             this help\n"
		"      --about            one-line description, version, platform\n"
		"\n"
		"Paths: '-' or '@stdin' reads standard input; '-', '@stdout' or '@stderr'\n"
		"writes there. Anything after '--' is treated as a path, never a switch.\n"
		"\n"
		"Exit codes: 0 verified; 1 NOT AUTHENTIC (the signature does not check\n"
		"out); 64 usage; 65 the input is not a well-formed envelope; 66 missing\n"
		"input; 70 internal error; 74 I/O; 75 temporary failure, retry may work.\n"
		"Only 1 ever means a document was rejected on its merits.\n");
	return EX_USAGE;
}

static void about(void) {
	printf("sigil %s — verify Ed25519-signed documents (%s/%s)\n",
		sigil_version(),
#if defined(__linux__)
		"linux",
#elif defined(__APPLE__)
		"macos",
#elif defined(_WIN32)
		"windows",
#else
		"unknown",
#endif
#if defined(__x86_64__) || defined(_M_X64)
		"x86_64"
#elif defined(__aarch64__) || defined(_M_ARM64)
		"aarch64"
#else
		"unknown"
#endif
	);
}

/* ── Argument parsing ───────────────────────────────────────────────────── */

typedef struct {
	const char *positional;      /* the input document, if any */
	const char *pubkey;
	const char *key;
	const char *out;
	const char *pubkey_out;
	const char *passphrase_file;
	const char *format;
	int json;
	int force;
} Opts;

/* Windows callers may spell switches with a leading '/'. Normalize so the rest
 * of the parser only ever sees the Unix form. */
static const char *normalize(const char *a, char *scratch, size_t cap) {
	if (a[0] != '/' || a[1] == '\0') return a;
	/* Only for short, switch-looking tokens — never mangle an absolute path. */
	if (strchr(a + 1, '/') || strlen(a) > 24) return a;
	if (snprintf(scratch, cap, "-%s", a + 1) >= (int)cap) return a;
	return scratch;
}

#define NEEDS_VALUE(name) do { \
	if (i + 1 >= argc) { die_usage("option needs a value", name); return EX_USAGE; } \
} while (0)

/* Later arguments override earlier ones, by construction: every option simply
 * assigns, and the last assignment wins. */
static int parse_opts(int argc, char *argv[], int start, Opts *o) {
	int no_more_switches = 0;
	char scratch[32];

	for (int i = start; i < argc; i++) {
		const char *a = no_more_switches ? argv[i] : normalize(argv[i], scratch, sizeof scratch);

		if (!no_more_switches && strcmp(a, "--") == 0) { no_more_switches = 1; continue; }

		if (!no_more_switches && a[0] == '-' && a[1] != '\0' && strcmp(a, "-") != 0) {
			/* Recognized on EVERY subcommand, not just as argv[1]. The help
			 * text advertises them under "Common options:", and someone typing
			 * --help is asking how to use the thing — answering "you used it
			 * wrong" would be both unhelpful and circular. Handled before any
			 * required-option check for the same reason. */
			if (!strcmp(a, "-h") || !strcmp(a, "--help") || !strcmp(a, "-?")) {
				usage(stdout);
				return EX_HELP_REQUESTED;
			}
			if (!strcmp(a, "--about")) { about(); return EX_HELP_REQUESTED; }
			if (!strcmp(a, "--version")) { printf("%s\n", sigil_version()); return EX_HELP_REQUESTED; }

			if (!strcmp(a, "--pubkey"))              { NEEDS_VALUE(a); o->pubkey = argv[++i]; }
			else if (!strcmp(a, "--key") || !strcmp(a, "-k")) { NEEDS_VALUE(a); o->key = argv[++i]; }
			else if (!strcmp(a, "--out") || !strcmp(a, "-o")) { NEEDS_VALUE(a); o->out = argv[++i]; }
			else if (!strcmp(a, "--pubkey-out"))     { NEEDS_VALUE(a); o->pubkey_out = argv[++i]; }
			else if (!strcmp(a, "--passphrase-file")){ NEEDS_VALUE(a); o->passphrase_file = argv[++i]; }
			else if (!strcmp(a, "--format") || !strcmp(a, "-f")) { NEEDS_VALUE(a); o->format = argv[++i]; }
			else if (!strcmp(a, "--json"))           { o->json = 1; }
			else if (!strcmp(a, "--force"))          { o->force = 1; }
			else if (!strcmp(a, "--quiet") || !strcmp(a, "-q")) { quiet = 1; }
			else if (!strcmp(a, "--no-color") || !strcmp(a, "--no-colour") || !strcmp(a, "--no-ansi")) { use_color = 0; }
			else if (!strcmp(a, "--simple"))         { simple = 1; use_color = 0; }
			else { die_usage("unknown option", argv[i]); return EX_USAGE; }
			continue;
		}

		if (o->positional) { die_usage("unexpected extra argument", argv[i]); return EX_USAGE; }
		o->positional = argv[i];
	}
	return EX_OK;
}

/* ── verify ─────────────────────────────────────────────────────────────── */

static int cmd_verify(int argc, char *argv[]) {
	Opts o = {0};
	int rc = parse_opts(argc, argv, 2, &o);
	if (rc == EX_HELP_REQUESTED) return EX_OK;
	if (rc != EX_OK) return rc;

	if (!o.positional) { die_usage("verify needs an envelope path (use '-' for stdin)", NULL); return EX_USAGE; }
	if (!o.pubkey)     { die_usage("verify needs --pubkey <path>", NULL); return EX_USAGE; }

	unsigned char *env = NULL, *pubtext = NULL, *payload = NULL;
	size_t env_len = 0, pubtext_len = 0;
	int status = EX_IOERR;

	rc = read_all(o.positional, &env, &env_len);
	if (rc != EX_OK) { status = rc; goto done; }
	rc = read_all(o.pubkey, &pubtext, &pubtext_len);
	if (rc != EX_OK) { status = rc; goto done; }

	unsigned char pk[64];
	if (sigil_public_key_len() > sizeof pk) { status = EX_IOERR; goto done; }
	int r = sigil_public_key_from_text((const char *)pubtext, pubtext_len, pk);
	if (r != SIGIL_OK) {
		fprintf(stderr, "sigil: %s is not a public key: %s\n", o.pubkey, sigil_strerror(r));
		status = EX_USAGE;
		goto done;
	}

	/* printable-binary only ever expands, so the envelope's length is always a
	 * sufficient buffer for the payload — no two-pass sizing needed. */
	payload = malloc(env_len + 1);
	if (!payload) { fputs("sigil: out of memory\n", stderr); status = EX_IOERR; goto done; }

	size_t payload_len = 0;
	r = sigil_verify_envelope((const char *)env, env_len, pk, payload, env_len, &payload_len);

	if (r != SIGIL_OK) {
		if (o.json) {
			char esc[512];
			sigil_json_escape(esc, sizeof esc, sigil_strerror(r));
			printf("{\"verified\":false,\"code\":%d,\"error\":\"%s\"}\n", r, esc);
		} else if (!quiet) {
			/* Only say "not authentic" when that is what actually happened.
			 * Anything else gets phrased as an inability to decide, because a
			 * customer reading "FAILED" next to their paid license will act on
			 * it — and a transient allocation failure is not a forgery. */
			if (r == SIGIL_ERR_BAD_SIGNATURE) {
				fprintf(stderr, "%s%s%s %s: %s\n", C_BAD, mark_bad(), C_OFF,
					o.positional, sigil_strerror(r));
			} else {
				fprintf(stderr, "sigil: could not verify %s: %s\n",
					o.positional, sigil_strerror(r));
			}
		}
		status = sigil_verify_exit_code(r);
		goto done;
	}

	if (o.json) {
		printf("{\"verified\":true,\"payload_bytes\":%zu}\n", payload_len);
	} else {
		/* The payload IS the output, and --quiet does not suppress it.
		 * --quiet means "no status output; rely on the exit code", per both
		 * --help and the README. It used to skip this branch, so
		 * `sigil verify --quiet` discarded the one thing it was asked to
		 * produce. Data goes to stdout; commentary goes to stderr, and only
		 * the commentary is optional. */
		status = write_all(o.out ? o.out : "-", payload, payload_len, 0);
		if (status != EX_OK) goto done;
	}

	if (!o.json && !quiet) {
		fprintf(stderr, "%s%s%s verified %s (%zu byte%s)\n", C_OK, mark_ok(), C_OFF,
			o.positional, payload_len, payload_len == 1 ? "" : "s");
	}
	status = EX_OK;

done:
	free(env); free(pubtext); free(payload);
	return status;
}

/* ── sign ───────────────────────────────────────────────────────────────── */

static int cmd_sign(int argc, char *argv[]) {
	Opts o = {0};
	int rc = parse_opts(argc, argv, 2, &o);
	if (rc == EX_HELP_REQUESTED) return EX_OK;
	if (rc != EX_OK) return rc;

	if (!o.positional) { die_usage("sign needs a payload path (use '-' for stdin)", NULL); return EX_USAGE; }
	if (!o.key)        { die_usage("sign needs --key <keyfile>", NULL); return EX_USAGE; }
	if (is_stdin_path(o.positional) && o.passphrase_file && is_stdin_path(o.passphrase_file)) {
		die_usage("payload and passphrase cannot both come from stdin", NULL);
		return EX_USAGE;
	}

	unsigned char *keyfile = NULL, *payload = NULL;
	char *pass = NULL, *env = NULL;
	size_t keyfile_len = 0, payload_len = 0, pass_len = 0;
	int status = EX_IOERR;

	rc = read_all(o.key, &keyfile, &keyfile_len);
	if (rc != EX_OK) { status = rc; goto done; }
	rc = read_all(o.positional, &payload, &payload_len);
	if (rc != EX_OK) { status = rc; goto done; }
	rc = obtain_passphrase(o.passphrase_file, "Passphrase: ", &pass, &pass_len);
	if (rc != EX_OK) { status = rc; goto done; }

	/* Envelope is the encoded payload plus a signature and a little JSON.
	 * Three bytes per payload byte is printable-binary's worst case. */
	size_t cap = payload_len * 3 + 1024;
	env = malloc(cap);
	if (!env) { fputs("sigil: out of memory\n", stderr); status = EX_IOERR; goto done; }

	size_t env_len = 0;
	int r = sigil_seal((const char *)keyfile, keyfile_len, pass, pass_len,
	                   payload, payload_len, env, cap, &env_len);
	if (r != SIGIL_OK) {
		fprintf(stderr, "sigil: %s%s%s cannot sign: %s\n", C_BAD, mark_bad(), C_OFF,
			sigil_sign_strerror(r));
		status = (r == SIGIL_ERR_AUTH_FAILED) ? EX_REJECTED : EX_IOERR;
		goto done;
	}

	status = write_all(o.out ? o.out : "-", env, env_len, 0);
	if (status != EX_OK) goto done;

	note("%s%s%s signed %s (%zu byte%s) -> %s\n", C_OK, mark_ok(), C_OFF,
		o.positional, payload_len, payload_len == 1 ? "" : "s",
		o.out ? o.out : "stdout");
	status = EX_OK;

done:
	if (pass) { wipe(pass, pass_len); free(pass); }
	free(keyfile); free(payload); free(env);
	return status;
}

/* ── keygen ─────────────────────────────────────────────────────────────── */

static int cmd_keygen(int argc, char *argv[]) {
	Opts o = {0};
	int rc = parse_opts(argc, argv, 2, &o);
	if (rc == EX_HELP_REQUESTED) return EX_OK;
	if (rc != EX_OK) return rc;

	const char *key_path = o.out ? o.out : o.positional;
	if (!key_path) { die_usage("keygen needs --out <keyfile>", NULL); return EX_USAGE; }

	char pub_default[1024];
	const char *pub_path = o.pubkey_out;
	if (!pub_path) {
		if (snprintf(pub_default, sizeof pub_default, "%s.pub", key_path) >= (int)sizeof pub_default) {
			fputs("sigil: key path is too long\n", stderr);
			return EX_USAGE;
		}
		pub_path = pub_default;
	}

	char *pass = NULL, *confirm = NULL, *keyfile = NULL;
	size_t pass_len = 0, confirm_len = 0;
	int status = EX_IOERR;

	rc = obtain_passphrase(o.passphrase_file, "Passphrase for the new key: ", &pass, &pass_len);
	if (rc != EX_OK) { status = rc; goto done; }

	/* Only confirm when we prompted. A typo in an interactive passphrase makes
	 * the key permanently unopenable, and there is no recovery path. */
	if (!o.passphrase_file) {
		rc = obtain_passphrase(NULL, "Confirm passphrase: ", &confirm, &confirm_len);
		if (rc != EX_OK) { status = rc; goto done; }
		if (pass_len != confirm_len || memcmp(pass, confirm, pass_len) != 0) {
			fputs("sigil: passphrases do not match; no key was written.\n", stderr);
			status = EX_USAGE;
			goto done;
		}
	}

	keyfile = malloc(4096);
	if (!keyfile) { fputs("sigil: out of memory\n", stderr); status = EX_IOERR; goto done; }

	size_t keyfile_len = 0;
	int r = sigil_keygen(pass, pass_len, keyfile, 4096, &keyfile_len);
	if (r != SIGIL_OK) {
		fprintf(stderr, "sigil: cannot generate a key: %s\n", sigil_sign_strerror(r));
		status = (r == SIGIL_ERR_EMPTY_PASSPHRASE) ? EX_USAGE : EX_IOERR;
		goto done;
	}

	status = write_all(key_path, keyfile, keyfile_len,
		WRITE_SECRET | (o.force ? 0 : WRITE_EXCLUSIVE));
	if (status != EX_OK) goto done;

	unsigned char pk[64];
	r = sigil_keyfile_public_key(keyfile, keyfile_len, pass, pass_len, pk);
	if (r != SIGIL_OK) {
		fprintf(stderr, "sigil: wrote %s but could not derive its public key: %s\n",
			key_path, sigil_sign_strerror(r));
		status = EX_IOERR;
		goto done;
	}

	char pub_text[512];
	size_t pub_text_len = 0;
	r = sigil_public_key_to_text(pk, pub_text, sizeof pub_text, &pub_text_len);
	if (r != SIGIL_OK) {
		fprintf(stderr, "sigil: cannot render the public key: %s\n", sigil_strerror(r));
		status = EX_IOERR;
		goto done;
	}

	status = write_all(pub_path, pub_text, pub_text_len,
		o.force ? 0 : WRITE_EXCLUSIVE);
	if (status != EX_OK) goto done;

	note("%s%s%s wrote %s (secret, encrypted) and %s (public)\n",
		C_OK, mark_ok(), C_OFF, key_path, pub_path);
	note("%s  Back up both. Lose the keyfile or the passphrase and you cannot\n"
	     "  sign again; every already-issued license keeps working.%s\n", C_DIM, C_OFF);
	status = EX_OK;

done:
	if (pass) { wipe(pass, pass_len); free(pass); }
	if (confirm) { wipe(confirm, confirm_len); free(confirm); }
	free(keyfile);
	return status;
}

/* ── pubkey ─────────────────────────────────────────────────────────────── */

static void emit_byte_array(const char *decl, const unsigned char *pk, size_t n,
                            const char *open, const char *close) {
	printf("%s%s", decl, open);
	for (size_t i = 0; i < n; i++) {
		if (i % 8 == 0) printf("\n    ");
		printf("0x%02x,%s", pk[i], (i % 8 == 7 || i + 1 == n) ? "" : " ");
	}
	printf("\n%s\n", close);
}

static int cmd_pubkey(int argc, char *argv[]) {
	Opts o = {0};
	int rc = parse_opts(argc, argv, 2, &o);
	if (rc == EX_HELP_REQUESTED) return EX_OK;
	if (rc != EX_OK) return rc;

	const char *src = o.key ? o.key : (o.pubkey ? o.pubkey : o.positional);
	if (!src) { die_usage("pubkey needs --key <keyfile> or --pubkey <path>", NULL); return EX_USAGE; }

	unsigned char *raw = NULL;
	size_t raw_len = 0;
	rc = read_all(src, &raw, &raw_len);
	if (rc != EX_OK) return rc;

	unsigned char pk[64];
	int r;
	if (o.key) {
		/* Deriving the key from a keyfile means decrypting it. That is the
		 * point: the alternative was a stored field anyone who could write the
		 * file could swap, which decided what a developer embedded in a shipped
		 * product. Reading the sibling .pub file still needs no passphrase. */
		char *pass = NULL;
		size_t pass_len = 0;
		rc = obtain_passphrase(o.passphrase_file, "Passphrase: ", &pass, &pass_len);
		if (rc != EX_OK) { free(raw); return rc; }
		r = sigil_keyfile_public_key((const char *)raw, raw_len, pass, pass_len, pk);
		wipe(pass, pass_len);
		free(pass);
	} else {
		r = sigil_public_key_from_text((const char *)raw, raw_len, pk);
	}

	if (r != SIGIL_OK) {
		fprintf(stderr, "sigil: cannot read a public key from %s: %s\n", src,
			o.key ? sigil_sign_strerror(r) : sigil_strerror(r));
		free(raw);
		return (o.key && r == SIGIL_ERR_AUTH_FAILED) ? EX_REJECTED : EX_USAGE;
	}
	free(raw);

	const size_t n = sigil_public_key_len();
	const char *fmt = o.format ? o.format : "text";

	if (!strcmp(fmt, "text")) {
		char text[512];
		size_t len = 0;
		r = sigil_public_key_to_text(pk, text, sizeof text, &len);
		if (r != SIGIL_OK) { fprintf(stderr, "sigil: %s\n", sigil_strerror(r)); return EX_IOERR; }
		return write_all(o.out ? o.out : "-", text, len, 0);
	}
	if (!strcmp(fmt, "hex")) {
		for (size_t i = 0; i < n; i++) printf("%02x", pk[i]);
		printf("\n");
		return EX_OK;
	}
	if (!strcmp(fmt, "raw")) {
		return write_all(o.out ? o.out : "-", pk, n, 0);
	}
	if (!strcmp(fmt, "c")) {
		emit_byte_array("static const unsigned char SIGIL_PUBLIC_KEY[32] = ", pk, n, "{", "};");
		return EX_OK;
	}
	if (!strcmp(fmt, "zig")) {
		emit_byte_array("pub const sigil_public_key: [32]u8 = .", pk, n, "{", "};");
		return EX_OK;
	}

	die_usage("unknown --format (want text, hex, raw, c or zig)", fmt);
	return EX_USAGE;
}

/* ── main ───────────────────────────────────────────────────────────────── */

int main(int argc, char *argv[]) {
	use_color = isatty(fileno(stderr));
	if (getenv("NO_COLOR")) use_color = 0;

	if (argc < 2) { usage(stderr); return EX_USAGE; }

	char scratch[32];
	const char *cmd = normalize(argv[1], scratch, sizeof scratch);

	if (!strcmp(cmd, "-h") || !strcmp(cmd, "--help") || !strcmp(cmd, "-?")) {
		usage(stdout);
		return EX_OK;
	}
	if (!strcmp(cmd, "--about")) { about(); return EX_OK; }
	if (!strcmp(cmd, "--version")) { printf("%s\n", sigil_version()); return EX_OK; }

	if (!strcmp(cmd, "verify")) return cmd_verify(argc, argv);
	if (!strcmp(cmd, "sign"))   return cmd_sign(argc, argv);
	if (!strcmp(cmd, "keygen")) return cmd_keygen(argc, argv);
	if (!strcmp(cmd, "pubkey")) return cmd_pubkey(argc, argv);

	fprintf(stderr, "sigil: unknown command: %s\n", argv[1]);
	usage(stderr);
	return EX_USAGE;
}
