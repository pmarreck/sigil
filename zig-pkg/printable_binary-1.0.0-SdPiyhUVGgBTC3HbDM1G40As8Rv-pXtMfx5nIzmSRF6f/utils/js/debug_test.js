import PrintableBinary from '../../js/printable_binary.js';

const encoder = new PrintableBinary();

// Test control characters 0-15
const input = new Uint8Array([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]);
console.log('Input bytes:', Array.from(input));

const encoded = encoder.encode(input);
console.log('Encoded string:', encoded);
console.log('Encoded string length:', encoded.length);
console.log('Encoded chars as hex:', Array.from(encoded).map(c => c.codePointAt(0).toString(16).padStart(4, '0')));

const decoded = encoder.decode(encoded);
console.log('Decoded bytes:', Array.from(decoded));

console.log('\nMismatch analysis:');
for (let i = 0; i < input.length; i++) {
  if (input[i] !== decoded[i]) {
    console.log('Position', i, ': expected', input[i], ', got', decoded[i] || 'undefined');
  }
}
