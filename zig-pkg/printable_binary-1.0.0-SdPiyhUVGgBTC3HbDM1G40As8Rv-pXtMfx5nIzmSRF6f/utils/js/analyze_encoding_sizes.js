#!/usr/bin/env -S deno run

/**
 * Analyze the encoding sizes to find the most expensive mappings
 */

import PrintableBinary from '../../js/printable_binary.js';

const encoder = new PrintableBinary();

// Analyze all byte encodings
const analysis = [];
let totalBytes = 0;
let totalEncodedBytes = 0;

for (let byte = 0; byte < 256; byte++) {
  const input = new Uint8Array([byte]);
  const encoded = encoder.encode(input);

  // Count UTF-8 bytes (not JavaScript string length, which counts UTF-16 code units)
  const utf8Bytes = new TextEncoder().encode(encoded).length;

  totalBytes++;
  totalEncodedBytes += utf8Bytes;

  analysis.push({
    byte,
    char: byte >= 32 && byte < 127 ? String.fromCharCode(byte) : '',
    encoded,
    utf8Bytes,
    expansion: utf8Bytes,
    hex: byte.toString(16).padStart(2, '0').toUpperCase()
  });
}

// Sort by expansion (worst first)
analysis.sort((a, b) => b.utf8Bytes - a.utf8Bytes);

console.log('PrintableBinary Encoding Size Analysis');
console.log('='.repeat(80));
console.log(`\nAverage expansion: ${(totalEncodedBytes / totalBytes).toFixed(2)}x per byte`);
console.log(`Total: 256 bytes → ${totalEncodedBytes} bytes\n`);

// Show distribution
const distribution = {};
analysis.forEach(item => {
  distribution[item.utf8Bytes] = (distribution[item.utf8Bytes] || 0) + 1;
});

console.log('Distribution:');
Object.keys(distribution).sort().forEach(size => {
  const count = distribution[size];
  const percent = ((count / 256) * 100).toFixed(1);
  console.log(`  ${size}-byte encodings: ${count.toString().padStart(3)} (${percent}%)`);
});

console.log('\n' + '='.repeat(80));
console.log('MOST EXPENSIVE ENCODINGS (Top 20):');
console.log('='.repeat(80));
console.log('Byte | Hex  | ASCII | Encoded | UTF-8 Bytes | Unicode');
console.log('-'.repeat(80));

analysis.slice(0, 20).forEach(item => {
  const asciiCol = item.char ? `  ${item.char}  ` : ' -   ';
  const encodedDisplay = item.encoded.padEnd(3);
  const codePoints = [...item.encoded].map(c =>
    'U+' + c.codePointAt(0).toString(16).toUpperCase().padStart(4, '0')
  ).join(' ');

  console.log(
    `${item.byte.toString().padStart(4)} | 0x${item.hex} | ${asciiCol} | ${encodedDisplay} | ${item.utf8Bytes.toString().padStart(11)} | ${codePoints}`
  );
});

console.log('\n' + '='.repeat(80));
console.log('MOST EFFICIENT ENCODINGS (Bottom 20):');
console.log('='.repeat(80));
console.log('Byte | Hex  | ASCII | Encoded | UTF-8 Bytes | Unicode');
console.log('-'.repeat(80));

analysis.slice(-20).reverse().forEach(item => {
  const asciiCol = item.char ? `  ${item.char}  ` : ' -   ';
  const encodedDisplay = item.encoded.padEnd(3);
  const codePoints = [...item.encoded].map(c =>
    'U+' + c.codePointAt(0).toString(16).toUpperCase().padStart(4, '0')
  ).join(' ');

  console.log(
    `${item.byte.toString().padStart(4)} | 0x${item.hex} | ${asciiCol} | ${encodedDisplay} | ${item.utf8Bytes.toString().padStart(11)} | ${codePoints}`
  );
});

// Show byte ranges
console.log('\n' + '='.repeat(80));
console.log('ANALYSIS BY BYTE RANGE:');
console.log('='.repeat(80));

const ranges = [
  { name: 'Control chars (0-31)', start: 0, end: 31 },
  { name: 'Printable ASCII (32-126)', start: 32, end: 126 },
  { name: 'DEL (127)', start: 127, end: 127 },
  { name: 'Extended (128-191)', start: 128, end: 191 },
  { name: 'Extended (192-255)', start: 192, end: 255 }
];

ranges.forEach(range => {
  const items = analysis.filter(a => a.byte >= range.start && a.byte <= range.end);
  const avg = items.reduce((sum, a) => sum + a.utf8Bytes, 0) / items.length;
  const min = Math.min(...items.map(a => a.utf8Bytes));
  const max = Math.max(...items.map(a => a.utf8Bytes));

  console.log(`\n${range.name}:`);
  console.log(`  Count: ${items.length}`);
  console.log(`  Average: ${avg.toFixed(2)} bytes`);
  console.log(`  Range: ${min}-${max} bytes`);
});

// Check for any 4+ byte encodings
console.log('\n' + '='.repeat(80));
console.log('ENCODINGS ≥ 4 BYTES:');
console.log('='.repeat(80));

const large = analysis.filter(a => a.utf8Bytes >= 4);
if (large.length > 0) {
  large.forEach(item => {
    const asciiCol = item.char ? `  ${item.char}  ` : ' -   ';
    const rawBytes = new TextEncoder().encode(item.encoded);
    const hexBytes = Array.from(rawBytes).map(b => b.toString(16).padStart(2, '0').toUpperCase()).join(' ');
    const codePoints = [...item.encoded].map(c =>
      'U+' + c.codePointAt(0).toString(16).toUpperCase().padStart(4, '0')
    ).join(' ');

    console.log(`Byte ${item.byte.toString().padStart(3)} (0x${item.hex}): ${item.encoded} = ${item.utf8Bytes} bytes`);
    console.log(`  UTF-8 hex: ${hexBytes}`);
    console.log(`  Unicode: ${codePoints}`);
  });
} else {
  console.log('No encodings use 4 or more bytes!');
}
