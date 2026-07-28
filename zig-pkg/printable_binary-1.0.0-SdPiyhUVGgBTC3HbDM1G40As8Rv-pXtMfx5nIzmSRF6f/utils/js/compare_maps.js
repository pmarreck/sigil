#!/usr/bin/env node

// Compare the Lua and JS encode maps for bytes 128-255
import PrintableBinary from '../../js/printable_binary.js';

const encoder = new PrintableBinary();

// Check bytes 128-255
for (let i = 128; i <= 255; i++) {
  const jsChar = encoder.encodeMap.get(i);
  const jsBytes = Buffer.from(jsChar, 'utf8');
  const jsHex = jsBytes.toString('hex');

  // Calculate what Lua should produce
  let luaHex;
  if (i < 192) {
    // Bytes 128-191 → U+0100-U+013F (Latin Extended-A)
    const unicodeVal = 0x0100 + (i - 128);
    const byte2 = unicodeVal - 0x0100 + 128;  // This is what Lua does
    luaHex = 'c4' + byte2.toString(16).padStart(2, '0');
  } else {
    // Bytes 192-255 → U+00C0-U+00FF
    const byte2 = i - 64;
    luaHex = 'c3' + byte2.toString(16).padStart(2, '0');
  }

  if (jsHex !== luaHex) {
    console.log(`Byte ${i} (0x${i.toString(16)}): JS=${jsHex}, Lua=${luaHex}`);
  }
}

console.log("Done checking");
