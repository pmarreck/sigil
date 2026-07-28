/**
 * PrintableBinary JavaScript Implementation
 * Encodes arbitrary binary data into human-readable UTF-8 strings and decodes them back
 *
 * This is a browser and Deno compatible implementation of the PrintableBinary algorithm.
 * It can be used as an ES module or included directly in HTML.
 */

const isNodeEnv = typeof process !== 'undefined' && !!process.versions?.node;
const isDenoEnv = typeof Deno !== 'undefined' && typeof Deno.readTextFileSync === 'function';

// A TextEncoder is stateless; share one instead of allocating per character.
const sharedTextEncoder = new TextEncoder();

const CONTROL_NAMES = [
  'NUL','SOH','STX','ETX','EOT','ENQ','ACK','BEL',
  'BS','TAB','LF','VT','FF','CR','SO','SI',
  'DLE','DC1','DC2','DC3','DC4','NAK','SYN','ETB',
  'CAN','EM','SUB','ESC','FS','GS','RS','US'
];

function asciiName(byte) {
  if (byte <= 0x1F) {
    return CONTROL_NAMES[byte];
  }
  if (byte === 0x20) {
    return 'SPACE';
  }
  if (byte === 0x7F) {
    return 'DEL';
  }
  if (byte >= 0x21 && byte <= 0x7E) {
    const ch = String.fromCharCode(byte);
    const sanitized = ch === '\\' || ch === "'" ? '\\' + ch : ch;
    return `'${sanitized}'`;
  }
  return `0x${byte.toString(16).toUpperCase().padStart(2, '0')}`;
}

function parseCharacterMap(text) {
  if (typeof text !== 'string') {
    throw new Error('Character map must be provided as text');
  }
  // Filter blank and full-line `#` comments; glyph = first whitespace-delimited
  // token (so `<glyph> # comment` trailing comments are ignored). `#` is never
  // a glyph (byte 0x23 -> music sharp), so this is unambiguous.
  const glyphs = [];
  for (let line of text.split('\n')) {
    if (line.endsWith('\r')) line = line.slice(0, -1);
    if (line.length === 0 || line.startsWith('##')) continue; // `##` = comment
    glyphs.push(line.split(/[ \t]/)[0]);
  }
  if (glyphs.length !== 256) {
    throw new Error(`Character map requires 256 glyph lines, found ${glyphs.length}`);
  }
  return glyphs;
}

function warnSpacesAfterNewline(str) {
  if (/[\n\r] {2,}/.test(str)) {
    console.warn('Warning: spaces after newline are treated as data in --spaces mode');
  }
}

let defaultCharacterMap = null;
if (isNodeEnv) {
  const { readFileSync } = await import('node:fs');
  const { fileURLToPath } = await import('node:url');
  const { dirname, join } = await import('node:path');

  const moduleDir = dirname(fileURLToPath(import.meta.url));
  const candidates = [];
  if (process.env.PRINTABLE_BINARY_MAP) {
    candidates.push(process.env.PRINTABLE_BINARY_MAP);
  }
  candidates.push(join(moduleDir, 'character_map.txt'));
  candidates.push(join(moduleDir, '..', 'character_map.txt'));
  candidates.push(join(moduleDir, '..', 'bin', 'character_map.txt'));
  candidates.push(join(moduleDir, '..', 'docs', 'character_map.txt'));
  candidates.push(join(process.cwd(), 'character_map.txt'));

  let lastError;
  for (const candidate of candidates) {
    try {
      const text = readFileSync(candidate, 'utf8');
      defaultCharacterMap = parseCharacterMap(text);
      break;
    } catch (err) {
      lastError = err;
    }
  }

  if (!defaultCharacterMap) {
    throw new Error(`PrintableBinary: Unable to load character_map.txt. Set PRINTABLE_BINARY_MAP or place the map alongside printable_binary.js. Last error: ${lastError?.message ?? 'none'}`);
  }
} else if (isDenoEnv) {
  const moduleDir = new URL('./', import.meta.url);
  const candidates = [];
  if (Deno.env?.get('PRINTABLE_BINARY_MAP')) {
    candidates.push(Deno.env.get('PRINTABLE_BINARY_MAP'));
  }
  candidates.push(new URL('character_map.txt', moduleDir).pathname);
  candidates.push(new URL('../character_map.txt', moduleDir).pathname);
  candidates.push(new URL('../bin/character_map.txt', moduleDir).pathname);
  candidates.push(new URL('../docs/character_map.txt', moduleDir).pathname);
  candidates.push(`${Deno.cwd()}/character_map.txt`);

  let lastError;
  for (const candidate of candidates) {
    try {
      const text = Deno.readTextFileSync(candidate);
      defaultCharacterMap = parseCharacterMap(text);
      break;
    } catch (err) {
      lastError = err;
    }
  }

  if (!defaultCharacterMap) {
    throw new Error(`PrintableBinary: Unable to load character_map.txt. Set PRINTABLE_BINARY_MAP or place the map alongside printable_binary.js. Last error: ${lastError?.message ?? 'none'}`);
  }
}

class PrintableBinary {
  constructor(options = {}) {
    this.encodeMap = new Map(); // number (0-255) -> string (UTF-8 character)
    this.decodeMap = new Map(); // string (UTF-8 character) -> number (0-255)

    const mapLines = options.map || defaultCharacterMap;
    if (!mapLines) {
      throw new Error('PrintableBinary: character map not provided. Supply { map: [...] } when constructing in non-Node environments.');
    }

    this.buildMaps(mapLines);
  }

  static parseMap(text) {
    return parseCharacterMap(text);
  }

  buildMaps(mapLines) {
    if (!Array.isArray(mapLines) || mapLines.length < 256) {
      throw new Error('PrintableBinary: character map must be an array of 256 entries');
    }

    for (let i = 0; i < 256; i++) {
      const char = mapLines[i];
      if (typeof char !== 'string' || char.length === 0) {
        throw new Error(`PrintableBinary: invalid character mapping at index ${i}`);
      }
      this.encodeMap.set(i, char);
      this.decodeMap.set(char, i);
    }
  }

  /**
   * Encode binary data (Uint8Array or ArrayBuffer) to printable UTF-8 string
   * @param {Uint8Array|ArrayBuffer} binaryData - The binary data to encode
   * @param {Object} options - Optional encoding options
   * @param {boolean} options.spaces - Preserve literal spaces (don't encode to ␣)
   * @param {boolean} options.tabs - Preserve literal tabs (don't encode to ⇥)
   * @param {boolean} options.crlf - Preserve literal CR/LF (don't encode to ⏎/↧)
   * @param {string} options.preserve - String of specific characters to preserve
   * @param {string} options.format - Format specification (e.g., "8x10" for 8 chars per group, 10 groups per line)
   * @returns {string} The encoded printable string
   */
  encode(binaryData, options = {}) {
    // Convert ArrayBuffer to Uint8Array if needed
    if (binaryData instanceof ArrayBuffer) {
      binaryData = new Uint8Array(binaryData);
    }

    if (!(binaryData instanceof Uint8Array)) {
      throw new Error("Input must be a Uint8Array or ArrayBuffer");
    }

    // Optimization: Build string in chunks to avoid massive array join
    // Join operations on million-element arrays are slow
    const CHUNK_SIZE = 65536; // 64KB chunks - balance between memory and performance
    const chunks = [];
    let currentChunk = [];

    const spacesMode = options.spaces === true;
    const tabsMode = options.tabs === true;
    const crlfMode = options.crlf === true;
    const preserveChars = options.preserve || '';

    // Build a Set of byte values to preserve
    const preserveSet = new Set();
    for (let i = 0; i < preserveChars.length; i++) {
      preserveSet.add(preserveChars.charCodeAt(i));
    }

    for (let i = 0; i < binaryData.length; i++) {
      const byte = binaryData[i];
      let encoded;

      // Check preservation modes
      if (spacesMode && byte === 0x20) {
        encoded = ' ';
      } else if (tabsMode && byte === 0x09) {
        encoded = '\t';
      } else if (crlfMode && (byte === 0x0A || byte === 0x0D)) {
        encoded = String.fromCharCode(byte);
      } else if (preserveSet.has(byte)) {
        encoded = String.fromCharCode(byte);
      } else {
        encoded = this.encodeMap.get(byte);
      }

      if (encoded !== undefined) {
        currentChunk.push(encoded);

        // Periodically join the chunk and reset
        if (currentChunk.length >= CHUNK_SIZE) {
          chunks.push(currentChunk.join(''));
          currentChunk = [];
        }
      }
    }

    // Don't forget the last chunk
    if (currentChunk.length > 0) {
      chunks.push(currentChunk.join(''));
    }

    let output = chunks.join('');

    // Apply formatting if requested
    if (options.format) {
      output = this.formatOutput(output, options.format, options);
    }

    return output;
  }

  getMappings() {
    const entries = [];
    for (let i = 0; i < 256; i++) {
      const mapping = this.encodeMap.get(i) ?? '';
      entries.push({
        byte: i,
        hex: `0x${i.toString(16).toUpperCase().padStart(2, '0')}`,
        dec: i,
        ascii: asciiName(i),
        mapping
      });
    }
    return entries;
  }

  /**
   * Format encoded output with grouping and line breaks
   * @param {string} encoded - The encoded string
   * @param {string} formatSpec - Format specification like "8x10" (8 chars per group, 10 groups per line)
   * @returns {string} Formatted output
   */
  formatOutput(encoded, formatSpec, options = {}) {
    // Parse format specification (e.g., "8x10" or "75x1")
    const match = formatSpec.match(/^(\d+)x(\d+)$/);
    if (!match) {
      throw new Error(`Invalid format specification: ${formatSpec}. Expected format like "8x10"`);
    }

    const charsPerGroup = parseInt(match[1], 10);
    const groupsPerLine = parseInt(match[2], 10);
    const glyphs = Array.from(encoded);
    const groupSeparator = options.spaces ? '\t' : ' ';

    if (groupsPerLine === 1) {
      const result = [];
      for (let index = 0; index < glyphs.length; index += charsPerGroup) {
        result.push(glyphs.slice(index, index + charsPerGroup).join(''));
      }
      return result.join('\n');
    }

    const result = [];
    let charCount = 0;
    let groupCount = 0;

    for (let i = 0; i < glyphs.length; i++) {
      result.push(glyphs[i]);
      charCount++;

      // Check if we've completed a group
      if (charCount === charsPerGroup) {
        groupCount++;
        charCount = 0;

        if (i < glyphs.length - 1) {
          if (groupCount === groupsPerLine) {
            result.push('\n');
            groupCount = 0;
          } else {
            result.push(groupSeparator);
          }
        } else if (groupCount === groupsPerLine) {
          groupCount = 0;
        }
      }
    }

    return result.join('');
  }

  /**
   * Decode printable UTF-8 string back to binary data
   * @param {string} printableString - The encoded string to decode
   * @param {Object} options - Optional decoding options
   * @param {boolean} options.spaces - Treat literal spaces as data (decode them to space bytes)
   * @param {boolean} options.stripWhitespace - Strip whitespace before decoding (for block-formatted input)
   * @param {boolean} options.warnOnIndent - Warn if spaces appear after newlines in spaces mode
   * @returns {Uint8Array} The decoded binary data
   */
  decode(printableString, options = {}) {
    if (typeof printableString !== 'string') {
      throw new Error("Input must be a string");
    }

    const spacesMode = options.spaces === true;
    const stripWhitespace = options.stripWhitespace === true;

    if (spacesMode && options.warnOnIndent) {
      warnSpacesAfterNewline(printableString);
    }

    // Only strip whitespace if explicitly requested
    let cleanedString = printableString;
    if (stripWhitespace) {
      cleanedString = spacesMode
        ? printableString.replace(/[\r\n\t]/g, '')
        : printableString.replace(/[\r\n\t ]/g, '');
    }

    const result = [];
    let i = 0;

    // Process the string one character at a time
    while (i < cleanedString.length) {
      if (spacesMode && cleanedString[i] === ' ') {
        result.push(0x20);
        i += 1;
        continue;
      }
      let matched = false;

      // Try to match longest first (up to 4 code points for our charset)
      // In JavaScript, some characters may be represented as surrogate pairs
      for (let len = Math.min(4, cleanedString.length - i); len >= 1; len--) {
        const sub = cleanedString.substring(i, i + len);
        const decoded = this.decodeMap.get(sub);

        if (decoded !== undefined) {
          result.push(decoded);
          i += len;
          matched = true;
          break;
        }
      }

      // If we didn't match any character in our map, pass through the UTF-8 character intact
      if (!matched) {
        // Get the code point at current position (handles surrogate pairs)
        const codePoint = cleanedString.codePointAt(i);
        if (codePoint !== undefined) {
          // Encode the code point to UTF-8 bytes and add to result
          const char = String.fromCodePoint(codePoint);
          const encoder = sharedTextEncoder;
          const bytes = encoder.encode(char);
          for (const byte of bytes) {
            result.push(byte);
          }
          // Advance by the number of UTF-16 code units (1 for BMP, 2 for supplementary)
          i += char.length;
        } else {
          i++;
        }
      }
    }

    return new Uint8Array(result);
  }

  /**
   * Hexlike passthrough set: bytes that pass through as-is in hexlike mode.
   * . 0-9 @ A-Z ^ _ a-z (the same bytes that are identity-mapped in the character map)
   */
  static get HEXLIKE_PASSTHROUGH() {
    if (!PrintableBinary._hexlikePassthrough) {
      const pt = new Set();
      pt.add(46);   // .
      for (let b = 48; b <= 57; b++) pt.add(b);   // 0-9
      pt.add(64);   // @
      for (let b = 65; b <= 90; b++) pt.add(b);   // A-Z
      pt.add(94);   // ^
      pt.add(95);   // _
      for (let b = 97; b <= 122; b++) pt.add(b);  // a-z
      PrintableBinary._hexlikePassthrough = pt;
    }
    return PrintableBinary._hexlikePassthrough;
  }

  // Οχ prefix: Greek Omicron (U+039F) + Greek Chi (U+03C7) — NOT ASCII "0x"
  static get OX_PREFIX() {
    return '\u039F\u03C7';  // Οχ
  }

  // Οχ as UTF-8 bytes: CE 9F CF 87
  static get OX_BYTES() {
    return Buffer.from([0xCE, 0x9F, 0xCF, 0x87]);
  }

  /**
   * Detect Οχ hex sequences in input (for cross-format warnings)
   * @param {string} inputString - The string to check
   * @returns {boolean} True if hexlike Οχ sequences are found
   */
  static detectHexlike(inputString) {
    if (typeof inputString !== 'string' || inputString.length === 0) {
      return false;
    }
    const ox = PrintableBinary.OX_PREFIX;
    const idx = inputString.indexOf(ox);
    if (idx < 0) return false;
    // Check that Οχ is followed by at least one hex pair
    const after = inputString.substring(idx + ox.length);
    return /^[0-9A-F]{2}/.test(after);
  }

  /**
   * Encode binary data to hexlike format
   * @param {Uint8Array|ArrayBuffer|Buffer} binaryData - The binary data to encode
   * @param {Object} options - Optional encoding options
   * @param {boolean} options.spaces - Preserve literal spaces (treat as passthrough)
   * @returns {string} The hexlike-encoded string
   */
  hexlikeEncode(binaryData, options = {}) {
    // Convert ArrayBuffer to Uint8Array if needed
    if (binaryData instanceof ArrayBuffer) {
      binaryData = new Uint8Array(binaryData);
    }
    if (!(binaryData instanceof Uint8Array)) {
      throw new Error("Input must be a Uint8Array or ArrayBuffer");
    }

    const spacesMode = options.spaces === true;
    const pt = PrintableBinary.HEXLIKE_PASSTHROUGH;
    const ox = PrintableBinary.OX_PREFIX;

    const result = [];
    let i = 0;
    const len = binaryData.length;

    while (i < len) {
      const byte = binaryData[i];
      const isPassthrough = pt.has(byte) || (spacesMode && byte === 0x20);

      if (isPassthrough) {
        // Passthrough run
        const runStart = i;
        while (i < len) {
          const b = binaryData[i];
          if (pt.has(b) || (spacesMode && b === 0x20)) {
            i++;
          } else {
            break;
          }
        }
        // Add the passthrough characters
        for (let j = runStart; j < i; j++) {
          result.push(String.fromCharCode(binaryData[j]));
        }
      } else {
        // Non-passthrough run: collect hex
        const hexParts = [];
        while (i < len) {
          const b = binaryData[i];
          if (pt.has(b) || (spacesMode && b === 0x20)) {
            break;
          }
          hexParts.push(b.toString(16).toUpperCase().padStart(2, '0'));
          i++;
        }

        // Delimiter space before Οχ (unless at start of output)
        if (result.length > 0) {
          result.push(' ');
        }
        result.push(ox);
        result.push(hexParts.join(''));
        // Delimiter space after hex run (unless at end of output)
        if (i < len) {
          result.push(' ');
        }
      }
    }

    return result.join('');
  }

  /**
   * Decode hexlike format back to binary
   * @param {string} printableString - The hexlike-encoded string to decode
   * @param {Object} options - Optional decoding options
   * @returns {{ data: Uint8Array, foundHex: boolean }} The decoded binary data and whether any hex sequences were found
   */
  hexlikeDecode(printableString, options = {}) {
    if (typeof printableString !== 'string') {
      throw new Error("Input must be a string");
    }

    const ox = PrintableBinary.OX_PREFIX;
    const oxLen = ox.length;  // 2 JS chars (Ο and χ)
    const result = [];
    let i = 0;
    const len = printableString.length;
    let foundHex = false;
    const hexRegex = /^[0-9A-Fa-f]$/;

    while (i < len) {
      // Check for Οχ (possibly preceded by delimiter space)
      let atOx = false;

      if (i + oxLen <= len && printableString.substring(i, i + oxLen) === ox) {
        atOx = true;
      } else if (i + 1 + oxLen <= len && printableString[i] === ' '
                 && printableString.substring(i + 1, i + 1 + oxLen) === ox) {
        i++;  // consume delimiter space
        atOx = true;
      }

      if (atOx) {
        foundHex = true;
        i += oxLen;  // skip past Οχ
        // Read hex pairs
        while (i + 1 < len) {
          const h1 = printableString[i];
          const h2 = printableString[i + 1];
          if (hexRegex.test(h1) && hexRegex.test(h2)) {
            result.push(parseInt(h1 + h2, 16));
            i += 2;
          } else {
            break;
          }
        }
        // Consume trailing delimiter space (if present)
        if (i < len && printableString[i] === ' ') {
          i++;
        }
      } else {
        // Passthrough: encode the character as UTF-8 bytes
        const codePoint = printableString.codePointAt(i);
        if (codePoint !== undefined) {
          const char = String.fromCodePoint(codePoint);
          const encoder = sharedTextEncoder;
          const bytes = encoder.encode(char);
          for (const byte of bytes) {
            result.push(byte);
          }
          i += char.length;
        } else {
          i++;
        }
      }
    }

    return { data: new Uint8Array(result), foundHex };
  }

  /**
   * Detect whether input appears to be already printable-binary encoded.
   * Iterates input as UTF-8 characters, checks each against the decode map,
   * and counts high-confidence glyphs (those whose encoding differs from
   * the raw byte value).
   *
   * @param {string} input - The UTF-8 string to check
   * @param {number} threshold - Confidence threshold (default 0.05 for 5%)
   * @returns {{ detected: boolean, confidence: number }}
   */
  detectDoubleEncode(input, threshold = 0.05) {
    if (typeof input !== 'string' || input.length === 0) {
      return { detected: false, confidence: 0 };
    }

    // Build high-confidence set lazily
    if (!this._highConfidenceSet) {
      this._highConfidenceSet = new Set();
      for (let i = 0; i < 256; i++) {
        const glyph = this.encodeMap.get(i);
        // High confidence if the glyph is not a single-char identity mapping
        if (glyph.length !== 1 || glyph.charCodeAt(0) !== i) {
          this._highConfidenceSet.add(glyph);
        }
      }
    }

    let glyphCount = 0;
    let charCount = 0;

    // Iterate by unicode characters (handles surrogate pairs)
    for (const char of input) {
      charCount++;
      if (this.decodeMap.has(char)) {
        const byteVal = this.decodeMap.get(char);
        const glyph = this.encodeMap.get(byteVal);
        if (this._highConfidenceSet.has(glyph)) {
          glyphCount++;
        }
      }
    }

    if (charCount === 0) {
      return { detected: false, confidence: 0 };
    }

    const confidence = glyphCount / charCount;
    return { detected: confidence >= threshold, confidence };
  }

  /**
   * Encode a string (treating it as UTF-8) to printable format
   * This is a convenience method for string input
   * @param {string} str - The string to encode
   * @returns {string} The encoded printable string
   */
  encodeString(str, options = {}) {
    const encoder = sharedTextEncoder;
    const bytes = encoder.encode(str);
    return this.encode(bytes, options);
  }

  /**
   * Decode a printable string back to a UTF-8 string
   * This is a convenience method that returns a string instead of bytes
   * @param {string} printableString - The encoded string to decode
   * @returns {string} The decoded string
   */
  decodeToString(printableString, options = {}) {
    const bytes = this.decode(printableString, options);
    const decoder = new TextDecoder();
    return decoder.decode(bytes);
  }

  /**
   * CRC-32/ISO-HDLC (the zip/gzip/png CRC): reflected, poly 0xEDB88320,
   * init/xorout 0xFFFFFFFF. Vector-pinned to the published constants so this JS
   * impl cannot silently diverge from the Zig core's pb_crc32 (MFIC differential).
   * @param {Uint8Array} bytes
   * @returns {number} unsigned 32-bit CRC
   */
  crc32(bytes) {
    let crc = 0xFFFFFFFF;
    for (let i = 0; i < bytes.length; i++) {
      crc ^= bytes[i];
      for (let k = 0; k < 8; k++) {
        crc = (crc & 1) ? ((crc >>> 1) ^ 0xEDB88320) : (crc >>> 1);
      }
    }
    return (crc ^ 0xFFFFFFFF) >>> 0;
  }

  /** Lowercase 8-hex-digit CRC-32 of `bytes` (the container's on-wire form). */
  crc32hex(bytes) {
    return this.crc32(bytes).toString(16).padStart(8, '0');
  }

  /**
   * Assemble a printable-binary-file container object (schema v1) from raw bytes
   * + optional metadata. The JSON envelope is trivial glue (A2 architecture);
   * the only algorithms — the codec and crc32 — are shared with the core. Caller
   * JSON.stringify's the result. Optional metadata is omitted when absent so the
   * format degrades gracefully (browser has only name/size/lastModified; POSIX
   * adds mode/owner/group).
   * @param {Uint8Array} bytes
   * @param {{filename?:string, modified_ms?:number, created_ms?:number, mode?:string, owner?:string, group?:string}} [meta]
   * @returns {object} the container
   */
  /**
   * Strip transport-injected whitespace from an encoded payload. The default
   * encoding emits no literal spaces/tabs/CR/LF (all are glyph'd), so a clean
   * payload is unchanged; this only removes whitespace a text transport (email
   * wrap, reflow) added — making the container as whitespace-tolerant as raw
   * printable-binary while keeping crc integrity intact for real corruption.
   */
  _canonicalPayload(data, keepSpaces) {
    // keepSpaces (container --spaces): literal spaces are DATA, so strip only
    // tab/CR/LF as transport noise; otherwise strip spaces too.
    return String(data).replace(keepSpaces ? /[\r\n\t]/g : /[\r\n\t ]/g, '');
  }

  /**
   * JSON.parse with a transport-tolerant fallback: a hard line-wrap can inject a
   * raw newline into the long `data` string, which JSON forbids unescaped inside
   * a string literal. On a parse failure, strip raw control whitespace (never
   * legitimate in our short metadata strings nor in the glyph payload) and retry.
   */
  _parseLenient(text) {
    try { return JSON.parse(text); }
    catch (_e) { return JSON.parse(String(text).replace(/[\r\n\t]/g, '')); }
  }


  encodeToContainer(bytes, meta = {}, opts = {}) {
    if (!(bytes instanceof Uint8Array)) {
      throw new Error("encodeToContainer expects a Uint8Array");
    }
    // opts.spaces: preserve literal spaces in the payload (legible ASCII). No schema
    // flag is written -- decode's crc-probe disambiguates spaces-as-data vs noise.
    const spaces = opts.spaces === true;
    const data = this.encode(bytes, { spaces });
    const dataBytes = sharedTextEncoder.encode(this._canonicalPayload(data, spaces));
    const container = {
      format: "printable-binary-file",
      version: 1,
      filename: meta.filename ?? "",
      byte_length: bytes.length,
      crc32: this.crc32hex(bytes),
      crc32_encoded: this.crc32hex(dataBytes),
    };
    for (const k of ["modified_ms", "created_ms", "mode", "owner", "group", "mime"]) {
      if (meta[k] !== undefined && meta[k] !== null) container[k] = meta[k];
    }
    // `data` is appended LAST so all metadata sits up front (JS object key
    // order is insertion order) -- the big payload reads at the end.
    container.data = data;
    return container;
  }

  /**
   * Parse a printable-binary-file container (object or JSON string) back to the
   * original bytes + metadata. Self-verifies integrity: crc32_encoded (if present)
   * is checked BEFORE decode (catches transport corruption of `data`); byte_length
   * and crc32 are checked AFTER decode. Any mismatch throws — never silently
   * returns corrupt data. Missing optional fields are tolerated.
   * @param {object|string} input
   * @returns {{ bytes: Uint8Array, meta: object }}
   */
  decodeFromContainer(input) {
    const c = typeof input === "string" ? this._parseLenient(input) : input;
    if (!c || typeof c !== "object") {
      throw new Error("Container must be a JSON object or JSON string");
    }
    if (c.format !== "printable-binary-file") {
      throw new Error("Not a printable-binary-file container (missing/invalid 'format')");
    }
    if (typeof c.data !== "string") {
      throw new Error("Container 'data' must be a string");
    }
    // Flagless crc-probe: no schema flag records whether --spaces was used; the
    // crc32_encoded oracle disambiguates. Try keeping literal spaces (DATA in a
    // --spaces container); if the crc mismatches, strip them as transport noise.
    let cleanData = this._canonicalPayload(c.data, true);
    let spaces = true;
    if (c.crc32_encoded !== undefined && c.crc32_encoded !== null) {
      const want = String(c.crc32_encoded).toLowerCase();
      if (this.crc32hex(sharedTextEncoder.encode(cleanData)) !== want) {
        const stripped = this._canonicalPayload(c.data, false);
        if (this.crc32hex(sharedTextEncoder.encode(stripped)) === want) {
          // Literal spaces were noise. If the space glyph is ALSO present, the payload
          // mixed real (glyph) spaces with formatting spaces -> warn we dropped them.
          const spaceGlyph = this.encodeMap.get(0x20);
          if (spaceGlyph && cleanData.includes(spaceGlyph)) {
            console.warn(`Warning: literal spaces in container data were assumed to be ignorable formatting because the space glyph ${spaceGlyph} was also present; stripping them`);
          }
          cleanData = stripped;
          spaces = false;
        } else {
          throw new Error(`Container crc32_encoded mismatch (got ${this.crc32hex(sharedTextEncoder.encode(cleanData))}, expected ${c.crc32_encoded}) — 'data' is corrupted`);
        }
      }
    }
    const bytes = this.decode(cleanData, { spaces });
    if (c.byte_length !== undefined && c.byte_length !== null && bytes.length !== c.byte_length) {
      throw new Error(`Container byte_length mismatch (decoded ${bytes.length}, expected ${c.byte_length})`);
    }
    if (c.crc32 !== undefined && c.crc32 !== null) {
      const got = this.crc32hex(bytes);
      if (got !== String(c.crc32).toLowerCase()) {
        throw new Error(`Container crc32 mismatch (got ${got}, expected ${c.crc32}) — decoded data is corrupted`);
      }
    }
    const meta = {};
    for (const k of ["filename", "modified_ms", "created_ms", "mode", "owner", "group", "mime"]) {
      if (c[k] !== undefined && c[k] !== null) meta[k] = c[k];
    }
    return { bytes, meta };
  }

  /**
   * Decode-mode router for the web/CLI: given pasted-or-loaded text, auto-route
   * between a printable-binary-file.json container and raw printable-binary
   * glyphs. Robust to raw output that merely starts with a literal '{' — to count
   * as a container it must JSON-parse AND carry the format discriminator. Returns
   * { bytes, filename, meta, kind:'container'|'raw' }. A corrupt container still
   * throws (decodeFromContainer self-verify) — never silently mis-decodes.
   * @param {string} text
   * @returns {{ bytes: Uint8Array, filename: string, meta: object, kind: string }}
   */
  decodeText(text) {
    const trimmed = String(text).trim();
    if (trimmed.startsWith('{')) {
      let parsed = null;
      try { parsed = this._parseLenient(trimmed); } catch (_e) { parsed = null; }
      if (parsed && parsed.format === 'printable-binary-file') {
        const { bytes, meta } = this.decodeFromContainer(parsed);
        return { bytes, filename: meta.filename || 'decoded.bin', meta, kind: 'container' };
      }
    }
    const bytes = this.decode(text);
    return { bytes, filename: 'decoded.bin', meta: {}, kind: 'raw' };
  }
}

// Export for different environments
// ES Module export
export default PrintableBinary;

// CommonJS export for Node.js compatibility
if (typeof module !== 'undefined' && module.exports) {
  module.exports = PrintableBinary;
}

// Global export for browser <script> tag usage
if (typeof window !== 'undefined') {
  window.PrintableBinary = PrintableBinary;
}

// Deno compatibility
if (typeof Deno !== 'undefined') {
  // Already exported via ES module
}
