import PrintableBinary from '../../js/printable_binary.js';

const encoder = new PrintableBinary();

console.log('Checking byte 1 mapping:');
const byte1Encoded = encoder.encodeMap.get(1);
if (byte1Encoded) {
  console.log('  encodeMap.get(1):', byte1Encoded, '-> codepoint:', byte1Encoded.codePointAt(0).toString(16));
}

console.log('\nChecking decode map for U+00AF:');
const barChar = "\u00AF";
console.log('  Character:', barChar);
console.log('  decodeMap.get(barChar):', encoder.decodeMap.get(barChar));

console.log('\nChecking byte 175 mapping:');
const byte175Encoded = encoder.encodeMap.get(175);
if (byte175Encoded) {
  console.log('  encodeMap.get(175):', byte175Encoded, '-> codepoint:', byte175Encoded.codePointAt(0).toString(16));
}

console.log('\nTotal encodeMap size:', encoder.encodeMap.size);
console.log('Total decodeMap size:', encoder.decodeMap.size);
