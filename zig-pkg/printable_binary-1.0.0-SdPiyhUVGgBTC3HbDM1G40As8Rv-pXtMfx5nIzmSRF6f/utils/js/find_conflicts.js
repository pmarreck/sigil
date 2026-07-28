import PrintableBinary from '../../js/printable_binary.js';

// Build maps without the Latin-1 extension to see the special chars
class TestEncoder {
  constructor() {
    this.encodeMap = new Map();
    this.defChar = (byteVal, utf8Str) => {
      this.encodeMap.set(byteVal, utf8Str);
    };
    
    // Control Characters (0-31) - copy from buildMaps
    this.defChar(0, "\u2205");   this.defChar(1, "\u00AF");
    this.defChar(2, "\u00AB");   this.defChar(3, "\u00BB");
    this.defChar(4, "\u03DF");   this.defChar(5, "\u00BF");
    this.defChar(6, "\u00A1");   this.defChar(7, "\u00AA");
    this.defChar(8, "\u232B");   this.defChar(9, "\u21E5");
    this.defChar(10, "\u21E9");  this.defChar(11, "\u21A7");
    this.defChar(12, "\u00A7");  this.defChar(13, "\u23CE");
    this.defChar(14, "\u022F");  this.defChar(15, "\u0298");
    this.defChar(16, "\u0194");  this.defChar(17, "\u00B9");
    this.defChar(18, "\u00B2");  this.defChar(19, "\u00BA");
    this.defChar(20, "\u00B3");  this.defChar(21, "\u00B5");
    this.defChar(22, "\u0268");  this.defChar(23, "\u00AC");
    this.defChar(24, "\u00A9");  this.defChar(25, "\u00A6");
    this.defChar(26, "\u01B5");  this.defChar(27, "\u238B");
    this.defChar(28, "\u039E");  this.defChar(29, "\u01C1");
    this.defChar(30, "\u01C0");  this.defChar(31, "\u00B6");
    
    // Special ASCII characters
    this.defChar(32, "\u2423");  this.defChar(33, "\uFE57");
    this.defChar(34, "\u02EE");  this.defChar(35, "\u266F");
    this.defChar(36, "\uFE69");  this.defChar(37, "\uFE6A");
    this.defChar(38, "\uFE60");  this.defChar(39, "\u02BC");
    this.defChar(40, "\u2768");  this.defChar(41, "\u2769");
    this.defChar(42, "\uFE61");  this.defChar(43, "\uFE62");
    this.defChar(45, "\uFE63");  this.defChar(47, "\u2044");
    this.defChar(58, "\uFE55");  this.defChar(59, "\uFE54");
    this.defChar(61, "\uFE66");  this.defChar(63, "\uFE56");
    this.defChar(64, "\uFE6B");  this.defChar(91, "\u27E6");
    this.defChar(92, "\u29F9");  this.defChar(93, "\u27E7");
    this.defChar(96, "\u02CB");  this.defChar(123, "\u2774");
    this.defChar(124, "\u2223"); this.defChar(125, "\u2775");
    this.defChar(126, "\u02DC"); this.defChar(127, "\u2326");
  }
}

const test = new TestEncoder();

console.log('Special characters in Latin-1 Supplement range (U+0080-U+00FF):');
for (let byte = 0; byte < 128; byte++) {
  const encoded = test.encodeMap.get(byte);
  if (encoded) {
    const codepoint = encoded.codePointAt(0);
    if (codepoint >= 0x80 && codepoint <= 0xFF) {
      console.log('  Byte', byte, '-> U+' + codepoint.toString(16).toUpperCase().padStart(4, '0'), '(' + encoded + ') conflicts with Latin-1 byte', codepoint);
    }
  }
}
