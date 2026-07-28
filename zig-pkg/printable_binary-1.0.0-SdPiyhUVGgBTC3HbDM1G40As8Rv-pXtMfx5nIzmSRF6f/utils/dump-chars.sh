#!/bin/bash
# Dump characters script for PrintableBinary
# Displays the character mappings for various byte values

# Set up temp files
TEMPFILE=$(mktemp)
RESULT=$(mktemp)

# Cleanup function
cleanup() {
  rm -f "$TEMPFILE" "$RESULT"
}
trap cleanup EXIT

# Create test file with single bytes
echo "Testing character mappings:"

# Test specific important character ranges
for range in "0-31" "32-64" "65-96" "97-127" "128-159" "160-191" "192-223" "224-255"; do
  start=$(echo $range | cut -d'-' -f1)
  end=$(echo $range | cut -d'-' -f2)
  
  echo "== Testing bytes $range (decimal) =="
  
  for ((i=start; i<=end; i++)); do
    # Create file with single byte
    printf "\\$(printf '%03o' $i)" > "$TEMPFILE"
    
    # Encode it
    ENCODED=$(./bin/printable-binary "$TEMPFILE" 2>/dev/null)
    
    # Show the mapping
    printf "Byte %3d (0x%02X) -> %s\n" "$i" "$i" "$ENCODED"
  done
  echo ""
done

echo "All character mappings displayed successfully"
