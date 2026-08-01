#ifndef SIGIL_CLI_JSON_H
#define SIGIL_CLI_JSON_H

#include <stddef.h>

/* JSON string escaping for `--json` output.
 *
 * `sigil verify --json` used to splice sigil_strerror() straight into a JSON
 * string literal. One of those messages is `sigtype is not "Ed25519"`, which
 * produced:
 *
 *   {"verified":false,"code":-6,"error":"sigtype is not "Ed25519""}
 *
 * jq rejects that. The whole point of --json is that something downstream
 * parses it, so emitting invalid JSON on an error path means the consumer
 * fails at exactly the moment it most needs to read the reason.
 *
 * Note this is NOT the printable-binary trick the envelope uses. That encoding
 * exists to carry arbitrary BYTES through a JSON string; these are
 * human-readable diagnostics, and a reader wants to see `"Ed25519"` rather
 * than a glyph. RFC 8259 escaping is the right tool here.
 *
 * Writes at most `cap` bytes including the NUL and always NUL-terminates when
 * cap > 0. Returns the number of bytes the full escaping needs, excluding the
 * NUL, so a caller can detect truncation the way snprintf does.
 */
static inline size_t sigil_json_escape(char *out, size_t cap, const char *in) {
	static const char hex[] = "0123456789abcdef";
	size_t need = 0;

	#define EMIT(ch) do { \
		if (need + 1 < cap) out[need] = (ch); \
		need++; \
	} while (0)

	for (const unsigned char *p = (const unsigned char *)in; *p; p++) {
		switch (*p) {
		case '"':  EMIT('\\'); EMIT('"');  break;
		case '\\': EMIT('\\'); EMIT('\\'); break;
		case '\b': EMIT('\\'); EMIT('b');  break;
		case '\f': EMIT('\\'); EMIT('f');  break;
		case '\n': EMIT('\\'); EMIT('n');  break;
		case '\r': EMIT('\\'); EMIT('r');  break;
		case '\t': EMIT('\\'); EMIT('t');  break;
		default:
			if (*p < 0x20) {
				/* RFC 8259 requires escaping everything below 0x20. The ones
				 * without a short form get \u00XX. */
				EMIT('\\'); EMIT('u'); EMIT('0'); EMIT('0');
				EMIT(hex[(*p >> 4) & 0xf]);
				EMIT(hex[*p & 0xf]);
			} else {
				/* >= 0x80 passes through: these messages are ASCII today, and
				 * a UTF-8 sequence is already valid inside a JSON string. */
				EMIT((char)*p);
			}
			break;
		}
	}
	#undef EMIT

	if (cap > 0) out[need < cap ? need : cap - 1] = '\0';
	return need;
}

#endif /* SIGIL_CLI_JSON_H */
