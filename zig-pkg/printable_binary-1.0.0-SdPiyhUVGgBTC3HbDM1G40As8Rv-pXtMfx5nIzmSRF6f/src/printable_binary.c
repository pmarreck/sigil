#define _POSIX_C_SOURCE 200809L
/*
 * PrintableBinary C Implementation
 * High-performance C version of the printable_binary tool
 * Encodes binary data into human-readable UTF-8 and decodes it back
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#if defined(_WIN32)
#include <windows.h>
#include <psapi.h>
#else
#include <unistd.h>
#endif
#include <time.h>
#if defined(__APPLE__)
#include <mach/mach.h>
#endif
#include <sys/stat.h>
#include <ctype.h>
#include <errno.h>

#include "character_map_embedded.h"
#include "printable_binary.h"
#include "container_json.h"

#ifdef __EMSCRIPTEN__
// Standalone WASM builds shouldn't depend on host-provided env functions.
__attribute__((used)) void emscripten_notify_memory_growth(int memory_index) {
    (void)memory_index;
}
#endif

static bool env_var_truthy(const char *value) {
    if (!value) {
        return false;
    }

    while (*value && isspace((unsigned char)*value)) {
        value++;
    }

    size_t len = strlen(value);
    while (len > 0 && isspace((unsigned char)value[len - 1])) {
        len--;
    }

    if (len == 0) {
        return false;
    }

    if (len == 1 && value[0] == '1') {
        return true;
    }

    if (len >= 8) {
        return false;
    }

    char lowered[8];
    for (size_t i = 0; i < len; i++) {
        lowered[i] = (char)tolower((unsigned char)value[i]);
    }
    lowered[len] = '\0';

    return (strcmp(lowered, "true") == 0 || strcmp(lowered, "yes") == 0);
}

#define MAX_UTF8_BYTES 4
#define INITIAL_BUFFER_SIZE 8192
#define BUFFER_GROW_FACTOR 2
#define STACK_BUFFER_SIZE 4096

// UTF-8 encoding structure
typedef struct {
    uint8_t bytes[MAX_UTF8_BYTES];
    uint8_t length;
} utf8_sequence_t;

// Global encoding and decoding tables
static utf8_sequence_t *encode_table;

typedef struct {
    uint64_t key;
    uint8_t value;
} decode_entry_t;

static decode_entry_t decode_entries[256];
static size_t decode_entry_count = 0;
/* O(1) decode lookups for 1- and 2-byte glyphs (-1 = no mapping). */
static int16_t decode_1byte[256];
static int16_t decode_2byte[32][64];

// High-confidence set for double-encoding detection.
// A byte is high-confidence if its PB glyph differs from the raw byte.
static bool high_confidence_set[256];

typedef enum {
    MAPPINGS_NONE = 0,
    MAPPINGS_TABLE,
    MAPPINGS_JSON,
    MAPPINGS_CSV
} mappings_mode_t;

// Program options
typedef struct {
    bool decode_mode;
    bool passthrough_mode;
    bool format_mode;
    bool help_mode;
    bool spaces_mode;
    bool tabs_mode;
    bool crlf_mode;
    bool strip_whitespace;
    char preserve_chars[256];
    int format_group;
    int format_groups_per_line;
    mappings_mode_t mappings_mode;
    char *input_file;
    bool has_range_start;
    bool has_range_end;
    int64_t range_start;
    int64_t range_end;
    bool no_double_encode_check;
    bool hexlike_mode;
    bool container_mode;
} options_t;

static void parse_format_spec(options_t *opts, const char *format_str) {
    if (!format_str || format_str[0] == '\0') {
        fprintf(stderr, "Error: --format requires a value like 8x10\n");
        exit(1);
    }

    while (*format_str == '=' || isspace((unsigned char)*format_str)) {
        format_str++;
    }

    if (*format_str == '\0') {
        fprintf(stderr, "Error: --format requires a value like 8x10\n");
        exit(1);
    }

    int group = 0;
    int groups_per_line = 0;
    if (sscanf(format_str, "%dx%d", &group, &groups_per_line) != 2 ||
        group <= 0 || groups_per_line <= 0) {
        fprintf(stderr, "Invalid format specification: %s\n", format_str);
        fprintf(stderr, "Expected format like: -f=8x10\n");
        exit(1);
    }

    opts->format_mode = true;
    opts->format_group = group;
    opts->format_groups_per_line = groups_per_line;
}

static void set_mappings_mode(options_t *opts, mappings_mode_t new_mode) {
    if (opts->mappings_mode != MAPPINGS_NONE && opts->mappings_mode != new_mode) {
        fprintf(stderr, "Error: Only one mappings output option can be specified\n");
        exit(1);
    }
    opts->mappings_mode = new_mode;
}

static bool long_option_equals(const char *name, size_t len, const char *option) {
    size_t option_len = strlen(option);
    return len == option_len && strncmp(name, option, option_len) == 0;
}

// Dynamic growing buffer for string building
typedef struct {
    char *data;
    size_t size;
    size_t capacity;
    bool uses_stack;   // True if using stack allocation
    char stack_data[STACK_BUFFER_SIZE];  // Embedded stack buffer
} buffer_t;

// Initialize a buffer with stack allocation if small enough
static void buffer_init(buffer_t *buf, size_t initial_capacity) {
    if (initial_capacity == 0) initial_capacity = INITIAL_BUFFER_SIZE;

    buf->size = 0;

    if (initial_capacity <= STACK_BUFFER_SIZE) {
        // Use embedded stack buffer for small data
        buf->data = buf->stack_data;
        buf->capacity = STACK_BUFFER_SIZE;
        buf->uses_stack = true;
    } else {
        // Use heap allocation for larger buffers
        buf->data = malloc(initial_capacity);
        buf->capacity = initial_capacity;
        buf->uses_stack = false;
        if (!buf->data) {
            fprintf(stderr, "Memory allocation failed\n");
            exit(1);
        }
    }
}

// Grow buffer capacity
static void buffer_grow(buffer_t *buf, size_t min_additional) {
    size_t new_capacity = buf->capacity;
    size_t needed = buf->size + min_additional;

    // Keep growing until we have enough space
    while (new_capacity < needed) {
        new_capacity *= BUFFER_GROW_FACTOR;
    }

    char *new_data;
    if (buf->uses_stack) {
        // Transition from stack to heap
        new_data = malloc(new_capacity);
        if (!new_data) {
            fprintf(stderr, "Memory allocation failed\n");
            exit(1);
        }
        // Copy existing data from stack buffer
        memcpy(new_data, buf->stack_data, buf->size);
        buf->uses_stack = false;
    } else {
        // Regular heap reallocation
        new_data = realloc(buf->data, new_capacity);
        if (!new_data) {
            fprintf(stderr, "Memory reallocation failed\n");
            exit(1);
        }
    }

    buf->data = new_data;
    buf->capacity = new_capacity;
}

// Append data to buffer with automatic growth
static void buffer_append(buffer_t *buf, const void *data, size_t len) {
    if (buf->size + len > buf->capacity) {
        buffer_grow(buf, len);
    }

    memcpy(buf->data + buf->size, data, len);
    buf->size += len;
}

// Append a single character to buffer
static void buffer_append_char(buffer_t *buf, char c) {
    buffer_append(buf, &c, 1);
}

// Prepare buffer for return - ensure data is heap-allocated
static void buffer_prepare_return(buffer_t *buf) {
    if (buf->uses_stack && buf->size > 0) {
        // Need to transition from stack to heap before returning
        char *heap_data = malloc(buf->size);
        if (!heap_data) {
            fprintf(stderr, "Memory allocation failed\n");
            exit(1);
        }
        memcpy(heap_data, buf->stack_data, buf->size);
        buf->data = heap_data;
        buf->capacity = buf->size;
        buf->uses_stack = false;
    }
}

// Free buffer memory
#ifndef __EMSCRIPTEN__
static void buffer_free(buffer_t *buf) {
    if (buf->data && !buf->uses_stack) {
        free(buf->data);
    }
    // Don't set data to NULL for stack buffers since it points to stack_data
    if (!buf->uses_stack) {
        buf->data = NULL;
    }
    buf->size = 0;
    buf->capacity = 0;
}
#endif

// Helper function to create UTF-8 sequence
static utf8_sequence_t make_utf8(const char *bytes) {
    utf8_sequence_t seq = {0};
    size_t len = strlen(bytes);
    if (len > MAX_UTF8_BYTES) len = MAX_UTF8_BYTES; /* never overflow seq.bytes[4] */
    seq.length = len;
    memcpy(seq.bytes, bytes, len);
    return seq;
}

static uint64_t make_key(const uint8_t *bytes, uint8_t len) {
    uint64_t key = len;
    for (uint8_t i = 0; i < len; i++) {
        key = (key << 8) | bytes[i];
    }
    return key;
}

static int compare_decode_entries(const void *a, const void *b) {
    const decode_entry_t *ea = (const decode_entry_t *)a;
    const decode_entry_t *eb = (const decode_entry_t *)b;
    if (ea->key < eb->key) return -1;
    if (ea->key > eb->key) return 1;
    return 0;
}

static bool load_map_from_path(const char *path) {
    if (!path) {
        return false;
    }

    FILE *fp = fopen(path, "rb");
    if (!fp) {
        return false;
    }

    /* Lines beginning with "##" are full-line comments; blank lines are skipped.
     * The glyph is the first whitespace-delimited token, so a trailing
     * "<glyph> ## comment" is ignored. Mirrors the Zig/Lua/JS parsers. */
    char buffer[512];
    int i = 0;
    while (i < 256) {
        if (!fgets(buffer, sizeof(buffer), fp)) {
            fprintf(stderr, "Error: character map '%s' must contain 256 glyph lines\n", path);
            fclose(fp);
            exit(1);
        }

        size_t len = strlen(buffer);
        bool complete_line = (len > 0 && buffer[len - 1] == '\n');
        while (len > 0 && (buffer[len - 1] == '\n' || buffer[len - 1] == '\r')) {
            buffer[--len] = '\0';
        }
        /* Discard the remainder if the line was longer than the buffer. */
        if (!complete_line) {
            int ch;
            while ((ch = fgetc(fp)) != EOF && ch != '\n') {
            }
        }

        if (len == 0) {
            continue; /* blank line */
        }
        if (len >= 2 && buffer[0] == '#' && buffer[1] == '#') {
            continue; /* "##" comment */
        }

        /* Truncate at first whitespace: glyph is the first token. */
        for (size_t j = 0; j < len; j++) {
            if (buffer[j] == ' ' || buffer[j] == '\t') {
                buffer[j] = '\0';
                break;
            }
        }

        if (strlen(buffer) > MAX_UTF8_BYTES) {
            fprintf(stderr, "Error: character map '%s' glyph at index %d exceeds %d bytes\n",
                    path, i, MAX_UTF8_BYTES);
            fclose(fp);
            exit(1);
        }

        encode_table[i] = make_utf8(buffer);
        i++;
    }

    fclose(fp);
    return true;
}

static void finalize_decode_entries(void) {
    decode_entry_count = 0;
    for (int i = 0; i < 256; i++) {
        utf8_sequence_t seq = encode_table[i];
        if (seq.length == 0) {
            fprintf(stderr, "Error: missing character mapping for byte %d\n", i);
            exit(1);
        }
        decode_entries[decode_entry_count].key = make_key(seq.bytes, seq.length);
        decode_entries[decode_entry_count].value = (uint8_t)i;
        decode_entry_count++;
    }

    qsort(decode_entries, decode_entry_count, sizeof(decode_entry_t), compare_decode_entries);

    for (size_t i = 1; i < decode_entry_count; i++) {
        if (decode_entries[i].key == decode_entries[i - 1].key) {
            fprintf(stderr, "Error: duplicate character mapping detected\n");
            exit(1);
        }
    }

    memset(decode_1byte, 0xFF, sizeof decode_1byte); /* 0xFFFF == -1 */
    memset(decode_2byte, 0xFF, sizeof decode_2byte);
    for (int i = 0; i < 256; i++) {
        utf8_sequence_t seq = encode_table[i];
        if (seq.length == 1) {
            decode_1byte[seq.bytes[0]] = (int16_t)i;
        } else if (seq.length == 2) {
            decode_2byte[seq.bytes[0] & 0x1F][seq.bytes[1] & 0x3F] = (int16_t)i;
        }
    }

    // Build high-confidence set: any byte whose glyph is not the identity mapping
    memset(high_confidence_set, 0, sizeof(high_confidence_set));
    for (int i = 0; i < 256; i++) {
        utf8_sequence_t seq = encode_table[i];
        if (seq.length != 1 || seq.bytes[0] != (uint8_t)i) {
            high_confidence_set[i] = true;
        }
    }
}

static void load_map_from_embedded(void) {
    for (int i = 0; i < 256; i++) {
        const char *entry = embedded_character_map[i];
        if (!entry || entry[0] == '\0') {
            fprintf(stderr, "Error: embedded character map has an empty entry at index %d\n", i);
            exit(1);
        }
        encode_table[i] = make_utf8(entry);
    }
    finalize_decode_entries();
}

static void load_character_map(const char *argv0) {
    const char *env_path = getenv("PRINTABLE_BINARY_MAP");
    if (env_path && load_map_from_path(env_path)) {
        finalize_decode_entries();
        return;
    }

    if (argv0) {
        char path_buffer[512];
        const char *slash = strrchr(argv0, '/');
#ifdef _WIN32
        const char *backslash = strrchr(argv0, '\\');
        if (!slash || (backslash && backslash > slash)) {
            slash = backslash;
        }
#endif
        if (slash) {
            size_t dir_len = (size_t)(slash - argv0) + 1;
            if (dir_len + strlen("character_map.txt") < sizeof(path_buffer)) {
                memcpy(path_buffer, argv0, dir_len);
                strcpy(path_buffer + dir_len, "character_map.txt");
                if (load_map_from_path(path_buffer)) {
                    finalize_decode_entries();
                    return;
                }
            }
        }
    }

    if (load_map_from_path("character_map.txt")) {
        finalize_decode_entries();
        return;
    }

    /* The embedded map is the guaranteed final fallback (load_map_from_embedded
     * exits on a malformed embed), so reaching here always succeeds. */
    load_map_from_embedded();
}

static const char *ascii_name_for_byte(uint8_t value, char *buffer, size_t buffer_size) {
    static const char *control_names[] = {
        "NUL","SOH","STX","ETX","EOT","ENQ","ACK","BEL",
        "BS","TAB","LF","VT","FF","CR","SO","SI",
        "DLE","DC1","DC2","DC3","DC4","NAK","SYN","ETB",
        "CAN","EM","SUB","ESC","FS","GS","RS","US"
    };

    if (value <= 0x1F) {
        return control_names[value];
    }
    if (value == 0x20) {
        return "SPACE";
    }
    if (value == 0x7F) {
        return "DEL";
    }
    if (value >= 0x21 && value <= 0x7E) {
        if (buffer_size < 4) {
            return "";
        }
        size_t idx = 0;
        buffer[idx++] = '\'';
        if (value == '\'' || value == '\\') {
            if (idx + 2 >= buffer_size) {
                buffer[0] = '\0';
                return buffer;
            }
            buffer[idx++] = '\\';
        }
        buffer[idx++] = (char)value;
        buffer[idx++] = '\'';
        buffer[idx] = '\0';
        return buffer;
    }
    snprintf(buffer, buffer_size, "0x%02X", value);
    return buffer;
}

static void utf8_sequence_to_string(const utf8_sequence_t *seq, char *buffer, size_t buffer_size) {
    if (buffer_size == 0) {
        return;
    }
    if (!seq || seq->length == 0) {
        buffer[0] = '\0';
        return;
    }
    size_t copy_len = seq->length;
    if (copy_len >= buffer_size) {
        copy_len = buffer_size - 1;
    }
    memcpy(buffer, seq->bytes, copy_len);
    buffer[copy_len] = '\0';
}

static void json_escape_and_print(FILE *out, const char *str) {
    for (const unsigned char *p = (const unsigned char *)str; *p; ++p) {
        if (*p == '"' || *p == '\\') {
            fputc('\\', out);
            fputc(*p, out);
        } else if (*p >= 0x20) {
            fputc(*p, out);
        } else {
            fprintf(out, "\\u%04X", *p);
        }
    }
}

static void csv_escape_and_print(FILE *out, const char *str) {
    fputc('"', out);
    for (const unsigned char *p = (const unsigned char *)str; *p; ++p) {
        if (*p == '"') {
            fputc('"', out);
            fputc('"', out);
        } else {
            fputc(*p, out);
        }
    }
    fputc('"', out);
}

static void print_mappings_table(void) {
    printf("%-6s %-5s %-12s %s\n", "Byte", "Dec", "ASCII", "Mapping");
    for (int i = 0; i < 256; i++) {
        char hex_buf[6];
        snprintf(hex_buf, sizeof(hex_buf), "0x%02X", i);
        char ascii_buf[16];
        const char *ascii_name = ascii_name_for_byte((uint8_t)i, ascii_buf, sizeof(ascii_buf));
        char mapping_buf[32];
        utf8_sequence_to_string(&encode_table[i], mapping_buf, sizeof(mapping_buf));
        printf("%-6s %-5d %-12s %s\n", hex_buf, i, ascii_name, mapping_buf[0] ? mapping_buf : "");
    }
}

static void print_mappings_json(void) {
    fputs("[\n", stdout);
    for (int i = 0; i < 256; i++) {
        char hex_buf[6];
        snprintf(hex_buf, sizeof(hex_buf), "0x%02X", i);
        char ascii_buf[16];
        const char *ascii_name = ascii_name_for_byte((uint8_t)i, ascii_buf, sizeof(ascii_buf));
        char mapping_buf[32];
        utf8_sequence_to_string(&encode_table[i], mapping_buf, sizeof(mapping_buf));
        printf("  {\"byte\":%d,\"hex\":\"%s\",\"dec\":%d,\"ascii\":\"", i, hex_buf, i);
        json_escape_and_print(stdout, ascii_name);
        fputs("\",\"mapping\":\"", stdout);
        json_escape_and_print(stdout, mapping_buf);
        fprintf(stdout, "\"}%s\n", (i == 255) ? "" : ",");
    }
    fputs("]\n", stdout);
}

static void print_mappings_csv(void) {
    fputs("byte,hex,dec,ascii,mapping\n", stdout);
    for (int i = 0; i < 256; i++) {
        char hex_buf[6];
        snprintf(hex_buf, sizeof(hex_buf), "0x%02X", i);
        char ascii_buf[16];
        const char *ascii_name = ascii_name_for_byte((uint8_t)i, ascii_buf, sizeof(ascii_buf));
        char mapping_buf[32];
        utf8_sequence_to_string(&encode_table[i], mapping_buf, sizeof(mapping_buf));
        printf("%d,%s,%d,", i, hex_buf, i);
        csv_escape_and_print(stdout, ascii_name);
        fputc(',', stdout);
        csv_escape_and_print(stdout, mapping_buf);
        fputc('\n', stdout);
    }
}

static void print_mappings(mappings_mode_t mode) {
    switch (mode) {
        case MAPPINGS_TABLE:
            print_mappings_table();
            break;
        case MAPPINGS_JSON:
            print_mappings_json();
            break;
        case MAPPINGS_CSV:
            print_mappings_csv();
            break;
        default:
            break;
    }
}

// Initialize encoding and decoding tables
static void init_tables(const char *argv0) {
    encode_table = calloc(256, sizeof(utf8_sequence_t));
    if (!encode_table) {
        fprintf(stderr, "Memory allocation failed for lookup tables\n");
        exit(1);
    }

    load_character_map(argv0);
}

// Public initialization function for FFI users
void pb_init(const char *argv0) {
    if (encode_table == NULL) {
        init_tables(argv0);
    }
}

// Get UTF-8 sequence length from first byte
static uint8_t utf8_sequence_length(uint8_t first_byte) {
    if (first_byte < 0x80) return 1;
    if (first_byte < 0xE0) return 2;
    if (first_byte < 0xF0) return 3;
    return 4;
}

// Decode a UTF-8 sequence to a Unicode codepoint
static uint32_t decode_utf8_codepoint(const uint8_t *bytes, uint8_t len) {
    if (len == 0) return 0xFFFD; // Replacement character

    uint8_t first = bytes[0];
    if (first < 0x80) {
        return first;
    } else if (first < 0xE0) {
        if (len < 2) return 0xFFFD;
        if ((bytes[1] & 0xC0) != 0x80) return 0xFFFD;
        return ((uint32_t)(first & 0x1F) << 6) | (bytes[1] & 0x3F);
    } else if (first < 0xF0) {
        if (len < 3) return 0xFFFD;
        if ((bytes[1] & 0xC0) != 0x80 || (bytes[2] & 0xC0) != 0x80) return 0xFFFD;
        return ((uint32_t)(first & 0x0F) << 12) | ((uint32_t)(bytes[1] & 0x3F) << 6) | (bytes[2] & 0x3F);
    } else {
        if (len < 4) return 0xFFFD;
        if ((bytes[1] & 0xC0) != 0x80 || (bytes[2] & 0xC0) != 0x80 || (bytes[3] & 0xC0) != 0x80) return 0xFFFD;
        return ((uint32_t)(first & 0x07) << 18) | ((uint32_t)(bytes[1] & 0x3F) << 12) |
               ((uint32_t)(bytes[2] & 0x3F) << 6) | (bytes[3] & 0x3F);
    }
}

// Validate that a string contains only valid printable-binary encoded characters
pb_validation_result_t pb_validate(const char *input, size_t input_len, unsigned int ws_flags) {
    pb_validation_result_t result = { .is_valid = 1, .error_position = -1, .error_codepoint = 0 };

    if (input == NULL || input_len == 0) {
        return result; // Empty input is valid
    }

    const uint8_t *data = (const uint8_t *)input;
    size_t i = 0;

    while (i < input_len) {
        uint8_t byte = data[i];

        // Check whitespace handling
        if (byte == ' ') {
            if (ws_flags & PB_WS_ALLOW_SPACE) {
                i++;
                continue;
            }
        } else if (byte == '\t') {
            if (ws_flags & PB_WS_ALLOW_TAB) {
                i++;
                continue;
            }
        } else if (byte == '\n') {
            if (ws_flags & PB_WS_ALLOW_LF) {
                i++;
                continue;
            }
        } else if (byte == '\r') {
            if (ws_flags & PB_WS_ALLOW_CR) {
                i++;
                continue;
            }
        }

        // Determine UTF-8 sequence length
        uint8_t seq_len = utf8_sequence_length(byte);
        size_t remaining = input_len - i;

        // Check for truncated UTF-8 sequence
        if (seq_len > remaining) {
            result.is_valid = 0;
            result.error_position = (int64_t)i;
            result.error_codepoint = decode_utf8_codepoint(data + i, (uint8_t)remaining);
            return result;
        }

        // Validate UTF-8 continuation bytes
        for (uint8_t j = 1; j < seq_len; j++) {
            if ((data[i + j] & 0xC0) != 0x80) {
                result.is_valid = 0;
                result.error_position = (int64_t)i;
                result.error_codepoint = decode_utf8_codepoint(data + i, seq_len);
                return result;
            }
        }

        // Look up in decode map using binary search
        uint64_t key = make_key(data + i, seq_len);
        bool found = false;
        size_t left = 0, right = decode_entry_count;
        while (left < right) {
            size_t mid = left + (right - left) / 2;
            if (decode_entries[mid].key == key) {
                found = true;
                break;
            } else if (decode_entries[mid].key < key) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }

        if (!found) {
            result.is_valid = 0;
            result.error_position = (int64_t)i;
            result.error_codepoint = decode_utf8_codepoint(data + i, seq_len);
            return result;
        }

        i += seq_len;
    }

    return result;
}

// Detect if input appears to be already printable-binary encoded
static pb_double_encode_info_t detect_double_encode(const char *input, size_t input_len, float threshold) {
    pb_double_encode_info_t result = { .detected = 0, .confidence = 0.0f };
    if (!input || input_len == 0) return result;

    const uint8_t *data = (const uint8_t *)input;
    size_t glyph_count = 0;
    size_t char_count = 0;
    size_t i = 0;

    while (i < input_len) {
        uint8_t first_byte = data[i];
        uint8_t seq_len = utf8_sequence_length(first_byte);
        size_t remaining = input_len - i;
        if (seq_len > remaining) seq_len = (uint8_t)remaining;

        char_count++;

        // Try to look up this UTF-8 char in the decode map
        if (seq_len >= 1 && seq_len <= MAX_UTF8_BYTES) {
            uint64_t key = make_key(data + i, seq_len);
            size_t left = 0, right = decode_entry_count;
            while (left < right) {
                size_t mid = left + (right - left) / 2;
                if (decode_entries[mid].key == key) {
                    uint8_t byte_val = decode_entries[mid].value;
                    if (high_confidence_set[byte_val]) {
                        glyph_count++;
                    }
                    break;
                } else if (decode_entries[mid].key < key) {
                    left = mid + 1;
                } else {
                    right = mid;
                }
            }
        }

        i += seq_len;
    }

    if (char_count == 0) return result;

    result.confidence = (float)glyph_count / (float)char_count;
    result.detected = (result.confidence >= threshold) ? 1 : 0;
    return result;
}

// Standalone C implementation of pb_detect_double_encode for FFI header compatibility
pb_double_encode_info_t pb_detect_double_encode(const char *input, size_t input_len, float threshold) {
    return detect_double_encode(input, input_len, threshold);
}

// CRC-32/ISO-HDLC (vector-pinned: CRC32("123456789")=0xCBF43926). Self-contained
// (the standalone build does not link the Zig lib). Backs .pbf.json container
// integrity; bitwise, ample for container-sized payloads.
uint32_t pb_crc32(const char *input, size_t input_len) {
    if (!input || input_len == 0) return 0u;
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < input_len; i++) {
        crc ^= (unsigned char)input[i];
        for (int k = 0; k < 8; k++) {
            crc = (crc & 1u) ? ((crc >> 1) ^ 0xEDB88320u) : (crc >> 1);
        }
    }
    return ~crc;
}

// Hexlike passthrough set: bytes that pass through as-is in hexlike mode
// . 0-9 @ A-Z ^ _ a-z (the same bytes that are identity-mapped in the character map)
static bool is_hexlike_passthrough(uint8_t byte, bool spaces_mode) {
    if (byte == 46) return true;                          // .
    if (byte >= 48 && byte <= 57) return true;            // 0-9
    if (byte == 64) return true;                          // @
    if (byte >= 65 && byte <= 90) return true;            // A-Z
    if (byte == 94) return true;                          // ^
    if (byte == 95) return true;                          // _
    if (byte >= 97 && byte <= 122) return true;           // a-z
    if (spaces_mode && byte == 32) return true;           // space (only with --spaces)
    return false;
}

// Οχ prefix: Greek Omicron (U+039F) + Greek Chi (U+03C7) — NOT ASCII "0x"
// Bytes: 0xCE 0x9F 0xCF 0x87 (4 bytes in UTF-8)
static const uint8_t OX_PREFIX[] = { 0xCE, 0x9F, 0xCF, 0x87 };
#define OX_PREFIX_LEN 4

// Detect Οχ hex sequences in input (for cross-format warnings)
static bool detect_hexlike(const uint8_t *input, size_t input_len) {
    if (!input || input_len < OX_PREFIX_LEN + 2) return false;

    for (size_t i = 0; i + OX_PREFIX_LEN + 1 < input_len; i++) {
        if (memcmp(input + i, OX_PREFIX, OX_PREFIX_LEN) == 0) {
            // Check that at least two hex digits follow
            uint8_t h1 = input[i + OX_PREFIX_LEN];
            uint8_t h2 = input[i + OX_PREFIX_LEN + 1];
            if (isxdigit(h1) && isxdigit(h2) &&
                ((h1 >= '0' && h1 <= '9') || (h1 >= 'A' && h1 <= 'F')) &&
                ((h2 >= '0' && h2 <= '9') || (h2 >= 'A' && h2 <= 'F'))) {
                return true;
            }
        }
    }
    return false;
}

// Encode binary data to hexlike format
static buffer_t hexlike_encode(const uint8_t *input, size_t input_len, const options_t *opts) {
    buffer_t output;
    buffer_init(&output, INITIAL_BUFFER_SIZE);

    size_t i = 0;
    bool has_output = false;  // track whether we've written anything yet

    while (i < input_len) {
        uint8_t byte = input[i];

        if (is_hexlike_passthrough(byte, opts->spaces_mode)) {
            // Passthrough run: collect consecutive passthrough bytes
            size_t run_start = i;
            while (i < input_len && is_hexlike_passthrough(input[i], opts->spaces_mode)) {
                i++;
            }
            buffer_append(&output, input + run_start, i - run_start);
            has_output = true;
        } else {
            // Non-passthrough run: collect hex pairs
            // Delimiter space before Οχ (unless at start of output)
            if (has_output) {
                buffer_append_char(&output, ' ');
            }
            // Write Οχ prefix
            buffer_append(&output, OX_PREFIX, OX_PREFIX_LEN);

            // Collect hex pairs for consecutive non-passthrough bytes
            while (i < input_len && !is_hexlike_passthrough(input[i], opts->spaces_mode)) {
                char hex[3];
                snprintf(hex, sizeof(hex), "%02X", input[i]);
                buffer_append(&output, hex, 2);
                i++;
            }

            // Delimiter space after hex run (unless at end of input)
            if (i < input_len) {
                buffer_append_char(&output, ' ');
            }
            has_output = true;
        }
    }

    buffer_prepare_return(&output);
    return output;
}

// Helper: parse a hex digit, returns -1 on invalid
static int hex_digit_value(uint8_t c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

// Decode hexlike format back to binary
// Sets *found_hex to true if any Οχ sequences were found
static buffer_t hexlike_decode(const uint8_t *input, size_t input_len, bool *found_hex) {
    buffer_t output;
    buffer_init(&output, INITIAL_BUFFER_SIZE);

    *found_hex = false;
    size_t i = 0;

    while (i < input_len) {
        bool at_ox = false;

        // Check for Οχ (4 bytes: CE 9F CF 87), possibly preceded by delimiter space
        if (i + OX_PREFIX_LEN <= input_len &&
            memcmp(input + i, OX_PREFIX, OX_PREFIX_LEN) == 0) {
            at_ox = true;
        } else if (i + 1 + OX_PREFIX_LEN <= input_len &&
                   input[i] == ' ' &&
                   memcmp(input + i + 1, OX_PREFIX, OX_PREFIX_LEN) == 0) {
            i++;  // consume delimiter space
            at_ox = true;
        }

        if (at_ox) {
            *found_hex = true;
            i += OX_PREFIX_LEN;  // skip past Οχ

            // Read hex pairs until non-hex char
            while (i + 1 < input_len) {
                int h1 = hex_digit_value(input[i]);
                int h2 = hex_digit_value(input[i + 1]);
                if (h1 >= 0 && h2 >= 0) {
                    uint8_t byte = (uint8_t)((h1 << 4) | h2);
                    buffer_append_char(&output, (char)byte);
                    i += 2;
                } else {
                    break;
                }
            }

            // Consume trailing delimiter space (if present)
            if (i < input_len && input[i] == ' ') {
                i++;
            }
        } else {
            // Passthrough byte
            buffer_append_char(&output, (char)input[i]);
            i++;
        }
    }

    buffer_prepare_return(&output);
    return output;
}

// Encode binary data to printable UTF-8
static buffer_t encode_data(const uint8_t *input, size_t input_len, const options_t *opts) {
    buffer_t output;
    // Start with reasonable initial size, will grow as needed
    buffer_init(&output, INITIAL_BUFFER_SIZE);

    // Build a lookup table for preserved characters
    bool preserve_set[256] = {false};
    for (size_t j = 0; opts->preserve_chars[j] != '\0'; j++) {
        preserve_set[(unsigned char)opts->preserve_chars[j]] = true;
    }

    for (size_t i = 0; i < input_len; i++) {
        uint8_t byte = input[i];

        // Check preservation modes
        if (opts->spaces_mode && byte == ' ') {
            buffer_append_char(&output, ' ');
        } else if (opts->tabs_mode && byte == '\t') {
            buffer_append_char(&output, '\t');
        } else if (opts->crlf_mode && (byte == '\n' || byte == '\r')) {
            buffer_append_char(&output, (char)byte);
        } else if (preserve_set[byte]) {
            buffer_append_char(&output, (char)byte);
        } else {
            utf8_sequence_t seq = encode_table[byte];
            if (seq.length > 0) {
                buffer_append(&output, seq.bytes, seq.length);
            }
        }
    }

    buffer_prepare_return(&output);
    return output;
}

// Decode printable UTF-8 back to binary
static buffer_t decode_data(const uint8_t *input, size_t input_len, bool spaces_mode) {
    buffer_t output;
    // Start with reasonable initial size, will grow as needed
    buffer_init(&output, INITIAL_BUFFER_SIZE);

    size_t i = 0;
    while (i < input_len) {
        if (spaces_mode && input[i] == ' ') {
            buffer_append_char(&output, ' ');
            i++;
            continue;
        }
        uint8_t first_byte = input[i];
        uint8_t seq_len = utf8_sequence_length(first_byte);

        // Ensure we don't go beyond input
        if (i + seq_len > input_len) {
            seq_len = input_len - i;
        }

        bool matched = false;

        /* O(1) direct lookup for 1- and 2-byte glyphs (the common cases);
         * 3-byte glyphs fall back to binary search over the ~28 entries. */
        if (seq_len == 1) {
            int16_t v = decode_1byte[first_byte];
            if (v >= 0) { buffer_append_char(&output, (char)(uint8_t)v); i += 1; matched = true; }
        } else if (seq_len == 2) {
            int16_t v = decode_2byte[first_byte & 0x1F][input[i + 1] & 0x3F];
            if (v >= 0) { buffer_append_char(&output, (char)(uint8_t)v); i += 2; matched = true; }
        } else if (seq_len == 3) {
            uint64_t key = make_key(input + i, 3);
            size_t left = 0, right = decode_entry_count;
            while (left < right) {
                size_t mid = left + (right - left) / 2;
                if (decode_entries[mid].key == key) {
                    buffer_append_char(&output, decode_entries[mid].value);
                    i += 3;
                    matched = true;
                    break;
                } else if (decode_entries[mid].key < key) {
                    left = mid + 1;
                } else {
                    right = mid;
                }
            }
        }

        // If we didn't match any character in our map, pass through the UTF-8 character intact
        if (!matched) {
            // Pass through the entire UTF-8 character
            for (uint8_t j = 0; j < seq_len; j++) {
                buffer_append_char(&output, (char)input[i + j]);
            }
            i += seq_len;
        }
    }

    buffer_prepare_return(&output);
    return output;
}

// Apply formatting to encoded output
static buffer_t format_output(const buffer_t *input, int group_size, int groups_per_line, bool spaces_mode) {
    buffer_t output;
    // Start with reasonable initial size, will grow as needed
    buffer_init(&output, INITIAL_BUFFER_SIZE);

    size_t char_count = 0;
    size_t i = 0;
    const char group_separator = spaces_mode ? '\t' : ' ';

    while (i < input->size) {
        // Determine UTF-8 character length
        uint8_t first_byte = (uint8_t)input->data[i];
        uint8_t char_len = utf8_sequence_length(first_byte);

        // Append the UTF-8 character
        for (uint8_t j = 0; j < char_len && i + j < input->size; j++) {
            buffer_append_char(&output, input->data[i + j]);
        }

        char_count++;
        i += char_len;

        // Add spacing after each group
        if (char_count % group_size == 0 && i < input->size) {
            if ((char_count / group_size) % groups_per_line == 0) {
                buffer_append_char(&output, '\n');
            } else {
                buffer_append_char(&output, group_separator);
            }
        }
    }

    buffer_prepare_return(&output);
    return output;
}

// Read entire file into memory
static buffer_t read_file(const char *filename) {
    buffer_t buf;
    size_t initial_capacity = INITIAL_BUFFER_SIZE;

    // Try to get file size for better initial allocation
    if (filename && strcmp(filename, "-") != 0) {
        struct stat st;
        if (stat(filename, &st) == 0 && st.st_size > 0) {
            initial_capacity = st.st_size;
        }
    }

    buffer_init(&buf, initial_capacity);

    // Fast path for stdin: use unbuffered read() to avoid libc quirks (notably in Cosmopolitan APE)
    if (!filename || strcmp(filename, "-") == 0) {
        char temp[8192];
        while (1) {
            ssize_t bytes_read = read(STDIN_FILENO, temp, sizeof(temp));
            if (bytes_read > 0) {
                if (buf.size + (size_t)bytes_read >= buf.capacity) {
                    buf.capacity = (buf.size + (size_t)bytes_read) * 2;
                    buf.data = realloc(buf.data, buf.capacity);
                    if (!buf.data) {
                        fprintf(stderr, "Memory allocation failed\n");
                        exit(1);
                    }
                }
                memcpy(buf.data + buf.size, temp, (size_t)bytes_read);
                buf.size += (size_t)bytes_read;
                continue;
            }
            if (bytes_read == 0) {
                break; // EOF
            }
            if (errno == EINTR
#ifdef EAGAIN
                || errno == EAGAIN || errno == EWOULDBLOCK
#endif
            ) {
                continue;
            }
            perror("Error reading input");
            exit(1);
        }
        buffer_prepare_return(&buf);
        return buf;
    }

    // File path case: use stdio for portability
    FILE *file = fopen(filename, "rb");
    if (!file) {
        perror("Error opening file");
        exit(1);
    }

    char temp[8192];
    while (1) {
        size_t bytes_read = fread(temp, 1, sizeof(temp), file);
        if (bytes_read > 0) {
            /* buffer_append routes through buffer_grow, which correctly migrates
             * a stack-backed buffer to the heap. The previous hand-rolled realloc
             * called realloc() directly on buf.data, corrupting/crashing when
             * buf.data still pointed at the 4096-byte stack buffer (e.g. a file
             * of exactly STACK_BUFFER_SIZE bytes). */
            buffer_append(&buf, temp, bytes_read);
            continue;
        }

        if (feof(file)) {
            break;
        }

        if (ferror(file)) {
            if (errno == EINTR
#ifdef EAGAIN
                || errno == EAGAIN || errno == EWOULDBLOCK
#endif
            ) {
                clearerr(file);
                continue;
            }
            perror("Error reading file");
            fclose(file);
            exit(1);
        }
    }

    fclose(file);
    buffer_prepare_return(&buf);
    return buf;
}

// Clean input for decoding (optionally strip whitespace)
static buffer_t clean_decode_input(const buffer_t *input, bool spaces_mode, bool strip_whitespace) {
    buffer_t output;
    // Start with reasonable initial size, will grow as needed
    buffer_init(&output, INITIAL_BUFFER_SIZE);

    bool warned = false;
    char prev1 = '\0';
    char prev2 = '\0';

    for (size_t i = 0; i < input->size; i++) {
        char c = input->data[i];

        if (spaces_mode && !warned && c == ' ' && prev1 == ' ' && (prev2 == '\n' || prev2 == '\r')) {
            fprintf(stderr, "Warning: spaces after newline are treated as data in --spaces mode\n");
            warned = true;
        }

        // Only strip whitespace if strip_whitespace is enabled
        if (strip_whitespace) {
            if (c == '\n' || c == '\r') {
                // skip
            } else if (c == '\t') {
                // skip
            } else if (c == ' ' && !spaces_mode) {
                // skip
            } else {
                buffer_append_char(&output, c);
            }
        } else {
            // Pass through everything
            buffer_append_char(&output, c);
        }

        prev2 = prev1;
        prev1 = c;
    }

    buffer_prepare_return(&output);
    return output;
}

static const char *resolve_program_name(const char *argv0) {
#ifdef PRINTABLE_BINARY_HELP_NAME
    (void)argv0;
    return PRINTABLE_BINARY_HELP_NAME;
#else
    if (argv0 && argv0[0] != '\0') {
        return argv0;
    }
    return "printable-binary";
#endif
}

static void print_usage(const char *program_name) {
    fprintf(stderr, "PrintableBinary C - Encode binary data as printable UTF-8 and decode it back\n\n");
    fprintf(stderr, "Usage: %s [options] [file]\n", program_name);
    fprintf(stderr, "Options:\n");
    fprintf(stderr, "  -d, --decode       Decode mode (default is encode mode)\n");
    fprintf(stderr, "  -p, --passthrough  Pass input to stdout unchanged, send encoded data to stderr\n");
    fprintf(stderr, "\nEncoding modes:\n");
    fprintf(stderr, "  -X, --hexlike    Hexlike mode: passthrough ASCII stays as-is, all other bytes\n");
    fprintf(stderr, "  -C, --container  Container mode: encode a file to a self-verifying .pbf.json\n");
    fprintf(stderr, "                   (keeps filename + crc32). With -d, decode a container back.\n");
    fprintf(stderr, "                   shown as uppercase hex runs prefixed by \xCE\x9F\xCF\x87 (Greek Omicron+Chi,\n");
    fprintf(stderr, "                   NOT ASCII 0x \xe2\x80\x94 beware when copying hex for other purposes).\n");
    fprintf(stderr, "                   Use with -d to decode hexlike-encoded data back to binary.\n");
    fprintf(stderr, "\nEncode options (preserve literal characters instead of encoding):\n");
    fprintf(stderr, "  -s, --spaces       Preserve literal spaces (don't encode to visible glyph)\n");
    fprintf(stderr, "  -t, --tabs         Preserve literal tabs (don't encode to visible glyph)\n");
    fprintf(stderr, "  -n, --crlf         Preserve literal CR/LF (don't encode to visible glyph)\n");
    fprintf(stderr, "  -w, --preserve-whitespace  Shorthand for -stn (preserve all whitespace)\n");
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
    fprintf(stderr, "  -S, --strip-whitespace     Strip whitespace before decoding (for formatted input)\n");
    fprintf(stderr, "\nFormat and output options:\n");
    fprintf(stderr, "  -f[=NxM], --format[=NxM]   Format output in groups\n");
    fprintf(stderr, "                              Default: 8x10 (groups of 8 chars, 10 groups per line)\n");
    fprintf(stderr, "  --mappings         Show the byte-to-character mapping table\n");
    fprintf(stderr, "  --mappings-json    Output mappings as JSON\n");
    fprintf(stderr, "  --mappings-csv     Output mappings as CSV\n");
    fprintf(stderr, "  -h, --help         Show this help\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "If no file is specified, input is read from stdin.\n");
    fprintf(stderr, "Output is written to stdout, unless --passthrough is used.\n\n");
    fprintf(stderr, "PrintableBinary encodes every byte (quotes, backslashes, tabs, CR/LF, etc.) into visible, but clearly related, glyphs.\n");
    fprintf(stderr, "You can format the encoded text freely—spaces, newlines, indentation—because the decoder ignores real whitespace.\n");
    fprintf(stderr, "With --spaces, literal spaces are treated as data (and we warn on indented lines).\n");
    fprintf(stderr, "Examples: SPACE→␣, TAB→⇥, CR→⏎, LF→↧, single quote→ʼ, double quote→ˮ, backslash→⧷.\n");
    fprintf(stderr, "This avoids shell-escaping surprises while keeping context obvious.\n\n");
    fprintf(stderr, "When --passthrough is used:\n");
    fprintf(stderr, "  - Original binary data is passed unchanged to stdout\n");
    fprintf(stderr, "  - Encoded representation is sent to stderr\n");
    fprintf(stderr, "  - This allows using the tool in pipelines to monitor binary data\n\n");
    fprintf(stderr, "Environment variables:\n");
    fprintf(stderr, "  PRINTABLE_BINARY_MAP        Override character map lookup path\n");
    fprintf(stderr, "  PRINTABLE_BINARY_MUTE_STATS Set to 1/true/yes to suppress stderr stats\n\n");
    fprintf(stderr, "Examples:\n");
    fprintf(stderr, "  %s binary_file               # Encode binary to UTF-8\n", program_name);
    fprintf(stderr, "  %s -d encoded_file           # Decode UTF-8 to binary\n", program_name);
    fprintf(stderr, "  %s -f=4x10 binary_file       # Encode with formatting\n", program_name);
    fprintf(stderr, "  %s --passthrough file | tool # Monitor binary stream\n", program_name);
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

    // Find the separator hyphen (not part of 0x prefix)
    const char *sep = NULL;
    if (spec[0] == '-') {
        // "-Y" form
        sep = spec;
    } else {
        // Find first hyphen after the start value
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

    // Parse start (before separator)
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

    // Parse end (after separator)
    const char *end_str = sep + 1;
    if (*end_str != '\0') {
        if (!parse_offset_value(end_str, end)) return false;
        *has_end = true;
    }

    return true;
}

// Check if string matches positional range pattern
static bool is_positional_range(const char *s) {
    if (!s || !*s || s[0] == '-') return false;
    // Must contain a hyphen that's not the first character
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

// Parse command line options
static options_t parse_options(int argc, char *argv[]) {
    options_t opts = {
        .decode_mode = false,
        .passthrough_mode = false,
        .format_mode = false,
        .help_mode = false,
        .spaces_mode = false,
        .tabs_mode = false,
        .crlf_mode = false,
        .strip_whitespace = false,
        .preserve_chars = "",
        .format_group = 8,
        .format_groups_per_line = 10,
        .mappings_mode = MAPPINGS_NONE,
        .input_file = NULL,
        .has_range_start = false,
        .has_range_end = false,
        .range_start = 0,
        .range_end = 0,
        .no_double_encode_check = false,
        .hexlike_mode = false
    };

    for (int i = 1; i < argc; i++) {
        char *arg = argv[i];

        if (strcmp(arg, "--") == 0) {
            if (i + 1 < argc) {
                if (opts.input_file) {
                    fprintf(stderr, "Error: Multiple input files specified\n");
                    exit(1);
                }
                opts.input_file = argv[++i];
            }
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
                fprintf(stderr, "Error: Multiple input files specified (%s)\n", arg);
                exit(1);
            }
            opts.input_file = arg;
            continue;
        }

        if (arg[1] == '-') {
            const char *name = arg + 2;
            const char *eq = strchr(name, '=');
            size_t name_len = eq ? (size_t)(eq - name) : strlen(name);
            const char *value = eq ? eq + 1 : NULL;

            if (long_option_equals(name, name_len, "decode")) {
                opts.decode_mode = true;
            } else if (long_option_equals(name, name_len, "passthrough")) {
                opts.passthrough_mode = true;
            } else if (long_option_equals(name, name_len, "spaces")) {
                opts.spaces_mode = true;
            } else if (long_option_equals(name, name_len, "tabs")) {
                opts.tabs_mode = true;
            } else if (long_option_equals(name, name_len, "crlf")) {
                opts.crlf_mode = true;
            } else if (long_option_equals(name, name_len, "strip-whitespace")) {
                opts.strip_whitespace = true;
            } else if (long_option_equals(name, name_len, "range")) {
                if (value && value[0] != '\0') {
                    bool hs, he;
                    int64_t sv, ev;
                    if (!parse_range_spec(value, &hs, &sv, &he, &ev)) {
                        fprintf(stderr, "Error: Invalid range specification: %s\n", value);
                        exit(1);
                    }
                    if (hs) { opts.has_range_start = true; opts.range_start = sv; }
                    if (he) { opts.has_range_end = true; opts.range_end = ev; }
                } else if (i + 1 < argc) {
                    i++;
                    bool hs, he;
                    int64_t sv, ev;
                    if (!parse_range_spec(argv[i], &hs, &sv, &he, &ev)) {
                        fprintf(stderr, "Error: Invalid range specification: %s\n", argv[i]);
                        exit(1);
                    }
                    if (hs) { opts.has_range_start = true; opts.range_start = sv; }
                    if (he) { opts.has_range_end = true; opts.range_end = ev; }
                } else {
                    fprintf(stderr, "Error: --range requires an argument\n");
                    exit(1);
                }
            } else if (long_option_equals(name, name_len, "start")) {
                if (value && value[0] != '\0') {
                    if (!parse_offset_value(value, &opts.range_start)) {
                        fprintf(stderr, "Error: Invalid start offset: %s\n", value);
                        exit(1);
                    }
                    opts.has_range_start = true;
                } else if (i + 1 < argc) {
                    i++;
                    if (!parse_offset_value(argv[i], &opts.range_start)) {
                        fprintf(stderr, "Error: Invalid start offset: %s\n", argv[i]);
                        exit(1);
                    }
                    opts.has_range_start = true;
                } else {
                    fprintf(stderr, "Error: --start requires an argument\n");
                    exit(1);
                }
            } else if (long_option_equals(name, name_len, "end")) {
                if (value && value[0] != '\0') {
                    if (!parse_offset_value(value, &opts.range_end)) {
                        fprintf(stderr, "Error: Invalid end offset: %s\n", value);
                        exit(1);
                    }
                    opts.has_range_end = true;
                } else if (i + 1 < argc) {
                    i++;
                    if (!parse_offset_value(argv[i], &opts.range_end)) {
                        fprintf(stderr, "Error: Invalid end offset: %s\n", argv[i]);
                        exit(1);
                    }
                    opts.has_range_end = true;
                } else {
                    fprintf(stderr, "Error: --end requires an argument\n");
                    exit(1);
                }
            } else if (long_option_equals(name, name_len, "preserve-whitespace")) {
                opts.spaces_mode = true;
                opts.tabs_mode = true;
                opts.crlf_mode = true;
            } else if (long_option_equals(name, name_len, "preserve")) {
                if (value && value[0] != '\0') {
                    strncpy(opts.preserve_chars, value, sizeof(opts.preserve_chars) - 1);
                    opts.preserve_chars[sizeof(opts.preserve_chars) - 1] = '\0';
                } else {
                    fprintf(stderr, "Error: --preserve requires a value (e.g., --preserve=abc)\n");
                    exit(1);
                }
            } else if (long_option_equals(name, name_len, "format")) {
                if (value && value[0] != '\0') {
                    parse_format_spec(&opts, value);
                } else {
                    opts.format_mode = true;
                }
            } else if (long_option_equals(name, name_len, "mappings")) {
                set_mappings_mode(&opts, MAPPINGS_TABLE);
            } else if (long_option_equals(name, name_len, "mappings-json")) {
                set_mappings_mode(&opts, MAPPINGS_JSON);
            } else if (long_option_equals(name, name_len, "mappings-csv")) {
                set_mappings_mode(&opts, MAPPINGS_CSV);
            } else if (long_option_equals(name, name_len, "no-double-encode-check")) {
                opts.no_double_encode_check = true;
            } else if (long_option_equals(name, name_len, "hexlike")) {
                opts.hexlike_mode = true;
            } else if (long_option_equals(name, name_len, "container")) {
                opts.container_mode = true;
            } else if (long_option_equals(name, name_len, "help")) {
                opts.help_mode = true;
            } else {
                fprintf(stderr, "Unknown option: --%.*s\n", (int)name_len, name);
                exit(1);
            }
            continue;
        }

        size_t pos = 1;
        while (arg[pos] != '\0') {
            char opt = arg[pos];
            switch (opt) {
                case 'd':
                    opts.decode_mode = true;
                    pos++;
                    break;
                case 'p':
                    opts.passthrough_mode = true;
                    pos++;
                    break;
                case 's':
                    opts.spaces_mode = true;
                    pos++;
                    break;
                case 't':
                    opts.tabs_mode = true;
                    pos++;
                    break;
                case 'n':
                    opts.crlf_mode = true;
                    pos++;
                    break;
                case 'w':
                    opts.spaces_mode = true;
                    opts.tabs_mode = true;
                    opts.crlf_mode = true;
                    pos++;
                    break;
                case 'S':
                    opts.strip_whitespace = true;
                    pos++;
                    break;
                case 'X':
                    opts.hexlike_mode = true;
                    pos++;
                    break;
                case 'C':
                    opts.container_mode = true;
                    pos++;
                    break;
                case 'P': {
                    if (arg[pos + 1] != '\0') {
                        const char *value = &arg[pos + 1];
                        strncpy(opts.preserve_chars, value, sizeof(opts.preserve_chars) - 1);
                        opts.preserve_chars[sizeof(opts.preserve_chars) - 1] = '\0';
                        pos = strlen(arg);
                    } else if (i + 1 < argc && argv[i + 1][0] != '-') {
                        const char *value = argv[++i];
                        strncpy(opts.preserve_chars, value, sizeof(opts.preserve_chars) - 1);
                        opts.preserve_chars[sizeof(opts.preserve_chars) - 1] = '\0';
                        pos = strlen(arg);
                    } else {
                        fprintf(stderr, "Error: -P requires a value\n");
                        exit(1);
                    }
                    break;
                }
                case 'h':
                    opts.help_mode = true;
                    pos++;
                    break;
                case 'f': {
                    if (arg[pos + 1] != '\0') {
                        const char *value = &arg[pos + 1];
                        pos = strlen(arg);
                        parse_format_spec(&opts, value);
                    } else {
                        opts.format_mode = true;
                        pos++;
                    }
                    break;
                }
                default:
                    fprintf(stderr, "Unknown option: -%c\n", opt);
                    exit(1);
            }
        }
    }

    return opts;
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


#ifndef PRINTABLE_BINARY_NO_MAIN
/* CLI-only leak-test support: the WASM build excludes the buffer_free/CLI path. */
#ifndef __EMSCRIPTEN__
/* ---- memory-leak suite support (driven by test/leak_test via --leak-seconds) ---- */
static long pb_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}
static long pb_rss_kb(void) {
#if defined(__APPLE__)
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return -1;
    return (long)(info.resident_size / 1024);
#elif defined(_WIN32)
    PROCESS_MEMORY_COUNTERS pmc;
    if (!GetProcessMemoryInfo(GetCurrentProcess(), &pmc, sizeof(pmc))) return -1;
    return (long)(pmc.WorkingSetSize / 1024);
#else
    FILE *f = fopen("/proc/self/statm", "r");
    if (!f) return -1;
    long total = 0, resident = 0;
    int n = fscanf(f, "%ld %ld", &total, &resident);
    fclose(f);
    return n == 2 ? resident * (sysconf(_SC_PAGESIZE) / 1024) : -1;
#endif
}
/* Time-bounded encode/decode loop that self-reports RSS, so the leak suite can
 * watch the C standalone's buffer_t alloc/free path for growth over time. */
static void run_leak_loop(long seconds) {
    if (seconds <= 0) seconds = 8;
    long start = pb_now_ms(), deadline = start + seconds * 1000L, last = start;
    static uint8_t buf[8192];
    uint64_t rng = 0x9E3779B97F4A7C15ULL;
    options_t opts;
    memset(&opts, 0, sizeof opts);
    printf("RSS %ld\n", pb_rss_kb());
    fflush(stdout);
    for (long i = 0;; i++) {
        if ((i & 0x3FF) == 0) {
            long t = pb_now_ms();
            if (t >= deadline) break;
            if (t - last >= 100) { printf("RSS %ld\n", pb_rss_kb()); fflush(stdout); last = t; }
        }
        rng = rng * 6364136223846793005ULL + 1442695040888963407ULL;
        size_t len = (size_t)((rng >> 33) % (sizeof(buf) + 1));
        for (size_t k = 0; k < len; k++) { rng = rng * 6364136223846793005ULL + 1442695040888963407ULL; buf[k] = (uint8_t)(rng >> 33); }
        buffer_t enc = encode_data(buf, len, &opts);
        buffer_t dec = decode_data((uint8_t *)enc.data, enc.size, false);
        buffer_free(&dec);
        buffer_free(&enc);
    }
    printf("RSS %ld\n", pb_rss_kb());
    fflush(stdout);
}
#endif /* !__EMSCRIPTEN__ */

int main(int argc, char *argv[]) {
#ifndef __EMSCRIPTEN__
    // Leak-test mode (test/leak_test): long-lived encode/decode loop, then exit.
    for (int ai = 1; ai < argc; ai++) {
        if (strcmp(argv[ai], "--leak-seconds") == 0 && ai + 1 < argc) {
            init_tables(argv[0]);
            run_leak_loop(atol(argv[ai + 1]));
            return 0;
        }
    }
#endif /* !__EMSCRIPTEN__ */
    // Parse command line options first (needed for help/usage)
    options_t opts = parse_options(argc, argv);
    const char *program_display_name = resolve_program_name(argv[0]);
    bool stats_enabled = !env_var_truthy(getenv("PRINTABLE_BINARY_MUTE_STATS"));

    // Initialize encoding/decoding tables (after options so argv[0] is available)
    init_tables(argv[0]);

    if (opts.help_mode) {
        print_usage(program_display_name);
        return 0;
    }

    if (opts.mappings_mode != MAPPINGS_NONE) {
        print_mappings(opts.mappings_mode);
        return 0;
    }

    // Check for terminal input when no file specified
    if (!opts.input_file && isatty(STDIN_FILENO)) {
        print_usage(program_display_name);
        return 0;
    }

    // Measure the user-visible pipeline: input read, codec work, and output write.
    double throughput_started_at = throughput_now_seconds();

    // Read input
    buffer_t input = read_file(opts.input_file);
    size_t input_bytes_read = input.size;

    // Apply byte range if specified
    if (opts.has_range_start || opts.has_range_end) {
        int64_t start = opts.has_range_start ? opts.range_start : 0;
        int64_t end = opts.has_range_end ? opts.range_end : (int64_t)input.size - 1;

        // Handle negative start (from end)
        if (start < 0) {
            start = (int64_t)input.size + start;
            if (start < 0) start = 0;
        }

        if (start >= (int64_t)input.size) {
            fprintf(stderr, "Warning: start offset %lld exceeds input size %zu\n",
                    (long long)start, input.size);
            input.size = 0;
        } else if (start > end) {
            fprintf(stderr, "Warning: start offset exceeds end offset, empty range\n");
            input.size = 0;
        } else {
            if (end >= (int64_t)input.size) {
                fprintf(stderr, "Warning: end offset %lld exceeds input size %zu, clamping to %zu\n",
                        (long long)end, input.size, input.size - 1);
                end = (int64_t)input.size - 1;
            }
            size_t new_size = (size_t)(end - start + 1);
            if (start > 0) {
                memmove(input.data, input.data + start, new_size);
            }
            input.size = new_size;
        }
    }

    if (opts.container_mode) {
        /* Only --spaces is honored in container mode; --tabs/--crlf/-w/--preserve
         * would put raw tab/CR/LF (or arbitrary chars) into the JSON value, breaking
         * single-line-JSON validity and the tab/CR/LF-stripping transport-resistance. */
        if (opts.tabs_mode || opts.crlf_mode || opts.preserve_chars[0] != '\0') {
            fprintf(stderr, "Error: --tabs/--crlf/-w/--preserve are not supported with --container (only --spaces is honored; other whitespace stays encoded)\n");
            return 1;
        }
        if (opts.decode_mode) {
            size_t dlen;
            const char *draw = cj_get_string(input.data, input.size, "data", &dlen);
            if (!draw) { fprintf(stderr, "Error: not a printable-binary-file container (missing 'data')\n"); return 1; }
            /* Flagless crc-probe: no schema flag records whether --spaces was used; the
             * crc32_encoded oracle disambiguates. Try keeping literal spaces (DATA in a
             * --spaces container); if the crc mismatches, strip them as transport noise. */
            size_t clen;
            char *clean = cj_canonical(draw, dlen, &clen, 1);
            bool spaces = true;
            size_t celen;
            const char *ce = cj_get_string(input.data, input.size, "crc32_encoded", &celen);
            if (ce) {
                char hx[9]; snprintf(hx, 9, "%08x", (unsigned int)pb_crc32(clean, clen));
                if (celen != 8 || memcmp(hx, ce, 8) != 0) {
                    size_t slen;
                    char *stripped = cj_canonical(draw, dlen, &slen, 0);
                    char hs[9]; snprintf(hs, 9, "%08x", (unsigned int)pb_crc32(stripped, slen));
                    if (celen == 8 && memcmp(hs, ce, 8) == 0) {
                        /* Literal spaces were noise. If the space glyph is ALSO present, the
                         * payload mixed real (glyph) spaces with formatting spaces -> warn. */
                        const char *sg = (const char *)encode_table[' '].bytes;
                        size_t sglen = encode_table[' '].length;
                        if (cj_contains(clean, clen, sg, sglen)) {
                            fprintf(stderr, "Warning: literal spaces in container data were assumed to be ignorable formatting because the space glyph %.*s was also present; stripping them\n", (int)sglen, sg);
                        }
                        free(clean);
                        clean = stripped;
                        clen = slen;
                        spaces = false;
                    } else {
                        free(stripped); free(clean);
                        fprintf(stderr, "Error: container crc32_encoded mismatch (data corrupted)\n");
                        return 1;
                    }
                }
            }
            buffer_t dec = decode_data((uint8_t *)clean, clen, spaces);
            free(clean);
            size_t colen;
            const char *co = cj_get_string(input.data, input.size, "crc32", &colen);
            if (co) {
                char hx[9]; snprintf(hx, 9, "%08x", (unsigned int)pb_crc32(dec.data, dec.size));
                if (colen != 8 || memcmp(hx, co, 8) != 0) { fprintf(stderr, "Error: container crc32 mismatch (decoded data corrupted)\n"); return 1; }
            }
            fwrite(dec.data, 1, dec.size, stdout);
            fflush(stdout);
            print_input_throughput(stats_enabled, input_bytes_read, throughput_started_at);
            return 0;
        } else {
            options_t enc_opts = opts;
            enc_opts.tabs_mode = false;
            enc_opts.crlf_mode = false;
            enc_opts.preserve_chars[0] = '\0';
            buffer_t enc = encode_data((uint8_t *)input.data, input.size, &enc_opts);
            size_t clen;
            char *clean = cj_canonical(enc.data, enc.size, &clen, opts.spaces_mode ? 1 : 0);
            char crc_orig[9], crc_enc[9];
            snprintf(crc_orig, 9, "%08x", (unsigned int)pb_crc32(input.data, input.size));
            snprintf(crc_enc, 9, "%08x", (unsigned int)pb_crc32(clean, clen));
            free(clean);
            const char *fname = (opts.input_file && strcmp(opts.input_file, "-") != 0) ? cj_basename(opts.input_file) : "";
            printf("{\n  \"format\": \"printable-binary-file\",\n  \"version\": 1,\n  \"filename\": \"");
            cj_fputs_escaped(stdout, fname, strlen(fname));
            printf("\",\n  \"byte_length\": %zu,\n  \"crc32\": \"%s\",\n  \"crc32_encoded\": \"%s\",\n  \"data\": \"", input.size, crc_orig, crc_enc);
            fwrite(enc.data, 1, enc.size, stdout);
            printf("\"\n}\n");
            fflush(stdout);
            print_input_throughput(stats_enabled, input_bytes_read, throughput_started_at);
            return 0;
        }
    }


    if (opts.decode_mode) {
        if (opts.passthrough_mode) {
            fprintf(stderr, "Warning: --passthrough ignored in decode mode\n");
        }

        if (stats_enabled) {
            fprintf(stderr, "Decoding mode: Input size is %zu bytes\n", input.size);
        }

        if (opts.hexlike_mode) {
            // Hexlike decode path
            bool found_hex = false;
            buffer_t decoded = hexlike_decode((uint8_t*)input.data, input.size, &found_hex);

            if (!found_hex) {
                fprintf(stderr, "Warning: no hexlike (\xCE\x9F\xCF\x87) sequences found in input\n");
                // Also check for PB glyphs
                pb_double_encode_info_t de_info = detect_double_encode(input.data, input.size, 0.05f);
                if (de_info.detected) {
                    fprintf(stderr, "Warning: input appears to contain standard printable-binary encoding\n");
                }
            }

            if (stats_enabled) {
                fprintf(stderr, "Decoded result size: %zu bytes\n", decoded.size);
            }

            fwrite(decoded.data, 1, decoded.size, stdout);
            free(decoded.data);
        } else {
            // Standard PB decode path
            // Clean input and decode
            buffer_t cleaned = clean_decode_input(&input, opts.spaces_mode, opts.strip_whitespace);
            if (stats_enabled) {
                if (opts.spaces_mode) {
                    fprintf(stderr, "After whitespace removal (tabs/newlines/CR): %zu bytes\n", cleaned.size);
                } else {
                    fprintf(stderr, "After whitespace removal: %zu bytes\n", cleaned.size);
                }
            }

            buffer_t decoded = decode_data((uint8_t*)cleaned.data, cleaned.size, opts.spaces_mode);
            if (stats_enabled) {
                fprintf(stderr, "Decoded result size: %zu bytes\n", decoded.size);
            }

            // Warn if hexlike encoding detected in regular PB decode
            if (detect_hexlike((uint8_t*)input.data, input.size)) {
                fprintf(stderr, "Warning: input appears to contain hexlike (\xCE\x9F\xCF\x87) encoding; use --hexlike -d to decode\n");
            }

            // Write decoded data to stdout
            fwrite(decoded.data, 1, decoded.size, stdout);

            free(cleaned.data);
            free(decoded.data);
        }
    } else {
        // Encode mode

        if (opts.hexlike_mode) {
            // Hexlike encode path
            if (opts.passthrough_mode) {
                fwrite(input.data, 1, input.size, stdout);
            }

            buffer_t encoded = hexlike_encode((uint8_t*)input.data, input.size, &opts);
            if (stats_enabled) {
                fprintf(stderr, "Encoded %zu bytes of input to %zu bytes\n", input.size, encoded.size);
            }

            if (opts.passthrough_mode) {
                fwrite(encoded.data, 1, encoded.size, stderr);
            } else {
                fwrite(encoded.data, 1, encoded.size, stdout);
            }

            free(encoded.data);
        } else {
            // Standard PB encode path

            // Check for double-encoding
            if (!opts.no_double_encode_check) {
                pb_double_encode_info_t de_info = detect_double_encode(input.data, input.size, 0.05f);
                if (de_info.detected) {
                    fprintf(stderr,
                        "Warning: Input appears to already be printable-binary encoded (%.1f%% detection).\n"
                        "         Use --no-double-encode-check to suppress this warning.\n",
                        de_info.confidence * 100.0f);
                }
            }

            if (opts.passthrough_mode) {
                // Write original data to stdout
                fwrite(input.data, 1, input.size, stdout);
            }

            // Encode the data
            buffer_t encoded = encode_data((uint8_t*)input.data, input.size, &opts);
            if (stats_enabled) {
                fprintf(stderr, "Encoded %zu bytes of input to %zu bytes\n", input.size, encoded.size);
            }

            buffer_t *output = &encoded;
            buffer_t formatted;

            // Apply formatting if requested
            if (opts.format_mode) {
                formatted = format_output(&encoded, opts.format_group, opts.format_groups_per_line, opts.spaces_mode);
                output = &formatted;
            }

            // Write encoded output
            if (opts.passthrough_mode) {
                // Send encoded data to stderr
                fwrite(output->data, 1, output->size, stderr);
            } else {
                // Send encoded data to stdout
                fwrite(output->data, 1, output->size, stdout);
            }

            free(encoded.data);
            if (opts.format_mode) {
                free(formatted.data);
            }
        }
    }

    fflush(stdout);
    fflush(stderr);
    print_input_throughput(stats_enabled, input_bytes_read, throughput_started_at);
    free(input.data);
    return 0;
}
#endif /* PRINTABLE_BINARY_NO_MAIN */
