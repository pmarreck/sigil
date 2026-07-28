/*
 * PrintableBinary - FFI Header
 * C API for encoding/decoding binary data as printable UTF-8
 *
 * This header can be used with either:
 * - The C implementation (src/printable_binary.c)
 * - The Zig implementation built as a library (src/zig/printable_binary.zig)
 */

#ifndef PRINTABLE_BINARY_H
#define PRINTABLE_BINARY_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================================
 * Validation API
 * ============================================================================ */

/**
 * Whitespace handling flags for validation.
 * Can be combined with bitwise OR.
 */
typedef enum {
    PB_WS_REJECT_ALL  = 0,       /**< Reject all whitespace characters */
    PB_WS_ALLOW_SPACE = 1 << 0,  /**< Allow space (0x20) */
    PB_WS_ALLOW_TAB   = 1 << 1,  /**< Allow tab (0x09) */
    PB_WS_ALLOW_LF    = 1 << 2,  /**< Allow line feed (0x0A) */
    PB_WS_ALLOW_CR    = 1 << 3,  /**< Allow carriage return (0x0D) */
    PB_WS_ALLOW_ALL   = 0x0F     /**< Allow all whitespace */
} pb_whitespace_flags_t;

/**
 * Result of validating a printable-binary encoded string.
 */
typedef struct {
    int is_valid;           /**< 0 = invalid, 1 = valid */
    int64_t error_position; /**< -1 if valid, else byte offset of first invalid char */
    uint32_t error_codepoint; /**< The invalid codepoint, or 0 if valid */
} pb_validation_result_t;

/**
 * Validate that a string contains only valid printable-binary encoded characters.
 *
 * @param input     Pointer to the UTF-8 encoded string to validate
 * @note      input may be NULL only when input_len == 0. NULL with a
 *            nonzero length returns an error result (error_code != 0,
 *            or is_valid/detected == 0) instead of dereferencing NULL.
 * @param input_len Length of the input in bytes
 * @param ws_flags  Bitfield of pb_whitespace_flags_t values
 * @return          Validation result with error details if invalid
 */
pb_validation_result_t pb_validate(const char *input, size_t input_len, unsigned int ws_flags);

/* ============================================================================
 * Range API
 * ============================================================================ */

/**
 * Warning codes from range resolution.
 */
typedef enum {
    PB_RANGE_OK              = 0, /**< No warning */
    PB_RANGE_START_EXCEEDS   = 1, /**< Start offset >= input length */
    PB_RANGE_EMPTY           = 2, /**< Start > end (empty range) */
    PB_RANGE_END_CLAMPED     = 3  /**< End was clamped to input length */
} pb_range_warning_t;

/**
 * Result of resolving byte-range arguments against an input length.
 */
typedef struct {
    size_t offset;               /**< Byte offset to start from */
    size_t length;               /**< Number of bytes in range */
    pb_range_warning_t warning;  /**< Warning code */
} pb_range_result_t;

/**
 * Resolve optional start/end byte-range arguments against an input length.
 * Pure function — no I/O, no allocations.
 *
 * @param input_len  Length of the input data in bytes
 * @param has_start  Non-zero if start is specified
 * @param start      Start byte offset (inclusive; negative counts from end)
 * @param has_end    Non-zero if end is specified
 * @param end        End byte offset (inclusive)
 * @return           Range result with offset, length, and warning
 */
pb_range_result_t pb_apply_range(size_t input_len, int has_start, int64_t start, int has_end, int64_t end);

/* ============================================================================
 * Encode/Decode/Format API (Zig FFI)
 * ============================================================================ */

/**
 * Encode flags - control which characters are preserved as-is.
 * Can be combined with bitwise OR.
 */
typedef enum {
    PB_ENCODE_NONE = 0,                 /**< Encode everything */
    PB_ENCODE_PRESERVE_SPACES = 1 << 0, /**< Preserve literal spaces */
    PB_ENCODE_PRESERVE_TABS = 1 << 1,   /**< Preserve literal tabs */
    PB_ENCODE_PRESERVE_CRLF = 1 << 2,   /**< Preserve literal CR/LF */
    PB_ENCODE_PRESERVE_ALL_WS = 0x07,   /**< Preserve all whitespace */
    PB_ENCODE_SKIP_DOUBLE_CHECK = 1 << 3 /**< Skip double-encoding detection */
} pb_encode_flags_t;

/**
 * Decode flags - control decoding behavior.
 * Can be combined with bitwise OR.
 */
typedef enum {
    PB_DECODE_NONE = 0,              /**< Default decoding */
    PB_DECODE_SPACES_MODE = 1 << 0,  /**< Treat literal spaces as data */
    PB_DECODE_STRIP_WS = 1 << 1      /**< Strip whitespace before decoding */
} pb_decode_flags_t;

/**
 * Result structure for FFI functions that return allocated data.
 * Caller must call pb_free() on data when done.
 */
typedef struct {
    char *data;       /**< Pointer to allocated data, or NULL on error */
    size_t len;       /**< Length of data in bytes, or 0 on error */
    int error_code;   /**< 0 = success, non-zero = error */
} pb_ffi_result_t;

/**
 * Free memory allocated by pb_encode, pb_decode, or pb_format.
 *
 * @param ptr Pointer returned by pb_encode/pb_decode/pb_format
 * @param len Length that was returned with the pointer
 */
void pb_free(char *ptr, size_t len);

/**
 * CRC-32/ISO-HDLC of `input_len` bytes at `input` (the zip/gzip/png CRC); used
 * for printable-binary-file.json container integrity. NULL or zero-length input
 * yields the CRC of empty input (0).
 */
uint32_t pb_crc32(const char *input, size_t input_len);

/**
 * Encode binary data to printable UTF-8.
 * Caller must call pb_free() on result.data when done.
 *
 * @param input             Pointer to binary data to encode
 * @note      input may be NULL only when input_len == 0. NULL with a
 *            nonzero length returns an error result (error_code != 0,
 *            or is_valid/detected == 0) instead of dereferencing NULL.
 * @param input_len         Length of input in bytes
 * @param flags             Bitfield of pb_encode_flags_t values
 * @param preserve_chars    Additional characters to preserve (or NULL)
 * @param preserve_chars_len Length of preserve_chars
 * @return                  Result with encoded data or error
 */
pb_ffi_result_t pb_encode(
    const char *input,
    size_t input_len,
    unsigned int flags,
    const char *preserve_chars,
    size_t preserve_chars_len
);

/**
 * Decode printable UTF-8 back to binary data.
 * Caller must call pb_free() on result.data when done.
 *
 * @param input     Pointer to encoded UTF-8 string
 * @note      input may be NULL only when input_len == 0. NULL with a
 *            nonzero length returns an error result (error_code != 0,
 *            or is_valid/detected == 0) instead of dereferencing NULL.
 * @param input_len Length of input in bytes
 * @param flags     Bitfield of pb_decode_flags_t values
 * @return          Result with decoded data or error
 */
pb_ffi_result_t pb_decode(
    const char *input,
    size_t input_len,
    unsigned int flags
);

/**
 * Format encoded output into groups for readability.
 * Caller must call pb_free() on result.data when done.
 *
 * @param input           Pointer to encoded data
 * @note      input may be NULL only when input_len == 0. NULL with a
 *            nonzero length returns an error result (error_code != 0,
 *            or is_valid/detected == 0) instead of dereferencing NULL.
 * @param input_len       Length of input in bytes
 * @param group_size      Characters per group (default: 8)
 * @param groups_per_line Groups per line (default: 10)
 * @param use_tabs        Use tabs instead of spaces between groups
 * @return                Result with formatted data or error
 */
pb_ffi_result_t pb_format(
    const char *input,
    size_t input_len,
    size_t group_size,
    size_t groups_per_line,
    int use_tabs
);

/**
 * Get the UTF-8 mapping for a byte value.
 * Returns a pointer to static data - do not free.
 *
 * @param byte The byte value (0-255)
 * @return     Pointer to UTF-8 string
 */
const char *pb_get_mapping(uint8_t byte);

/**
 * Get the length of the UTF-8 mapping for a byte value.
 *
 * @param byte The byte value (0-255)
 * @return     Length in bytes of the mapping
 */
size_t pb_get_mapping_len(uint8_t byte);

/* ============================================================================
 * Double-Encoding Detection API
 * ============================================================================ */

/**
 * Result of double-encoding detection.
 */
typedef struct {
    int detected;     /**< 0 = not detected, 1 = detected */
    float confidence; /**< 0.0 to 1.0 — ratio of high-confidence PB glyphs */
} pb_double_encode_info_t;

/**
 * Detect whether input appears to be already printable-binary encoded.
 * Iterates input as UTF-8 characters, checks each against the decode map,
 * and counts high-confidence glyphs (those whose encoding differs from
 * the raw byte).
 *
 * @param input     Pointer to the UTF-8 input to check
 * @note      input may be NULL only when input_len == 0. NULL with a
 *            nonzero length returns an error result (error_code != 0,
 *            or is_valid/detected == 0) instead of dereferencing NULL.
 * @param input_len Length of the input in bytes
 * @param threshold Confidence threshold (e.g. 0.05 for 5%)
 * @return          Detection result with confidence ratio
 */
pb_double_encode_info_t pb_detect_double_encode(const char *input, size_t input_len, float threshold);

/* ============================================================================
 * Hexlike API (passthrough ASCII stays as-is; other bytes -> Οχ-prefixed hex)
 * ============================================================================ */

/**
 * Encode binary data to hexlike format. Caller must call pb_free() on result.data.
 * @param input      Binary data (may be NULL only when input_len == 0)
 * @param input_len  Length of input in bytes
 * @param spaces     Non-zero to preserve literal spaces as passthrough
 * @return           Result with hexlike-encoded data or error
 */
pb_ffi_result_t pb_hexlike_encode(const char *input, size_t input_len, int spaces);

/**
 * Decode hexlike text back to binary. Caller must call pb_free() on result.data.
 * @param input      Hexlike-encoded text (may be NULL only when input_len == 0)
 * @param input_len  Length of input in bytes
 * @param spaces     Non-zero to treat literal spaces as data
 * @return           Result with decoded data or error
 */
pb_ffi_result_t pb_hexlike_decode(const char *input, size_t input_len, int spaces);

/**
 * Detect whether input appears to be hexlike-encoded.
 * @return 1 if hexlike, 0 otherwise (also 0 on NULL with input_len > 0)
 */
int pb_detect_hexlike(const char *input, size_t input_len);

/* ============================================================================
 * C Implementation Only
 * ============================================================================ */

/**
 * Initialize the printable-binary library (C implementation only).
 * Must be called before using pb_validate() with the C implementation.
 * Not needed when using the Zig implementation.
 *
 * @param argv0 Path to the executable (for finding character map), or NULL
 */
void pb_init(const char *argv0);

#ifdef __cplusplus
}
#endif

#endif /* PRINTABLE_BINARY_H */
