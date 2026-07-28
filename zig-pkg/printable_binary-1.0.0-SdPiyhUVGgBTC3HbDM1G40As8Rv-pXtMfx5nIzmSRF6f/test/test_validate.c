/*
 * Test program for pb_validate() FFI function
 * Compile with: cc -o test_validate test_validate.c ../src/printable_binary.c -I../src
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include "../src/printable_binary.h"

static int tests_passed = 0;
static int tests_failed = 0;

#define TEST(name) printf("Test: %s ... ", name)
#define PASS() do { printf("\033[32mPASS\033[0m\n"); tests_passed++; } while(0)
#define FAIL(msg) do { printf("\033[31mFAIL\033[0m: %s\n", msg); tests_failed++; } while(0)

static void test_valid_encoded_string(void) {
    TEST("Valid encoded string");

    // "Hello" encoded: H, e, l, l, o are ASCII pass-through in our encoding
    const char *input = "Hello";
    pb_validation_result_t result = pb_validate(input, strlen(input), PB_WS_REJECT_ALL);

    if (result.is_valid == 1 && result.error_position == -1 && result.error_codepoint == 0) {
        PASS();
    } else {
        char msg[256];
        snprintf(msg, sizeof(msg), "is_valid=%d, error_position=%lld, error_codepoint=U+%04X",
                 result.is_valid, (long long)result.error_position, result.error_codepoint);
        FAIL(msg);
    }
}

static void test_valid_with_special_chars(void) {
    TEST("Valid string with special encoded chars");

    // Test with some mapped characters: · (NUL mapping), ␣ (space mapping)
    const char *input = "\xC2\xB7"; // · (middle dot, maps to NUL)
    pb_validation_result_t result = pb_validate(input, strlen(input), PB_WS_REJECT_ALL);

    if (result.is_valid == 1) {
        PASS();
    } else {
        char msg[256];
        snprintf(msg, sizeof(msg), "error_position=%lld, error_codepoint=U+%04X",
                 (long long)result.error_position, result.error_codepoint);
        FAIL(msg);
    }
}

static void test_invalid_unrecognized_codepoint(void) {
    TEST("Invalid - unrecognized codepoint");

    // Chinese character not in our encoding map
    const char *input = "\xE4\xB8\x96"; // 世
    pb_validation_result_t result = pb_validate(input, strlen(input), PB_WS_REJECT_ALL);

    if (result.is_valid == 0 && result.error_position == 0) {
        PASS();
    } else {
        char msg[256];
        snprintf(msg, sizeof(msg), "Expected invalid at position 0, got is_valid=%d, error_position=%lld",
                 result.is_valid, (long long)result.error_position);
        FAIL(msg);
    }
}

static void test_invalid_truncated_utf8(void) {
    TEST("Invalid - truncated UTF-8 sequence");

    // Start of 2-byte sequence but missing continuation
    const char input[] = { '\xC2' };
    pb_validation_result_t result = pb_validate(input, 1, PB_WS_REJECT_ALL);

    if (result.is_valid == 0 && result.error_position == 0) {
        PASS();
    } else {
        char msg[256];
        snprintf(msg, sizeof(msg), "Expected invalid at position 0, got is_valid=%d, error_position=%lld",
                 result.is_valid, (long long)result.error_position);
        FAIL(msg);
    }
}

static void test_invalid_bad_continuation(void) {
    TEST("Invalid - bad UTF-8 continuation byte");

    // C2 should be followed by 80-BF, but we give it a non-continuation byte
    const char input[] = { '\xC2', '\x00' };
    pb_validation_result_t result = pb_validate(input, 2, PB_WS_REJECT_ALL);

    if (result.is_valid == 0 && result.error_position == 0) {
        PASS();
    } else {
        char msg[256];
        snprintf(msg, sizeof(msg), "Expected invalid at position 0, got is_valid=%d, error_position=%lld",
                 result.is_valid, (long long)result.error_position);
        FAIL(msg);
    }
}

static void test_whitespace_reject_all(void) {
    TEST("Whitespace rejected when flags = REJECT_ALL");

    const char *input = "A B";  // Contains space
    pb_validation_result_t result = pb_validate(input, strlen(input), PB_WS_REJECT_ALL);

    if (result.is_valid == 0 && result.error_position == 1) {
        PASS();
    } else {
        char msg[256];
        snprintf(msg, sizeof(msg), "Expected invalid at position 1, got is_valid=%d, error_position=%lld",
                 result.is_valid, (long long)result.error_position);
        FAIL(msg);
    }
}

static void test_whitespace_allow_space(void) {
    TEST("Whitespace allowed with ALLOW_SPACE flag");

    const char *input = "A B";
    pb_validation_result_t result = pb_validate(input, strlen(input), PB_WS_ALLOW_SPACE);

    if (result.is_valid == 1) {
        PASS();
    } else {
        char msg[256];
        snprintf(msg, sizeof(msg), "Expected valid, got is_valid=%d, error_position=%lld",
                 result.is_valid, (long long)result.error_position);
        FAIL(msg);
    }
}

static void test_whitespace_allow_tab(void) {
    TEST("Tab allowed with ALLOW_TAB flag");

    const char *input = "A\tB";
    pb_validation_result_t result = pb_validate(input, strlen(input), PB_WS_ALLOW_TAB);

    if (result.is_valid == 1) {
        PASS();
    } else {
        char msg[256];
        snprintf(msg, sizeof(msg), "Expected valid, got is_valid=%d, error_position=%lld",
                 result.is_valid, (long long)result.error_position);
        FAIL(msg);
    }
}

static void test_whitespace_allow_lf(void) {
    TEST("LF allowed with ALLOW_LF flag");

    const char *input = "A\nB";
    pb_validation_result_t result = pb_validate(input, strlen(input), PB_WS_ALLOW_LF);

    if (result.is_valid == 1) {
        PASS();
    } else {
        char msg[256];
        snprintf(msg, sizeof(msg), "Expected valid, got is_valid=%d, error_position=%lld",
                 result.is_valid, (long long)result.error_position);
        FAIL(msg);
    }
}

static void test_whitespace_allow_cr(void) {
    TEST("CR allowed with ALLOW_CR flag");

    const char *input = "A\rB";
    pb_validation_result_t result = pb_validate(input, strlen(input), PB_WS_ALLOW_CR);

    if (result.is_valid == 1) {
        PASS();
    } else {
        char msg[256];
        snprintf(msg, sizeof(msg), "Expected valid, got is_valid=%d, error_position=%lld",
                 result.is_valid, (long long)result.error_position);
        FAIL(msg);
    }
}

static void test_whitespace_allow_all(void) {
    TEST("All whitespace allowed with ALLOW_ALL flag");

    const char *input = "A \t\n\rB";
    pb_validation_result_t result = pb_validate(input, strlen(input), PB_WS_ALLOW_ALL);

    if (result.is_valid == 1) {
        PASS();
    } else {
        char msg[256];
        snprintf(msg, sizeof(msg), "Expected valid, got is_valid=%d, error_position=%lld",
                 result.is_valid, (long long)result.error_position);
        FAIL(msg);
    }
}

static void test_empty_input(void) {
    TEST("Empty input is valid");

    pb_validation_result_t result = pb_validate("", 0, PB_WS_REJECT_ALL);

    if (result.is_valid == 1 && result.error_position == -1) {
        PASS();
    } else {
        char msg[256];
        snprintf(msg, sizeof(msg), "Expected valid, got is_valid=%d, error_position=%lld",
                 result.is_valid, (long long)result.error_position);
        FAIL(msg);
    }
}

static void test_null_input(void) {
    TEST("NULL input is valid (treated as empty)");

    pb_validation_result_t result = pb_validate(NULL, 0, PB_WS_REJECT_ALL);

    if (result.is_valid == 1 && result.error_position == -1) {
        PASS();
    } else {
        char msg[256];
        snprintf(msg, sizeof(msg), "Expected valid, got is_valid=%d, error_position=%lld",
                 result.is_valid, (long long)result.error_position);
        FAIL(msg);
    }
}

static void test_error_position_accuracy(void) {
    TEST("Error position reports correct byte offset");

    // Valid chars followed by invalid: "AB" + Chinese char
    const char *input = "AB\xE4\xB8\x96";  // AB世
    pb_validation_result_t result = pb_validate(input, strlen(input), PB_WS_REJECT_ALL);

    if (result.is_valid == 0 && result.error_position == 2) {
        PASS();
    } else {
        char msg[256];
        snprintf(msg, sizeof(msg), "Expected error at position 2, got is_valid=%d, error_position=%lld",
                 result.is_valid, (long long)result.error_position);
        FAIL(msg);
    }
}

static void test_error_codepoint_reported(void) {
    TEST("Error codepoint is correctly reported");

    // Chinese character 世 = U+4E16
    const char *input = "\xE4\xB8\x96";
    pb_validation_result_t result = pb_validate(input, strlen(input), PB_WS_REJECT_ALL);

    if (result.is_valid == 0 && result.error_codepoint == 0x4E16) {
        PASS();
    } else {
        char msg[256];
        snprintf(msg, sizeof(msg), "Expected codepoint U+4E16, got U+%04X", result.error_codepoint);
        FAIL(msg);
    }
}

static void test_combined_whitespace_flags(void) {
    TEST("Combined whitespace flags work");

    // Allow space and tab, but not LF
    const char *input = "A \tB";
    unsigned int flags = PB_WS_ALLOW_SPACE | PB_WS_ALLOW_TAB;
    pb_validation_result_t result = pb_validate(input, strlen(input), flags);

    if (result.is_valid == 1) {
        PASS();
    } else {
        char msg[256];
        snprintf(msg, sizeof(msg), "Expected valid, got is_valid=%d, error_position=%lld",
                 result.is_valid, (long long)result.error_position);
        FAIL(msg);
    }
}

static void test_combined_flags_partial_reject(void) {
    TEST("Combined flags reject unallowed whitespace");

    // Allow only space, should reject tab
    const char *input = "A\tB";
    pb_validation_result_t result = pb_validate(input, strlen(input), PB_WS_ALLOW_SPACE);

    if (result.is_valid == 0 && result.error_position == 1) {
        PASS();
    } else {
        char msg[256];
        snprintf(msg, sizeof(msg), "Expected invalid at position 1, got is_valid=%d, error_position=%lld",
                 result.is_valid, (long long)result.error_position);
        FAIL(msg);
    }
}

int main(int argc, char *argv[]) {
    (void)argc;

    printf("\n=== pb_validate() Test Suite ===\n\n");

    // Initialize the library
    pb_init(argv[0]);

    // Run all tests
    test_valid_encoded_string();
    test_valid_with_special_chars();
    test_invalid_unrecognized_codepoint();
    test_invalid_truncated_utf8();
    test_invalid_bad_continuation();
    test_whitespace_reject_all();
    test_whitespace_allow_space();
    test_whitespace_allow_tab();
    test_whitespace_allow_lf();
    test_whitespace_allow_cr();
    test_whitespace_allow_all();
    test_empty_input();
    test_null_input();
    test_error_position_accuracy();
    test_error_codepoint_reported();
    test_combined_whitespace_flags();
    test_combined_flags_partial_reject();

    // Summary
    printf("\n=== Test Summary ===\n");
    printf("Passed: %d\n", tests_passed);
    printf("Failed: %d\n", tests_failed);

    if (tests_failed > 0) {
        printf("\n\033[31mSome tests failed!\033[0m\n");
        return 1;
    }

    printf("\n\033[32mAll tests passed!\033[0m\n");
    return 0;
}
