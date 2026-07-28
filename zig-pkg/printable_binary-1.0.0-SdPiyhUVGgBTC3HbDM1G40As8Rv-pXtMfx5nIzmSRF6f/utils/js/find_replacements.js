// Find suitable replacement codepoints for the 16 conflicting special chars
// We want 2-byte UTF-8 sequences (U+0080-U+07FF) that are:
// 1. Not in Latin-1 Supplement (U+0080-U+00FF) since we need that for bytes 128-255
// 2. Visually distinct and memorable if possible

const conflicts = [
  {byte: 1, current: 0x00AF, char: '¯', name: 'macron'},
  {byte: 2, current: 0x00AB, char: '«', name: 'left guillemet'},
  {byte: 3, current: 0x00BB, char: '»', name: 'right guillemet'},
  {byte: 5, current: 0x00BF, char: '¿', name: 'inverted question'},
  {byte: 6, current: 0x00A1, char: '¡', name: 'inverted exclamation'},
  {byte: 7, current: 0x00AA, char: 'ª', name: 'feminine ordinal'},
  {byte: 12, current: 0x00A7, char: '§', name: 'section sign'},
  {byte: 17, current: 0x00B9, char: '¹', name: 'superscript 1'},
  {byte: 18, current: 0x00B2, char: '²', name: 'superscript 2'},
  {byte: 19, current: 0x00BA, char: 'º', name: 'masculine ordinal'},
  {byte: 20, current: 0x00B3, char: '³', name: 'superscript 3'},
  {byte: 21, current: 0x00B5, char: 'µ', name: 'micro sign'},
  {byte: 23, current: 0x00AC, char: '¬', name: 'not sign'},
  {byte: 24, current: 0x00A9, char: '©', name: 'copyright'},
  {byte: 25, current: 0x00A6, char: '¦', name: 'broken bar'},
  {byte: 31, current: 0x00B6, char: '¶', name: 'pilcrow'},
];

// Good replacement ranges (all 2-byte UTF-8):
// U+0100-U+017F: Latin Extended-A
// U+0180-U+024F: Latin Extended-B
// U+0250-U+02AF: IPA Extensions (already using some)
// U+02B0-U+02FF: Spacing Modifier Letters (already using some)
// U+0300-U+036F: Combining Diacritical Marks (skip - combining chars)
// U+0370-U+03FF: Greek and Coptic (already using 0x03DF, 0x039E)

console.log('Current conflicts with Latin-1 Supplement:');
conflicts.forEach(c => {
  console.log(`  Byte ${c.byte.toString().padStart(2)}: ${c.char} (U+${c.current.toString(16).toUpperCase().padStart(4, '0')}) - ${c.name}`);
});

console.log('\nThese need to be remapped to codepoints >= U+0100');
