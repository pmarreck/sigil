#!/bin/bash
# Script to diagnose encoding/decoding issues

# Create a file with all 256 possible byte values
TEST_FILE=$(mktemp)
ENCODED_FILE=$(mktemp)
DECODED_FILE=$(mktemp)

echo "Creating test file with all 256 byte values..."
for i in {0..255}; do
    printf "\\$(printf '%03o' $i)" >> "$TEST_FILE"
done

echo "Original file size: $(wc -c < "$TEST_FILE") bytes"
echo "First 32 bytes of original:"
hexdump -C "$TEST_FILE" | head -n 2

echo "Encoding..."
./bin/printable-binary "$TEST_FILE" > "$ENCODED_FILE"
echo "Encoded file size: $(wc -c < "$ENCODED_FILE") bytes"
echo "First 32 bytes of encoded:"
hexdump -C "$ENCODED_FILE" | head -n 2

echo "Decoding..."
./bin/printable-binary -d "$ENCODED_FILE" > "$DECODED_FILE"
echo "Decoded file size: $(wc -c < "$DECODED_FILE") bytes"
echo "First 32 bytes of decoded:"
hexdump -C "$DECODED_FILE" | head -n 4

echo "Finding differences..."
cmp -l "$TEST_FILE" "$DECODED_FILE" | head -n 20

echo "Cleanup..."
rm "$TEST_FILE" "$ENCODED_FILE" "$DECODED_FILE"
