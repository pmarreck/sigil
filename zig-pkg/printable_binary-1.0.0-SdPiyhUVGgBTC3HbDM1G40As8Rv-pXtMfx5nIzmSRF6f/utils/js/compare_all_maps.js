#!/usr/bin/env node

// Compare ALL the Lua and JS encode maps
import PrintableBinary from '../../js/printable_binary.js';
import fs from 'fs';

const encoder = new PrintableBinary();

// Build the Lua map by parsing the Lua source
const luaSource = fs.readFileSync('./bin/printable-binary-luajit', 'utf8');

// Extract def_char calls and build Lua map
const luaMap = new Map();

// Pattern to match def_char(byte, "utf8_bytes") -- comment
const defCharPattern = /def_char\((\d+),\s*"([^"]+)"\)/g;
let match;

while ((match = defCharPattern.exec(luaSource)) !== null) {
  const byteVal = parseInt(match[1]);
  const utf8Str = match[2];

  // Convert Lua escape sequences to actual bytes
  const bytes = [];
  let i = 0;
  while (i < utf8Str.length) {
    if (utf8Str[i] === '\\' && i + 1 < utf8Str.length) {
      const next = utf8Str.substring(i + 1, i + 4);
      if (/^\d{3}$/.test(next)) {
        // Octal escape sequence
        bytes.push(parseInt(next, 8));
        i += 4;
      } else {
        // Unknown escape, just take the character
        bytes.push(utf8Str.charCodeAt(i + 1));
        i += 2;
      }
    } else {
      bytes.push(utf8Str.charCodeAt(i));
      i++;
    }
  }

  const hex = bytes.map(b => b.toString(16).padStart(2, '0')).join('');
  luaMap.set(byteVal, hex);
}

console.log(`Found ${luaMap.size} Lua mappings`);

// Also handle the ASCII range that's added in the loop
for (let i = 33; i <= 126; i++) {
  if (!luaMap.has(i)) {
    // Single ASCII character
    luaMap.set(i, i.toString(16).padStart(2, '0'));
  }
}

// Also handle extended bytes 128-255
for (let i = 128; i <= 255; i++) {
  if (!luaMap.has(i)) {
    if (i < 192) {
      const unicodeVal = 0x0100 + (i - 128);
      const byte2 = unicodeVal - 0x0100 + 128;
      luaMap.set(i, 'c4' + byte2.toString(16).padStart(2, '0'));
    } else {
      const byte2 = i - 64;
      luaMap.set(i, 'c3' + byte2.toString(16).padStart(2, '0'));
    }
  }
}

console.log(`Total Lua mappings: ${luaMap.size}`);

// Compare all 256 bytes
let differences = 0;
for (let i = 0; i <= 255; i++) {
  const jsChar = encoder.encodeMap.get(i);
  const jsBytes = jsChar ? Buffer.from(jsChar, 'utf8') : null;
  const jsHex = jsBytes ? jsBytes.toString('hex') : 'MISSING';

  const luaHex = luaMap.get(i) || 'MISSING';

  if (jsHex !== luaHex) {
    console.log(`Byte ${i} (0x${i.toString(16).padStart(2, '0')}): JS=${jsHex}, Lua=${luaHex}`);
    differences++;
  }
}

if (differences === 0) {
  console.log("No differences found!");
} else {
  console.log(`\nTotal differences: ${differences}`);
}
