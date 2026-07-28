// Find which Latin-1 Supplement codepoints are already used by special chars
const usedCodepoints = new Set();

const specialMappings = [
  [0, 0x2205], [1, 0x00AF], [2, 0x00AB], [3, 0x00BB],
  [4, 0x03DF], [5, 0x00BF], [6, 0x00A1], [7, 0x00AA],
  [8, 0x232B], [9, 0x21E5], [10, 0x21E9], [11, 0x21A7],
  [12, 0x00A7], [13, 0x23CE], [14, 0x022F], [15, 0x0298],
  [16, 0x0194], [17, 0x00B9], [18, 0x00B2], [19, 0x00BA],
  [20, 0x00B3], [21, 0x00B5], [22, 0x0268], [23, 0x00AC],
  [24, 0x00A9], [25, 0x00A6], [26, 0x01B5], [27, 0x238B],
  [28, 0x039E], [29, 0x01C1], [30, 0x01C0], [31, 0x00B6],
];

specialMappings.forEach(([byte, codepoint]) => {
  if (codepoint >= 0x80 && codepoint <= 0xFF) {
    usedCodepoints.add(codepoint);
  }
});

console.log('Latin-1 Supplement codepoints (0x80-0xFF) already used by special chars:');
const usedArray = Array.from(usedCodepoints).sort((a, b) => a - b);
usedArray.forEach(cp => {
  console.log('  U+' + cp.toString(16).toUpperCase().padStart(4, '0'), '(' + String.fromCharCode(cp) + ')');
});

console.log('\nAvailable Latin-1 Supplement codepoints:');
const available = [];
for (let i = 0x80; i <= 0xFF; i++) {
  if (!usedCodepoints.has(i)) {
    available.push(i);
  }
}
console.log('  Count:', available.length);
console.log('  Need: 128 (for bytes 128-255)');
console.log('  Shortfall:', 128 - available.length);
