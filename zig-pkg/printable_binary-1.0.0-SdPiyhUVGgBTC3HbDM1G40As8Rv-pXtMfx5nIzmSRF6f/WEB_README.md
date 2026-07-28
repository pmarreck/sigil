# PrintableBinary Web Implementation

This directory contains a web-based implementation of the PrintableBinary encoder, allowing you to encode binary files directly in your browser.

## Files

- **`printable_binary.js`** - JavaScript implementation of the PrintableBinary algorithm
  - Works in browsers, Deno, and Node.js
  - Fully compatible with the Lua and C implementations
  - Handles files up to 2GB

- **`index.html`** - Modern web interface
  - Drag-and-drop file upload
  - Progress indicator for large files
  - Copy to clipboard functionality
  - Download encoded output
  - Responsive design

- **`test/js/test_printable_binary.js`** - Comprehensive test suite
  - 25 tests covering all edge cases
  - Can be run with Deno or Node.js

- **`test/js/test_cross_compat.js`** - Cross-implementation compatibility test
  - Verifies that JavaScript and Lua implementations produce identical output

## Usage

### Web Interface

1. **Serve the files with a local web server:**

   ```bash
   # Using Python 3
   python3 -m http.server 8000

   # Using Deno
   deno run --allow-net --allow-read https://deno.land/std/http/file_server.ts

   # Using npx (Node.js)
   npx serve
   ```

2. **Open in your browser:**
   ```
   http://localhost:8000
   ```

3. **Drop a file or click to browse** - The encoded output will appear in the textarea

4. **Copy or download** the encoded result

### JavaScript API

```javascript
import PrintableBinary from './printable_binary.js';

const encoder = new PrintableBinary();

// Encode binary data
const binaryData = new Uint8Array([72, 101, 108, 108, 111]);
const encoded = encoder.encode(binaryData);
console.log(encoded); // Output: Hello

// Decode back to binary
const decoded = encoder.decode(encoded);
console.log(decoded); // Uint8Array([72, 101, 108, 108, 111])

// Convenience methods for strings
const encoded2 = encoder.encodeString("Hello!");
const decoded2 = encoder.decodeToString(encoded2);
```

### Testing

Run the test suite with Deno:

```bash
deno run --allow-read --allow-env test/js/test_printable_binary.js
```

Test cross-compatibility with the Lua implementation:

```bash
deno run --allow-read --allow-run test/js/test_cross_compat.js
```

## Features

### JavaScript Implementation

- ✅ Full compatibility with Lua and C implementations
- ✅ Handles all 256 byte values (0-255)
- ✅ Proper UTF-8 encoding/decoding
- ✅ Whitespace and formatting-aware decoding
- ✅ Works with ArrayBuffer and Uint8Array
- ✅ Browser, Deno, and Node.js compatible
- ✅ ES Module and CommonJS support

### Web Interface

- ✅ Modern, responsive design
- ✅ Drag-and-drop file upload
- ✅ Handles files up to 2GB
- ✅ Chunked processing for large files
- ✅ Progress indicator
- ✅ Copy to clipboard
- ✅ Download encoded output
- ✅ Error handling and validation

## Browser Compatibility

The web interface works in all modern browsers:

- ✅ Chrome/Edge 90+
- ✅ Firefox 88+
- ✅ Safari 14+
- ✅ Opera 76+

Requirements:
- ES6 Modules support
- File API
- Clipboard API (for copy functionality)

## Performance

The JavaScript implementation is optimized for both small and large files:

- **Small files (<10MB)**: Processed in a single pass
- **Large files (>10MB)**: Processed in 1MB chunks to prevent memory issues
- **Performance**: ~10,000 bytes encoded in ~1.6ms, decoded in ~3.3ms (Deno)

## Testing

The implementation includes comprehensive tests:

1. **Basic encoding/decoding** - Round-trip tests
2. **Control characters** - All control characters (0-31)
3. **Special ASCII** - Shell-safe special characters
4. **Extended bytes** - All bytes 128-255
5. **Edge cases** - Empty input, single byte, NUL bytes
6. **Whitespace handling** - Decoding with spaces/newlines (and `spaces` mode preserving literal spaces)
7. **Known mappings** - Verification of specific character mappings
8. **Binary patterns** - Repeating and sequential patterns
9. **Large data** - Performance test with 10,000 bytes
10. **Error handling** - Invalid input handling
11. **Cross-compatibility** - Verification against Lua implementation

All tests pass successfully!

## Architecture

The implementation follows the same algorithm as the Lua and C versions:

1. **Encoding**: Each byte (0-255) maps to a specific UTF-8 character
2. **Decoding**: UTF-8 characters are matched (longest first) and converted back to bytes

The character mappings are identical across all implementations:
- Control characters (0-31) → Visual symbols (∅, ¯, «, », etc.)
- Special ASCII (space, quotes, backslash, etc.) → Safe Unicode alternatives
- Regular ASCII (33-126) → Mostly unchanged
- Extended bytes (128-255) → Read from `character_map.txt`, grouped alphabetically so neighbouring bytes share related glyphs

## License

This implementation is part of the PrintableBinary project and follows the same MIT license.
