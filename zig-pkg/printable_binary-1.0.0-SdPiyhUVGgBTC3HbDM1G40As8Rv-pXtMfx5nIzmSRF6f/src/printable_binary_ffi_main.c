/*
 * PrintableBinary - Thin C wrapper for Zig FFI
 *
 * This is a minimal CLI that calls the Zig library via C FFI.
 * It handles argument parsing and I/O, delegating all encoding/decoding
 * to the Zig implementation.
 *
 * Build: Link against the Zig static library (libprintable_binary.a)
 */

#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#if defined(_WIN32)
#include <windows.h>
#else
#include <unistd.h>
#endif
#include <ctype.h>
#include <errno.h>
#include <time.h>

#include "printable_binary.h"
#include "container_json.h"

/* Program options */
typedef struct {
    bool decode_mode;
    bool passthrough_mode;
    bool spaces_mode;
    bool tabs_mode;
    bool crlf_mode;
    bool strip_whitespace;
    bool hexlike_mode;
    bool format_mode;
    bool help_mode;
    int format_group;
    int format_groups_per_line;
    int mappings_mode; /* 0=none, 1=table, 2=json, 3=csv */
    char *preserve_chars;
    char *input_file;
    bool has_range_start;
    bool has_range_end;
    int64_t range_start;
    int64_t range_end;
    bool no_double_encode_check;
    bool container_mode;
} options_t;

static bool env_var_truthy(const char *value) {
    if (!value || !*value) return false;
    while (*value && isspace((unsigned char)*value)) value++;
    if (!*value) return false;
    if (*value == '1') return true;
    char lower[8] = {0};
    for (int i = 0; i < 7 && value[i]; i++) {
        lower[i] = (char)tolower((unsigned char)value[i]);
    }
    return strcmp(lower, "true") == 0 || strcmp(lower, "yes") == 0;
}

/// Return a monotonic wall-clock timestamp for comparable CLI pipeline rates.
static double throughput_now_seconds(void) {
#if defined(_WIN32)
    static LARGE_INTEGER frequency;
    LARGE_INTEGER counter;
    if (frequency.QuadPart == 0) QueryPerformanceFrequency(&frequency);
    QueryPerformanceCounter(&counter);
    return (double)counter.QuadPart / (double)frequency.QuadPart;
#else
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) == 0) {
        return (double)ts.tv_sec + (double)ts.tv_nsec / 1000000000.0;
    }
    return (double)clock() / (double)CLOCKS_PER_SEC;
#endif
}

/// Emit input-byte throughput after output is flushed so UTF-8 expansion is explicit.
static void print_input_throughput(bool enabled, size_t input_bytes_read, double started_at) {
    if (!enabled) return;
    double elapsed = throughput_now_seconds() - started_at;
    if (elapsed < 0.0005) elapsed = 0.0005;
    double megabytes = (double)input_bytes_read / 1000000.0;
    fprintf(stderr, "Input throughput: %.2f MB read in %.3f s (%.2f MB/s)\n",
            megabytes, elapsed, megabytes / elapsed);
}

static void print_usage(const char *name) {
    fprintf(stderr, "PrintableBinary (Zig core) - Encode binary data as printable UTF-8\n\n");
    fprintf(stderr, "Usage: %s [options] [file]\n", name);
    fprintf(stderr, "Options:\n");
    fprintf(stderr, "  -d, --decode       Decode mode (default is encode mode)\n");
    fprintf(stderr, "  -p, --passthrough  Pass input to stdout unchanged, send encoded data to stderr\n");
    fprintf(stderr, "  -X, --hexlike      Hexlike mode (passthrough ASCII as-is, other bytes as \xce\x9f\xcf\x87-prefixed hex)\n");
    fprintf(stderr, "  -C, --container    Container mode: encode a file to a self-verifying .pbf.json\n");
    fprintf(stderr, "                     (keeps filename + crc32). With -d, decode a container back.\n");
    fprintf(stderr, "\nEncode options (preserve literal characters instead of encoding):\n");
    fprintf(stderr, "  -s, --spaces       Preserve literal spaces\n");
    fprintf(stderr, "  -t, --tabs         Preserve literal tabs\n");
    fprintf(stderr, "  -n, --crlf         Preserve literal CR/LF\n");
    fprintf(stderr, "  -w, --preserve-whitespace  Shorthand for -stn\n");
    fprintf(stderr, "  -P, --preserve=CHARS       Preserve specific characters\n");
    fprintf(stderr, "\nRange options (select byte range from input before processing):\n");
    fprintf(stderr, "  --range X-Y              Byte range, 0-indexed inclusive (e.g., --range 0-9)\n");
    fprintf(stderr, "  --start X                Start offset (negative = from end, like xxd -s)\n");
    fprintf(stderr, "  --end Y                  End offset (inclusive)\n");
    fprintf(stderr, "  X-Y (positional)         Shorthand for --range X-Y\n");
    fprintf(stderr, "  Hex offsets supported: --range 0x0A-0xFF\n");
    fprintf(stderr, "  Omitted bounds: --range -9 (first 10 bytes), --range 10- (byte 10 to EOF)\n");
    fprintf(stderr, "\nEncode detection:\n");
    fprintf(stderr, "  --no-double-encode-check   Skip detection of already-encoded input\n");
    fprintf(stderr, "\nDecode options:\n");
    fprintf(stderr, "  -S, --strip-whitespace     Strip whitespace before decoding\n");
    fprintf(stderr, "\nFormat and output options:\n");
    fprintf(stderr, "  -f[=NxM], --format[=NxM]   Format output in groups (default: 8x10)\n");
    fprintf(stderr, "  --mappings         Show the byte-to-character mapping table\n");
    fprintf(stderr, "  --mappings-json    Output mappings as JSON\n");
    fprintf(stderr, "  --mappings-csv     Output mappings as CSV\n");
    fprintf(stderr, "  -h, --help         Show this help\n");
}

static void parse_format_spec(options_t *opts, const char *spec) {
    if (!spec || !*spec) {
        fprintf(stderr, "Error: --format requires a value like 8x10\n");
        exit(1);
    }
    while (*spec == '=' || isspace((unsigned char)*spec)) spec++;
    int group = 0, per_line = 0;
    if (sscanf(spec, "%dx%d", &group, &per_line) != 2 || group <= 0 || per_line <= 0) {
        fprintf(stderr, "Invalid format specification: %s\n", spec);
        exit(1);
    }
    opts->format_mode = true;
    opts->format_group = group;
    opts->format_groups_per_line = per_line;
}

// Parse offset value (supports hex 0x prefix and decimal, optionally negative)
static bool parse_offset_value(const char *s, int64_t *out) {
    if (!s || !*s) return false;
    char *endptr;
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        unsigned long long v = strtoull(s, &endptr, 16);
        if (*endptr != '\0') return false;
        *out = (int64_t)v;
        return true;
    }
    long long v = strtoll(s, &endptr, 10);
    if (*endptr != '\0') return false;
    *out = (int64_t)v;
    return true;
}

// Parse a range spec "X-Y", "-Y", "X-"
static bool parse_range_spec(const char *spec, bool *has_start, int64_t *start, bool *has_end, int64_t *end) {
    if (!spec || !*spec) return false;
    const char *sep = NULL;
    if (spec[0] == '-') {
        sep = spec;
    } else {
        const char *p = spec;
        if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
            p += 2;
            while (*p && isxdigit((unsigned char)*p)) p++;
        } else {
            while (*p && isdigit((unsigned char)*p)) p++;
        }
        if (*p == '-') {
            sep = p;
        } else {
            return false;
        }
    }
    *has_start = false;
    *has_end = false;
    if (sep > spec) {
        char start_buf[64];
        size_t slen = (size_t)(sep - spec);
        if (slen >= sizeof(start_buf)) return false;
        memcpy(start_buf, spec, slen);
        start_buf[slen] = '\0';
        if (!parse_offset_value(start_buf, start)) return false;
        *has_start = true;
    }
    const char *end_str = sep + 1;
    if (*end_str != '\0') {
        if (!parse_offset_value(end_str, end)) return false;
        *has_end = true;
    }
    return true;
}

static bool is_positional_range(const char *s) {
    if (!s || !*s || s[0] == '-') return false;
    const char *p = s;
    if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
        p += 2;
        while (*p && isxdigit((unsigned char)*p)) p++;
    } else if (isdigit((unsigned char)*p)) {
        while (*p && isdigit((unsigned char)*p)) p++;
    } else {
        return false;
    }
    return *p == '-';
}

static options_t parse_options(int argc, char *argv[]) {
    options_t opts = {
        .decode_mode = false,
        .passthrough_mode = false,
        .spaces_mode = false,
        .tabs_mode = false,
        .crlf_mode = false,
        .strip_whitespace = false,
        .format_mode = false,
        .help_mode = false,
        .format_group = 8,
        .format_groups_per_line = 10,
        .mappings_mode = 0,
        .preserve_chars = NULL,
        .input_file = NULL,
        .has_range_start = false,
        .has_range_end = false,
        .range_start = 0,
        .range_end = 0,
        .no_double_encode_check = false
    };

    for (int i = 1; i < argc; i++) {
        char *arg = argv[i];

        if (strcmp(arg, "--") == 0) {
            if (i + 1 < argc) opts.input_file = argv[++i];
            break;
        }

        if (arg[0] != '-' || strcmp(arg, "-") == 0) {
            if (is_positional_range(arg)) {
                bool hs, he;
                int64_t sv, ev;
                if (parse_range_spec(arg, &hs, &sv, &he, &ev)) {
                    if (hs) { opts.has_range_start = true; opts.range_start = sv; }
                    if (he) { opts.has_range_end = true; opts.range_end = ev; }
                    continue;
                }
            }
            if (opts.input_file) {
                fprintf(stderr, "Error: Multiple input files\n");
                exit(1);
            }
            opts.input_file = arg;
            continue;
        }

        if (arg[1] == '-') {
            /* Long options */
            const char *name = arg + 2;
            if (strncmp(name, "format=", 7) == 0) {
                parse_format_spec(&opts, name + 7);
            } else if (strncmp(name, "preserve=", 9) == 0) {
                free(opts.preserve_chars);
                opts.preserve_chars = strdup(name + 9);
            } else if (strcmp(name, "decode") == 0) {
                opts.decode_mode = true;
            } else if (strcmp(name, "passthrough") == 0) {
                opts.passthrough_mode = true;
            } else if (strcmp(name, "hexlike") == 0) {
                opts.hexlike_mode = true;
            } else if (strcmp(name, "container") == 0) {
                opts.container_mode = true;
            } else if (strcmp(name, "spaces") == 0) {
                opts.spaces_mode = true;
            } else if (strcmp(name, "tabs") == 0) {
                opts.tabs_mode = true;
            } else if (strcmp(name, "crlf") == 0) {
                opts.crlf_mode = true;
            } else if (strcmp(name, "preserve-whitespace") == 0) {
                opts.spaces_mode = opts.tabs_mode = opts.crlf_mode = true;
            } else if (strcmp(name, "strip-whitespace") == 0) {
                opts.strip_whitespace = true;
            } else if (strcmp(name, "range") == 0) {
                if (i + 1 < argc) {
                    bool hs, he;
                    int64_t sv, ev;
                    if (!parse_range_spec(argv[++i], &hs, &sv, &he, &ev)) {
                        fprintf(stderr, "Error: Invalid range specification: %s\n", argv[i]);
                        exit(1);
                    }
                    if (hs) { opts.has_range_start = true; opts.range_start = sv; }
                    if (he) { opts.has_range_end = true; opts.range_end = ev; }
                } else {
                    fprintf(stderr, "Error: --range requires an argument\n");
                    exit(1);
                }
            } else if (strncmp(name, "range=", 6) == 0) {
                bool hs, he;
                int64_t sv, ev;
                if (!parse_range_spec(name + 6, &hs, &sv, &he, &ev)) {
                    fprintf(stderr, "Error: Invalid range specification: %s\n", name + 6);
                    exit(1);
                }
                if (hs) { opts.has_range_start = true; opts.range_start = sv; }
                if (he) { opts.has_range_end = true; opts.range_end = ev; }
            } else if (strcmp(name, "start") == 0) {
                if (i + 1 < argc) {
                    if (!parse_offset_value(argv[++i], &opts.range_start)) {
                        fprintf(stderr, "Error: Invalid start offset: %s\n", argv[i]);
                        exit(1);
                    }
                    opts.has_range_start = true;
                } else {
                    fprintf(stderr, "Error: --start requires an argument\n");
                    exit(1);
                }
            } else if (strncmp(name, "start=", 6) == 0) {
                if (!parse_offset_value(name + 6, &opts.range_start)) {
                    fprintf(stderr, "Error: Invalid start offset: %s\n", name + 6);
                    exit(1);
                }
                opts.has_range_start = true;
            } else if (strcmp(name, "end") == 0) {
                if (i + 1 < argc) {
                    if (!parse_offset_value(argv[++i], &opts.range_end)) {
                        fprintf(stderr, "Error: Invalid end offset: %s\n", argv[i]);
                        exit(1);
                    }
                    opts.has_range_end = true;
                } else {
                    fprintf(stderr, "Error: --end requires an argument\n");
                    exit(1);
                }
            } else if (strncmp(name, "end=", 4) == 0) {
                if (!parse_offset_value(name + 4, &opts.range_end)) {
                    fprintf(stderr, "Error: Invalid end offset: %s\n", name + 4);
                    exit(1);
                }
                opts.has_range_end = true;
            } else if (strcmp(name, "no-double-encode-check") == 0) {
                opts.no_double_encode_check = true;
            } else if (strcmp(name, "format") == 0) {
                opts.format_mode = true;
            } else if (strcmp(name, "mappings") == 0) {
                opts.mappings_mode = 1;
            } else if (strcmp(name, "mappings-json") == 0) {
                opts.mappings_mode = 2;
            } else if (strcmp(name, "mappings-csv") == 0) {
                opts.mappings_mode = 3;
            } else if (strcmp(name, "help") == 0) {
                opts.help_mode = true;
            } else {
                fprintf(stderr, "Unknown option: --%s\n", name);
                exit(1);
            }
        } else {
            /* Short options */
            for (size_t j = 1; arg[j]; j++) {
                switch (arg[j]) {
                    case 'd': opts.decode_mode = true; break;
                    case 'p': opts.passthrough_mode = true; break;
                    case 'X': opts.hexlike_mode = true; break;
                    case 'C': opts.container_mode = true; break;
                    case 's': opts.spaces_mode = true; break;
                    case 't': opts.tabs_mode = true; break;
                    case 'n': opts.crlf_mode = true; break;
                    case 'w': opts.spaces_mode = opts.tabs_mode = opts.crlf_mode = true; break;
                    case 'S': opts.strip_whitespace = true; break;
                    case 'h': opts.help_mode = true; break;
                    case 'f':
                        if (arg[j + 1]) {
                            parse_format_spec(&opts, arg + j + 1);
                            j = strlen(arg) - 1;
                        } else {
                            opts.format_mode = true;
                        }
                        break;
                    case 'P':
                        if (arg[j + 1]) {
                            free(opts.preserve_chars);
                            opts.preserve_chars = strdup(arg + j + 1);
                            j = strlen(arg) - 1;
                        } else if (i + 1 < argc) {
                            free(opts.preserve_chars);
                            opts.preserve_chars = strdup(argv[++i]);
                        } else {
                            fprintf(stderr, "Error: -P requires a value\n");
                            exit(1);
                        }
                        break;
                    default:
                        fprintf(stderr, "Unknown option: -%c\n", arg[j]);
                        exit(1);
                }
            }
        }
    }
    return opts;
}

/* ASCII names for mappings output */
static const char *ascii_names[] = {
    "NUL","SOH","STX","ETX","EOT","ENQ","ACK","BEL",
    "BS","TAB","LF","VT","FF","CR","SO","SI",
    "DLE","DC1","DC2","DC3","DC4","NAK","SYN","ETB",
    "CAN","EM","SUB","ESC","FS","GS","RS","US",
    "SPACE"
};

static void print_mappings(int mode) {
    switch (mode) {
        case 1: /* table */
            printf("Byte   Dec   ASCII        Mapping\n");
            for (int i = 0; i < 256; i++) {
                const char *ascii = (i < 33) ? ascii_names[i] :
                                    (i == 127) ? "DEL" :
                                    (i < 128) ? "" : "";
                char ascii_buf[4] = {0};
                if (i >= 33 && i < 127) {
                    ascii_buf[0] = '\'';
                    ascii_buf[1] = (char)i;
                    ascii_buf[2] = '\'';
                }
                printf("0x%02X   %-5d %-12s %.*s\n", i, i,
                       (i >= 33 && i < 127) ? ascii_buf : ascii,
                       (int)pb_get_mapping_len((uint8_t)i), pb_get_mapping((uint8_t)i));
            }
            break;
        case 2: /* json */
            printf("[\n");
            for (int i = 0; i < 256; i++) {
                const char *ascii = (i < 33) ? ascii_names[i] :
                                    (i == 127) ? "DEL" : "";
                char ascii_esc[16] = {0};
                if (i >= 33 && i < 127) {
                    if (i == '"' || i == '\\') {
                        snprintf(ascii_esc, sizeof(ascii_esc), "\\%c", (char)i);
                    } else {
                        ascii_esc[0] = (char)i;
                    }
                } else {
                    strncpy(ascii_esc, ascii, sizeof(ascii_esc) - 1);
                }
                printf("  {\"byte\": %d, \"ascii\": \"%s\", \"mapping\": \"%.*s\"}%s\n",
                       i, ascii_esc,
                       (int)pb_get_mapping_len((uint8_t)i), pb_get_mapping((uint8_t)i),
                       (i < 255) ? "," : "");
            }
            printf("]\n");
            break;
        case 3: /* csv */
            printf("byte,hex,dec,ascii,mapping\n");
            for (int i = 0; i < 256; i++) {
                const char *ascii = (i < 33) ? ascii_names[i] :
                                    (i == 127) ? "DEL" : "";
                char ascii_buf[4] = {0};
                if (i >= 33 && i < 127) {
                    ascii_buf[0] = (char)i;
                }
                printf("%d,0x%02X,%d,\"%s\",\"%.*s\"\n", i, i, i,
                       (i >= 33 && i < 127) ? ascii_buf : ascii,
                       (int)pb_get_mapping_len((uint8_t)i), pb_get_mapping((uint8_t)i));
            }
            break;
    }
}

/* Read entire input into buffer */
static char *read_input(const char *filename, size_t *len_out) {
    FILE *fp = stdin;
    if (filename && strcmp(filename, "-") != 0) {
        fp = fopen(filename, "rb");
        if (!fp) {
            perror("Error opening file");
            exit(1);
        }
    }

    size_t capacity = 8192;
    size_t len = 0;
    char *buf = malloc(capacity);
    if (!buf) {
        fprintf(stderr, "Memory allocation failed\n");
        exit(1);
    }

    while (1) {
        size_t n = fread(buf + len, 1, capacity - len, fp);
        if (n == 0) break;
        len += n;
        if (len >= capacity) {
            capacity *= 2;
            char *new_buf = realloc(buf, capacity);
            if (!new_buf) {
                free(buf);
                fprintf(stderr, "Memory allocation failed\n");
                exit(1);
            }
            buf = new_buf;
        }
    }

    if (fp != stdin) fclose(fp);
    *len_out = len;
    return buf;
}

int main(int argc, char *argv[]) {
    options_t opts = parse_options(argc, argv);
    const char *prog_name = argv[0] ? argv[0] : "printable-binary";
    bool stats_enabled = !env_var_truthy(getenv("PRINTABLE_BINARY_MUTE_STATS"));

    if (getenv("PRINTABLE_BINARY_MAP") != NULL) {
        fprintf(stderr, "Warning: PRINTABLE_BINARY_MAP is ignored by the FFI build (compiled-in map); use the C, Lua, or Node build for custom maps.\n");
    }
    if (opts.help_mode) {
        print_usage(prog_name);
        return 0;
    }

    if (opts.mappings_mode) {
        print_mappings(opts.mappings_mode);
        return 0;
    }

    /* Check for TTY without input file */
    if (!opts.input_file && isatty(STDIN_FILENO)) {
        print_usage(prog_name);
        return 0;
    }

    /* Measure the user-visible pipeline: input read, codec work, and output write. */
    double throughput_started_at = throughput_now_seconds();

    /* Read input */
    size_t input_len;
    char *input = read_input(opts.input_file, &input_len);
    size_t input_bytes_read = input_len;

    /* Apply byte range if specified (policy logic lives in Zig core) */
    if (opts.has_range_start || opts.has_range_end) {
        pb_range_result_t range = pb_apply_range(input_len,
            opts.has_range_start, opts.range_start,
            opts.has_range_end, opts.range_end);
        switch (range.warning) {
        case PB_RANGE_START_EXCEEDS:
            fprintf(stderr, "Warning: start offset %lld exceeds input size %zu\n",
                    (long long)(opts.has_range_start ? opts.range_start : 0), input_len);
            break;
        case PB_RANGE_EMPTY:
            fprintf(stderr, "Warning: start offset exceeds end offset, empty range\n");
            break;
        case PB_RANGE_END_CLAMPED:
            fprintf(stderr, "Warning: end offset %lld exceeds input size %zu, clamping to %zu\n",
                    (long long)(opts.has_range_end ? opts.range_end : 0), input_len, input_len - 1);
            break;
        case PB_RANGE_OK:
            break;
        }
        if (range.offset > 0) {
            memmove(input, input + range.offset, range.length);
        }
        input_len = range.length;
    }

    if (opts.container_mode) {
        /* Only --spaces is honored in container mode; --tabs/--crlf/-w/--preserve
         * would put raw tab/CR/LF (or arbitrary chars) into the JSON value, breaking
         * single-line-JSON validity and the tab/CR/LF-stripping transport-resistance. */
        if (opts.tabs_mode || opts.crlf_mode || (opts.preserve_chars && opts.preserve_chars[0] != '\0')) {
            fprintf(stderr, "Error: --tabs/--crlf/-w/--preserve are not supported with --container (only --spaces is honored; other whitespace stays encoded)\n");
            free(input); return 1;
        }
        if (opts.decode_mode) {
            size_t dlen;
            const char *draw = cj_get_string(input, input_len, "data", &dlen);
            if (!draw) { fprintf(stderr, "Error: not a printable-binary-file container (missing 'data')\n"); free(input); return 1; }
            /* Flagless crc-probe: no schema flag records whether --spaces was used; the
             * crc32_encoded oracle disambiguates. Try keeping literal spaces (DATA in a
             * --spaces container); if the crc mismatches, strip them as transport noise. */
            size_t clen;
            char *clean = cj_canonical(draw, dlen, &clen, 1);
            unsigned int decode_flags = PB_DECODE_SPACES_MODE;
            size_t celen;
            const char *ce = cj_get_string(input, input_len, "crc32_encoded", &celen);
            if (ce) {
                char hx[9]; snprintf(hx, 9, "%08x", pb_crc32(clean, clen));
                if (celen != 8 || memcmp(hx, ce, 8) != 0) {
                    size_t slen;
                    char *stripped = cj_canonical(draw, dlen, &slen, 0);
                    char hs[9]; snprintf(hs, 9, "%08x", pb_crc32(stripped, slen));
                    if (celen == 8 && memcmp(hs, ce, 8) == 0) {
                        /* Literal spaces were noise. If the space glyph is ALSO present, the
                         * payload mixed real (glyph) spaces with formatting spaces -> warn. */
                        const char *sg = pb_get_mapping(' ');
                        size_t sglen = pb_get_mapping_len(' ');
                        if (sg && cj_contains(clean, clen, sg, sglen)) {
                            fprintf(stderr, "Warning: literal spaces in container data were assumed to be ignorable formatting because the space glyph %.*s was also present; stripping them\n", (int)sglen, sg);
                        }
                        free(clean);
                        clean = stripped;
                        clen = slen;
                        decode_flags = 0;
                    } else {
                        free(stripped); free(clean); free(input);
                        fprintf(stderr, "Error: container crc32_encoded mismatch (data corrupted)\n");
                        return 1;
                    }
                }
            }
            pb_ffi_result_t dr = pb_decode(clean, clen, decode_flags);
            free(clean);
            if (dr.error_code) { free(input); fprintf(stderr, "Error: container decode failed\n"); return 1; }
            size_t colen;
            const char *co = cj_get_string(input, input_len, "crc32", &colen);
            if (co) {
                char hx[9]; snprintf(hx, 9, "%08x", pb_crc32(dr.data, dr.len));
                if (colen != 8 || memcmp(hx, co, 8) != 0) { pb_free(dr.data, dr.len); free(input); fprintf(stderr, "Error: container crc32 mismatch (decoded data corrupted)\n"); return 1; }
            }
            fwrite(dr.data, 1, dr.len, stdout);
            fflush(stdout);
            print_input_throughput(stats_enabled, input_bytes_read, throughput_started_at);
            pb_free(dr.data, dr.len);
            free(input);
            return 0;
        } else {
            unsigned int encode_flags = opts.spaces_mode ? PB_ENCODE_PRESERVE_SPACES : 0;
            pb_ffi_result_t er = pb_encode(input, input_len, encode_flags, NULL, 0);
            if (er.error_code) { free(input); fprintf(stderr, "Error: container encode failed\n"); return 1; }
            size_t clen;
            char *clean = cj_canonical(er.data, er.len, &clen, opts.spaces_mode ? 1 : 0);
            char crc_orig[9], crc_enc[9];
            snprintf(crc_orig, 9, "%08x", pb_crc32(input, input_len));
            snprintf(crc_enc, 9, "%08x", pb_crc32(clean, clen));
            free(clean);
            const char *fname = (opts.input_file && strcmp(opts.input_file, "-") != 0) ? cj_basename(opts.input_file) : "";
            printf("{\n  \"format\": \"printable-binary-file\",\n  \"version\": 1,\n  \"filename\": \"");
            cj_fputs_escaped(stdout, fname, strlen(fname));
            printf("\",\n  \"byte_length\": %zu,\n  \"crc32\": \"%s\",\n  \"crc32_encoded\": \"%s\",\n  \"data\": \"", input_len, crc_orig, crc_enc);
            fwrite(er.data, 1, er.len, stdout);
            printf("\"\n}\n");
            fflush(stdout);
            print_input_throughput(stats_enabled, input_bytes_read, throughput_started_at);
            pb_free(er.data, er.len);
            free(input);
            return 0;
        }
    }


    if (opts.decode_mode) {
        if (opts.passthrough_mode) {
            fprintf(stderr, "Warning: --passthrough ignored in decode mode\n");
        }

        if (stats_enabled) {
            fprintf(stderr, "Decoding mode: Input size is %zu bytes\n", input_len);
        }

        /* Warn about spaces after newlines in spaces + strip-whitespace mode */
        if (opts.spaces_mode && opts.strip_whitespace) {
            char prev1 = 0, prev2 = 0;
            for (size_t i = 0; i < input_len; i++) {
                char c = input[i];
                if (c == ' ' && prev1 == ' ' && (prev2 == '\n' || prev2 == '\r')) {
                    fprintf(stderr, "Warning: spaces after newline are treated as data in --spaces mode\n");
                    break;
                }
                prev2 = prev1;
                prev1 = c;
            }
        }

        /* Build decode flags */
        unsigned int flags = PB_DECODE_NONE;
        if (opts.spaces_mode) flags |= PB_DECODE_SPACES_MODE;
        if (opts.strip_whitespace) flags |= PB_DECODE_STRIP_WS;

        pb_ffi_result_t result = opts.hexlike_mode
            ? pb_hexlike_decode(input, input_len, opts.spaces_mode ? 1 : 0)
            : pb_decode(input, input_len, flags);
        if (result.error_code != 0 || !result.data) {
            fprintf(stderr, "Decode error\n");
            free(input);
            return 1;
        }

        if (stats_enabled) {
            fprintf(stderr, "Decoded result size: %zu bytes\n", result.len);
        }

        fwrite(result.data, 1, result.len, stdout);
        pb_free(result.data, result.len);
    } else {
        /* Encode mode */

        /* Check for double-encoding */
        if (!opts.no_double_encode_check) {
            pb_double_encode_info_t de_info = pb_detect_double_encode(input, input_len, 0.05f);
            if (de_info.detected) {
                fprintf(stderr,
                    "Warning: Input appears to already be printable-binary encoded (%.1f%% detection).\n"
                    "         Use --no-double-encode-check to suppress this warning.\n",
                    de_info.confidence * 100.0f);
            }
        }

        if (opts.passthrough_mode) {
            fwrite(input, 1, input_len, stdout);
        }

        /* Build encode flags */
        unsigned int flags = PB_ENCODE_NONE;
        if (opts.spaces_mode) flags |= PB_ENCODE_PRESERVE_SPACES;
        if (opts.tabs_mode) flags |= PB_ENCODE_PRESERVE_TABS;
        if (opts.crlf_mode) flags |= PB_ENCODE_PRESERVE_CRLF;

        size_t preserve_len = opts.preserve_chars ? strlen(opts.preserve_chars) : 0;
        pb_ffi_result_t result = opts.hexlike_mode
            ? pb_hexlike_encode(input, input_len, opts.spaces_mode ? 1 : 0)
            : pb_encode(input, input_len, flags, opts.preserve_chars, preserve_len);
        if (result.error_code != 0 || !result.data) {
            fprintf(stderr, "Encode error\n");
            free(input);
            return 1;
        }

        char *output = result.data;
        size_t output_len = result.len;
        pb_ffi_result_t formatted = {0};

        if (opts.format_mode) {
            formatted = pb_format(result.data, result.len,
                                  (size_t)opts.format_group,
                                  (size_t)opts.format_groups_per_line,
                                  opts.spaces_mode ? 1 : 0);
            if (formatted.error_code == 0 && formatted.data) {
                output = formatted.data;
                output_len = formatted.len;
            }
        }

        if (stats_enabled) {
            fprintf(stderr, "Encoded %zu bytes of input to %zu bytes\n",
                    input_len, output_len);
        }

        if (opts.passthrough_mode) {
            fwrite(output, 1, output_len, stderr);
        } else {
            fwrite(output, 1, output_len, stdout);
        }

        pb_free(result.data, result.len);
        if (formatted.data) {
            pb_free(formatted.data, formatted.len);
        }
    }

    fflush(stdout);
    fflush(stderr);
    print_input_throughput(stats_enabled, input_bytes_read, throughput_started_at);
    free(input);
    if (opts.preserve_chars) free(opts.preserve_chars);
    return 0;
}
