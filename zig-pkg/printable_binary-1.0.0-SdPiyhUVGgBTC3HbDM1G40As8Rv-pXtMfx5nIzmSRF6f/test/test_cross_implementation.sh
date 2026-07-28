#!/usr/bin/env bash

# Test cross-implementation compatibility between Lua and JavaScript versions
# This test ensures that data encoded by one implementation can be decoded by the other

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Cross-Implementation Compatibility Test ==="
echo

# Create test data: all possible byte values 0-255
TEST_DATA="/tmp/pb_test_all_bytes.bin"
printf "Creating test file with all byte values (0-255)...\n"
for i in {0..255}; do
    printf "\\x$(printf '%02x' $i)"
done > "$TEST_DATA"

echo "Test data size: $(wc -c < "$TEST_DATA") bytes"
echo

# Test 1: JS encode -> Lua decode
echo "=== Test 1: JavaScript encode -> Lua decode ==="
JS_ENCODED="/tmp/pb_js_encoded.txt"
LUA_DECODED="/tmp/pb_lua_decoded.bin"

JS_CLI="$REPO_ROOT/bin/printable-binary-node.js"
LUA_CLI="$REPO_ROOT/printable-binary"

echo "Encoding with JavaScript..."
"$JS_CLI" "$TEST_DATA" > "$JS_ENCODED"
echo "JS encoded size: $(wc -c < "$JS_ENCODED") bytes"

echo "Decoding with Lua..."
"$LUA_CLI" -d "$JS_ENCODED" > "$LUA_DECODED" 2>/dev/null
echo "Lua decoded size: $(wc -c < "$LUA_DECODED") bytes"

echo "Comparing original and decoded..."
if cmp -s "$TEST_DATA" "$LUA_DECODED"; then
    echo "✓ Test 1 PASSED: JS encode -> Lua decode is compatible"
else
    echo "✗ Test 1 FAILED: Files differ!"
    echo "First difference:"
    cmp -l "$TEST_DATA" "$LUA_DECODED" | head -5
    exit 1
fi
echo

# Test 2: Lua encode -> JS decode
echo "=== Test 2: Lua encode -> JavaScript decode ==="
LUA_ENCODED="/tmp/pb_lua_encoded.txt"
JS_DECODED="/tmp/pb_js_decoded.bin"

echo "Encoding with Lua..."
"$LUA_CLI" "$TEST_DATA" > "$LUA_ENCODED" 2>/dev/null
echo "Lua encoded size: $(wc -c < "$LUA_ENCODED") bytes"

echo "Decoding with JavaScript..."
"$JS_CLI" -d "$LUA_ENCODED" > "$JS_DECODED"
echo "JS decoded size: $(wc -c < "$JS_DECODED") bytes"

echo "Comparing original and decoded..."
if cmp -s "$TEST_DATA" "$JS_DECODED"; then
    echo "✓ Test 2 PASSED: Lua encode -> JS decode is compatible"
else
    echo "✗ Test 2 FAILED: Files differ!"
    echo "First difference:"
    cmp -l "$TEST_DATA" "$JS_DECODED" | head -5
    exit 1
fi
echo

# Test 3: Round-trip JS
echo "=== Test 3: JavaScript round-trip ==="
JS_ROUNDTRIP="/tmp/pb_js_roundtrip.bin"
"$JS_CLI" -d "$JS_ENCODED" > "$JS_ROUNDTRIP"
if cmp -s "$TEST_DATA" "$JS_ROUNDTRIP"; then
    echo "✓ Test 3 PASSED: JS encode -> JS decode round-trip works"
else
    echo "✗ Test 3 FAILED: JS round-trip failed!"
    exit 1
fi
echo

# Test 4: Round-trip Lua
echo "=== Test 4: Lua round-trip ==="
LUA_ROUNDTRIP="/tmp/pb_lua_roundtrip.bin"
"$LUA_CLI" -d "$LUA_ENCODED" > "$LUA_ROUNDTRIP" 2>/dev/null
if cmp -s "$TEST_DATA" "$LUA_ROUNDTRIP"; then
    echo "✓ Test 4 PASSED: Lua encode -> Lua decode round-trip works"
else
    echo "✗ Test 4 FAILED: Lua round-trip failed!"
    exit 1
fi
echo

# Test 5: Formatted output parity (75x1)
echo "=== Test 5: Formatted output parity (75x1) ==="
LUA_FORMATTED="/tmp/pb_lua_formatted.txt"
JS_FORMATTED="/tmp/pb_js_formatted.txt"

"$LUA_CLI" -f=75x1 "$TEST_DATA" > "$LUA_FORMATTED" 2>/dev/null

"$JS_CLI" -f=75x1 "$TEST_DATA" > "$JS_FORMATTED"

if cmp -s "$LUA_FORMATTED" "$JS_FORMATTED"; then
    echo "✓ Test 5 PASSED: JS formatted output matches Lua"
else
    echo "✗ Test 5 FAILED: Formatted outputs differ!"
    diff -u "$LUA_FORMATTED" "$JS_FORMATTED" | head -20
    exit 1
fi
echo

# Cleanup
echo "Cleaning up temporary files..."
rm -f "$TEST_DATA" "$JS_ENCODED" "$LUA_DECODED" "$LUA_ENCODED" "$JS_DECODED" "$JS_ROUNDTRIP" "$LUA_ROUNDTRIP" "$LUA_FORMATTED" "$JS_FORMATTED"

echo
echo "=== ALL TESTS PASSED ==="
