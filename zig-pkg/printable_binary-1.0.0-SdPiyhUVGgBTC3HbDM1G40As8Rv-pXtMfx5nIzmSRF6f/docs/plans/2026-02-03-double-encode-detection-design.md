# Double-Encoding Detection Design

## Problem

Users can accidentally pipe printable-binary output back through the encoder, producing unnecessarily bloated output that's hard to debug. We want to detect and warn about this at encode time.

## Goals

1. Detect when input appears to be already-encoded PB output
2. Warn but don't block (non-breaking for scripts)
3. Provide opt-out for legitimate use cases
4. Minimize false positives on legitimate UTF-8 text

## Non-Goals

- Auto-unwrap multiple encoding layers (risky, masks bugs)
- Decode-time detection (less critical, can add later)
- 100% accuracy (impossible due to epistemological uncertainty)

## Design

### Detection Heuristic

Scan input for "high-confidence" PB glyphs—characters that are:
- Used by PB to encode non-printable bytes
- Uncommon in legitimate text

**High-confidence glyph sets:**
- Control character mappings (0x00-0x1F): `·`, `¯`, `«`, `»`, `ϟ`, `¿`, `¡`, etc.
- High-byte mappings (0x80-0xFF): `ā`, `Ā`, `ă`, `Ă`, ... `Ż`
- Replaced ASCII mappings: `␣`, `ǃ`, `ˮ`, `♯`, etc.

**Threshold:** If >5% of input characters are high-confidence PB glyphs, warn.

### Behavior

```
$ echo -n -e '\x00' | ./bin/printable-binary | ./bin/printable-binary
Warning: Input appears to already be printable-binary encoded (8% detection).
         Use --no-double-encode-check to suppress this warning.
ĺȉ
```

- Warning goes to stderr
- Encoding proceeds normally (exit 0)
- Warning includes detection percentage for debugging

### CLI Option

`--no-double-encode-check` - Skip the detection entirely.

### FFI/Library Interface

For programmatic use:
- Detection function returns `{is_likely_encoded: bool, confidence: float}`
- Encoding function accepts `skip_double_encode_check` parameter
- Warning can be captured or suppressed

## Edge Cases

### Identity/Fixed Points
Pure ASCII input (e.g., "aaaaaa") contains no PB glyphs → no warning, no problem. Encoding is idempotent for such input anyway.

### Legitimate Glyph Usage
Text that legitimately contains some PB glyphs (e.g., documentation about PB) may trigger false positives if above threshold. User can:
1. Accept the warning (it's non-blocking)
2. Use `--no-double-encode-check`

### Mixed Content
Binary with embedded ASCII that happens to encode to some high-byte glyphs is unlikely to hit 5% threshold unless truly already-encoded.

## Implementation Plan

1. Create lookup table of high-confidence glyphs
2. Add detection function that scans input and returns confidence
3. Integrate into encode path with warning output
4. Add `--no-double-encode-check` CLI flag
5. Expose detection state for FFI

## Testing Strategy

- Test detection on known double-encoded input (should warn)
- Test detection on pure ASCII (should not warn)
- Test detection on legitimate UTF-8 with few PB glyphs (should not warn)
- Test threshold boundary (4.9% vs 5.1%)
- Test `--no-double-encode-check` suppresses warning
- Test warning goes to stderr, output to stdout
