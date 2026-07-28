# PrintableBinary

[![Mechatron Prime CI](https://img.shields.io/endpoint?url=https%3A%2F%2Fthelio-nixos.tail66c90.ts.net%2Fbadges%2Fprintable_binary.json&style=for-the-badge)](https://thelio-nixos.tail66c90.ts.net/mechatron-prime/)
[![GitHub CI](https://github.com/pmarreck/printable_binary/actions/workflows/ci.yml/badge.svg?branch=yolo)](https://github.com/pmarreck/printable_binary/actions/workflows/ci.yml)

A cross-platform utility with LuaJIT, C, Zig, JavaScript/Node, Rust, WebAssembly, and Cosmopolitan **Actually Portable Executable (APE)** variants for encoding arbitrary binary data into human-readable UTF-8 text, and then decoding it back to the original binary data.

## Overview

PrintableBinary is designed to [de]serialize binary data to/from a visually distinct, human-readable format that is also copy-pastable and embeddable in any UTF-8-aware context. It's an alternative to hexadecimal encoding that offers better visual density and makes embedded ASCII text immediately recognizable, while also making it possible to incorporate binary data into text-based formats (such as JSON, TOML, XML, YAML, etc.) without escaping issues.

### Self-hosted CI

Mechatron Prime builds the exact committed target list in
[`.mechatron-prime/targets`](.mechatron-prime/targets). For the fleet-wide
onboarding, webhook, and live-verification procedure, follow the canonical
[Mechatron Prime CI guide](https://github.com/pmarreck/mechatron-prime/blob/yolo/MECHATRON_PRIME_CI.md).

This implementation allows you to view binary data directly in a terminal (it even has a pipe inspection mode with `--passthrough`) without breaking the display, making it particularly useful for debugging, logging, sharing binary data in human-readable form, embedding binary values directly in tests as legible inline literals instead of separate fixture files, and even dragging files into a web UI for instant encode/decode.

## Features

- **Multiple Implementations**: Available as a LuaJIT script, native C CLI, Cosmopolitan APE, Zig CLI, JavaScript module/Node CLI, WebAssembly CLI, and Rust raw codec for maximum flexibility
- **Web & Node.js Tooling**: Drag-and-drop browser interface and a Node-based CLI wrapper share the same encode/decode core for cross-platform workflows
- **Visually Distinct Characters**: Each of the 256 possible byte values maps to a unique, visually distinct UTF-8 character
- **ASCII Passthrough**: Standard printable ASCII characters (32-126) largely remain themselves for immediate recognition
- **Shell-Safe Encoding**: Special characters that could cause shell issues are encoded with safe Unicode alternatives
- **Single Character Width**: Each encoded representation renders as a single character wide in a monospace terminal
- **Compactness**: Uses 1–3 byte UTF-8 characters. Data with lots of printable ASCII grows only nominally — roughly **1.2×** — while data dominated by high bytes (128–255) can expand **2–3×** (each such byte becomes a 2–3 byte UTF-8 glyph)
- **Usability**: Encoded strings are easily copyable, pastable, and printable, and resistant to whitespace incursion (newlines, indentation, line-wrapping) -- the decoder ignores inserted whitespace, so blocks survive reflow and email/chat transports
- **Formatting**: Customizable output formatting with group size and line width options
- **Binary Safety**: Preserves all binary data, including NUL bytes, when encoding and decoding
- **Passthrough Mode**: Simultaneously outputs original binary data to stdout and encoded text to stderr for flexible processing pipelines
- **File Container (`.pbf.json`)**: Wrap a file as one self-describing, self-verifying JSON object that preserves the filename and a CRC-32 check -- decodable by every full CLI and the browser UI, and resistant to whitespace-mangling transports (email, reflow); see [File Container](#file-container-pbfjson)

### Practical benefits (why use this?)
- **Human-scannable snapshots:** denser than hex, more readable than Base64; great for fixtures/tests where you want literal UTF-8 instead of escaped hex blobs.
- **Better diffs & greppability:** control chars and whitespace are explicit, so structure pops out; far richer than `strings(1)`, which drops most bytes.
- **Debuggable logs & pastebins:** printable, reversible, survives Slack/email/wikis without mangling or wrap damage.
- **Small binary fixtures:** embed headers, protocol frames, certs, etc., in text files while staying patch/grep friendly.
- **Cross-platform:** native C, Zig, LuaJIT, Node, and Rust run directly; the same C CLI also ships as WebAssembly and a single-file Cosmopolitan APE.
- **Monospace-safe glyph set:** every glyph is vetted to occupy the same width in common monospace fonts, so alignment in editors/terminals/diffs stays intact (surprisingly many Unicode symbols don’t).

### Compared to Hexadecimal Encodings

- **Higher on-screen density**: Hex consumes two glyphs per byte; PrintableBinary maps each byte to a single visible character, so you see roughly twice as much data per line while still preserving UTF-8 safety.
- **ASCII stands out**: Printable ASCII bytes are left untouched (except for shell-hostile symbols, which use look-alike substitutes), so embedded text is immediately readable instead of needing to mentally decode hex pairs.
- **Control characters are labeled**: Bytes 0–31 and DEL render as mnemonic symbols (`⏎`, `↧`, `⌫`, etc.), making structure and control flow obvious without extra tooling.
- **Trade-off**: Hex expands data by exactly 2× in bytes. PrintableBinary ranges from ~1.2× on ASCII-heavy data to 2–3× on data dominated by high bytes (128–255), averaging roughly 1.8× on mixed real-world binaries. The small extra cost buys markedly better readability and paste safety.

## Performance

The comparative benchmark is intentionally machine-local: it verifies a round trip before timing and reports median distribution data from `hyperfine`, rather than presenting stale throughput as a property of an implementation. It covers every available CLI path, including Rust, WebAssembly, and the Cosmopolitan APE:

| Target | Benchmark invocation | What is measured |
| --- | --- | --- |
| C, Zig, LuaJIT, Node | Direct CLI | End-to-end process + file I/O |
| APE | Clean-environment adapter | End-to-end Cosmopolitan process + file I/O |
| Rust | stdin adapter around its raw-codec CLI | End-to-end process + stdin/stdout I/O |
| WebAssembly | `wazero run` adapter | End-to-end WASM runtime + CLI I/O |

```bash
# Build the native, Zig, WASM, and APE artifacts; build Rust separately.
./build
nix develop -c cargo build --release --manifest-path rust/Cargo.toml

# Check exactly which implementations are ready, then compare all of them.
nix develop -c ./bm/benchmark-zig-opt --list-impls
nix develop -c ./bm/benchmark-zig-opt --quick --sizes "1M"

# Require a focused comparison; this fails rather than silently omitting a target.
nix develop -c ./bm/benchmark-zig-opt --impls rust,wasm,ape --sizes "10M"
```

The Rust crate also has an in-process codec microbenchmark (`nix develop -c cargo run --release --manifest-path rust/Cargo.toml --example bench`). It deliberately excludes CLI and runtime startup costs, so it should be compared only with the Zig `--bench` core measurement—not with the cross-CLI table above.

Key optimizations in the Zig core:
- **Pre-allocated buffers**: encode/decode output sized upfront (no growth checks in the hot loop).
- **Flat character map**: a comptime-built contiguous byte buffer (~1.5 KB) replacing 256 scattered fat pointers — fits in L1 cache.
- **SIMD literal-prefix gate**: a portable 16-byte vector check copies a contiguous run of literal passthrough glyphs unchanged during both encode and decode, then falls back to the compact variable-width mapper at the first mapped byte.
- **O(1) decode lookup**: direct tables for 1- and 2-byte UTF-8 sequences plus a compact 24 KiB table for the map's three 3-byte lead-byte planes, replacing the former binary search.
- **No inner decode loop**: a single UTF-8 length check + direct lookup per character.

The C and Lua decoders were tuned in a measured pass: C uses direct 1-/2-byte lookup tables (**1.9×** decode). Lua got two passes — resolving each glyph by its UTF-8 leading-byte length (instead of brute-forcing all four), then writing decoded bytes straight into a LuaJIT `string.buffer` via its FFI `reserve`/`commit` API (no per-byte `string.char`). Together that took Lua **decode from ~8 to ~91 MB/s** — now faster than its own encode (which uses `string.buffer:put`, ~1.2×). Every optimization is benchmarked before and after (hyperfine), and a continuous memory-leak suite (`test/leak_test`) guards the FFI/C paths against regressions.

The optional PGO path (`make pgo-ffi`) adds a further ~1–3% via profile-guided branch layout, dogfooding the Zig library through its public C ABI.

## Usage

### As a Command Line Tool

```bash
# Use any implementation:
# Zig CLI (default):  ./build zig && ./bin/printable-binary
# LuaJIT CLI:         ./bin/printable-binary-luajit
# Node.js CLI:         ./bin/printable-binary-node.js
# C version:           ./build native && ./bin/printable-binary-c
# APE version:         ./build ape && ./bin/printable-binary-ape.com
# WASM version:        ./build wasm && wazero run bin/printable-binary.wasm < input.bin
# Rust raw codec:      cargo build --release --manifest-path rust/Cargo.toml
#                     < input.bin rust/target/release/printable-binary-rs
# (Examples below use the canonical Zig full CLI. Rust intentionally offers only
# stdin→stdout encoding and -d/--decode; the other listed CLI variants share
# the full option surface.)

# Build every compiled distribution on Linux (C, Zig, WASM, and APE).
./build_all

# Encode binary data
echo -n "Hello, World!" | ./bin/printable-binary
# Output: Hello,␣World﹗

# Note: Direct encoding of binary data as command-line arguments is not supported
# because shell environments cannot represent all binary data (such as NUL bytes)
# Always pipe input or specify a file to encode

# Encode a file
./bin/printable-binary somefile.bin > encoded.txt

# Encode with formatting (groups of 8 characters, 10 groups per line)
./bin/printable-binary -f somefile.bin > formatted_encoded.txt

# Encode with custom formatting (groups of 4 characters, 16 groups per line)
./bin/printable-binary -f=4x16 somefile.bin > custom_formatted.txt

# Inspect the active character map (table/JSON/CSV)
./bin/printable-binary --mappings | head
./bin/printable-binary-c --mappings-json > mapping.json
./bin/printable-binary-node.js --mappings-csv > mapping.csv

# Decode data (whitespace is ignored during decoding)
echo -n "Hello,␣World﹗" | ./bin/printable-binary -d
# Output: Hello, World!

# Decode formatted data (formatting is ignored)
cat formatted_encoded.txt | ./bin/printable-binary -d > original.bin

# Preserve literal whitespace (spaces, tabs, newlines stay as-is instead of being encoded)
echo -n "A B  C" | ./bin/printable-binary --spaces > encoded_with_spaces.txt
./bin/printable-binary -d -S encoded_with_spaces.txt > restored.bin

# Preserve all whitespace (shorthand for -s -t -n)
./bin/printable-binary -w input.bin > with_whitespace.txt

# Preserve specific characters (e.g., keep ! and " literal)
./bin/printable-binary -p '!"' input.bin > preserved.txt

# Decode block-formatted input (strip whitespace separators first)
./bin/printable-binary -d -S formatted_encoded.txt > original.bin

# Use passthrough mode to output both original binary (stdout) and encoded text (stderr)
# This is useful for binary data processing pipelines that need both representations
echo -n "Hello, World!" | ./bin/printable-binary --passthrough 2>encoded.txt | wc -c
# Binary data goes to stdout, encoded text to stderr

# Use the C implementation for better performance on large files
./bin/printable-binary-c large_file.bin > encoded_large.txt
```

Every CLI writes a final stderr line for informal comparisons:

```text
Input throughput: 4999.36 MB read in 49.939 s (100.11 MB/s)
```

`MB` means decimal input megabytes (1,000,000 bytes). The rate uses bytes read,
not the larger encoded result, and covers input read, codec work, and output
write. Set `PRINTABLE_BINARY_MUTE_STATS=1` to suppress it.

### Web Interface

- Live demo: <https://pmarreck.github.io/printable_binary/>
- Two explicit modes, selected by tabs:
  - **Encode** — drag-and-drop or browse to encode any file. Choose plain-text
    output (`.pbt`) or a self-verifying **`.pbf.json` container** that also keeps
    the filename, modified date, and a CRC-32 integrity check (see
    [File Container](#file-container-pbfjson)).
  - **Decode** — **paste** a printable-binary block *or* a `.pbf.json` container,
    or **drop** a `.pbt`/`.pbf.json` file. It auto-detects container-vs-raw, shows
    a metadata panel (filename, size, integrity), and downloads the restored file
    under its original name.
- Large outputs skip the textarea to avoid browser jank — use the Copy/Download
  buttons, which reuse the exact bytes the CLI and Node implementations produce.
- To hack locally, serve the repo root over HTTP (any static file server) and open
  `index.html` — the ES-module import and character-map fetch need `http://`, not
  `file://`; no build step required.

### File Container (`.pbf.json`)

The `-C`/`--container` flag wraps a file as a self-describing
**`printable-binary-file.json`** — one JSON object that keeps the filename and a
CRC-32 integrity check alongside the encoded data, so a decode can restore the
original file and verify it round-tripped exactly.

```bash
# Encode a file into a container (filename + crc32 embedded)
./bin/printable-binary -C photo.png > photo.png.pbf.json

# Decode the container back to the original bytes (verifies crc32)
./bin/printable-binary -d -C photo.png.pbf.json > photo.png
```

Every full implementation understands it (Lua, Node, native C, APE, WASM, Zig,
the C-FFI CLI, and the browser demo) and they produce **mutually-decodable**
containers. The Rust raw codec intentionally operates below this envelope layer.
The format is
**transport-resistant**: the encoded payload is whitespace-agnostic and
`crc32_encoded` is verified over the canonical (whitespace-stripped) payload —
with a lenient JSON parse for hard line-wraps — so a container survives being
pasted into an email body or reflowed by a text transport, while a genuine
(non-whitespace) corruption is still rejected. Schema (v1, `data` serialized
last so metadata reads up front):

```json
{
  "format": "printable-binary-file",
  "version": 1,
  "filename": "photo.png",
  "byte_length": 12345,
  "crc32": "cbf43926",
  "crc32_encoded": "1a2b3c4d",
  "data": "…encoded glyphs…"
}
```

The browser demo's **Decode** tab consumes the same container (drag-drop or
paste) and restores the file under its original name. Optional metadata
(timestamps, POSIX permissions/owner) is included when the tool can read it and
omitted otherwise; decode never fails on a missing optional field.

**Legible-text containers with `-s`/`--spaces`.** Add `--spaces` to keep literal
spaces in the `data` value instead of encoding them to the space glyph. Since
letters, digits and `. @ ^ _` already pass through as themselves, a text file —
e.g. Markdown — reads naturally inside the container while staying valid,
single-line JSON (newlines remain `¶` glyphs):

```bash
./bin/printable-binary -C --spaces notes.md > notes.md.pbf.json
# data value reads like:  "♯ Title¶¶Some ⁎⁎bold⁎⁎ text.¶˗ a list item¶"
```

No schema flag records this — the format stays `version: 1`. Decode disambiguates
with the `crc32_encoded` oracle: it keeps literal spaces if they check out as
data, otherwise strips them as transport formatting (and warns if the space glyph
was also present, i.e. the spaces were injected into a non-`--spaces` container).
`--spaces` is the only preserve flag allowed with `-C`; `--tabs`/`--crlf`/`-w`/
`--preserve` are rejected, since raw tab/CR/LF would break both JSON validity and
the whitespace-stripping transport-resistance.

### Hexlike Mode (`-X`)

`-X`/`--hexlike` is a hybrid view: printable ASCII passes through untouched while
every other byte is shown as an uppercase hex run prefixed by `Οχ` (Greek
Omicron+Chi). It keeps embedded text fully legible while making binary regions
explicit — useful when you care more about reading the ASCII than about density.
Round-trips with `-X -d`.

```bash
# Encode in hexlike mode, then decode it back
printf 'Hi\x00\xff!' | ./bin/printable-binary -X
printf 'Hi\x00\xff!' | ./bin/printable-binary -X | ./bin/printable-binary -X -d | xxd
```

### As a Lua Library

```lua
local PrintableBinary = require("printable_binary")

-- Encode binary data
local binary_data = "Hello, World!"
local encoded = PrintableBinary.encode(binary_data)
print(encoded)  -- Output: Hello,␣World!

-- Decode back to binary
local decoded = PrintableBinary.decode(encoded)
print(decoded)  -- Output: Hello, World!
```

### As a JavaScript Module

```js
import PrintableBinary from './js/printable_binary.js';

const pb = new PrintableBinary();
const input = new Uint8Array([0x00, 0xFF, 0x41]);

// Encode to printable UTF-8
const encoded = pb.encode(input, { format: '75x1' });
console.log(encoded);

// Decode back to bytes
const decoded = pb.decode(encoded);
console.log(Array.from(decoded)); // [0, 255, 65]

// Preserve literal spaces (tabs/newlines/CR still ignored on decode)
const encodedSpaces = pb.encodeString('A B  C', { spaces: true });
const decodedSpaces = pb.decodeToString(encodedSpaces, { spaces: true });
```

The same module powers the browser UI and can be run in Node.js (ESM) or bundled for other environments.

### As a Rust Library or Raw-Codec CLI

The Rust crate is a compact transport-oriented implementation that generates its
tables from the same `character_map.txt` at compile time. Its `encode_into` and
`decode_into` APIs reuse a caller-owned `Vec<u8>` after warm-up, avoiding a
per-message allocation.

```bash
nix develop -c cargo build --release --manifest-path rust/Cargo.toml

# The provisional raw-codec CLI is deliberately stdin-only.
rust/target/release/printable-binary-rs < input.bin > encoded.pbt
rust/target/release/printable-binary-rs --decode < encoded.pbt > restored.bin
```

```rust
use printable_binary::{decode_into, encode_into};

let mut encoded = Vec::new();
encode_into(b"frame\x00", &mut encoded);

let mut decoded = Vec::new();
decode_into(&encoded, &mut decoded);
assert_eq!(decoded, b"frame\x00");
```

The Rust CLI does not yet implement the full formatting/container/mapping-report
surface. Use a full CLI when those features are needed; use the Rust crate when
embedding the raw codec or moving bytes across a Rust↔Zig boundary.

### JavaScript CLI

For command-line parity with the LuaJIT/C tools, use the Node-based wrapper:

```bash
# Encode (auto-detects stdin vs. file)
./bin/printable-binary-node.js input.bin > encoded.pbt

# Decode (whitespace is ignored automatically)
./bin/printable-binary-node.js --decode encoded.pbt > restored.bin

# Apply formatting (e.g., 75 characters per line)
./bin/printable-binary-node.js --format 75x1 input.bin > formatted.pbt

# Pipe data through stdin
cat input.bin | ./bin/printable-binary-node.js -f=8x10 > encoded.txt

# Dump the current character map
./bin/printable-binary-node.js --mappings-json > map.json
```

Supported flags: `-d/--decode`, `-f/--format NxM`, `-s/--spaces`, `--mappings*`, `-h/--help`. The CLI shares the exact encode/decode implementation with the browser UI.

### As an Elixir `~PB` Sigil (compile-time)

The `~PB` sigil decodes printable-binary glyphs to a **raw binary at compile
time**, so you can embed binary data legibly inline in Elixir source (no
separate fixture files) with zero runtime cost — the decoded bytes are baked
straight into the compiled BEAM module. A literal `"` never appears in the
encoding, so a `"""` heredoc can safely hold multi-line payloads.

```elixir
import PrintableBinary

# Decoded to raw bytes at COMPILE time, then trivially assigned to a variable.
# (Letters/digits pass through; comma -> ٫, space -> ␣, ! -> ǃ, etc.)
greeting = ~PB"Hello٫␣Worldǃ"      # => "Hello, World!"

# Heredoc form — whitespace is ignored, so wrapped/pasted glyphs are safe:
blob = ~PB"""
       ·OK
       """                        # => <<0, "OK">>   (byte 0 -> ·)

# Runtime helper for dynamic (non-literal) input:
PrintableBinary.decode(encoded)   # => raw binary
```

Generate the glyphs for any file with the CLI (`printable-binary secret.bin`)
and paste them between the sigil delimiters. See `elixir/` for the module and
tests; the `test-elixir` CI check verifies the decoder against the Zig encoder
(an independent oracle) across all 256 byte values plus random multi-byte input.

### Character Map

Every full CLI (including the WASM and APE variants) ships with the canonical
256-entry table embedded, so you can always inspect it:

```bash
./bin/printable-binary --mappings          # human-readable table
./bin/printable-binary --mappings-json     # machine-readable JSON
./bin/printable-binary --mappings-csv      # spreadsheet-friendly CSV
```

Those commands show whichever map is active. To override the defaults, place a `character_map.txt` next to the executable (or set `PRINTABLE_BINARY_MAP`) and rerun the same flags to confirm your changes. The file format is simple: **256 lines of UTF-8, one glyph per byte value starting at 0x00**. No commas, spaces, or indexes—just the literal characters in order. After editing, run `./utils/audit_character_map.lua character_map.txt` (and `./utils/update_eaw_data.sh` when Unicode publishes a new width table) plus `./utils/generate_embedded_map.lua` so the embedded headers stay in sync.

The runtime lookup order is:

1. `PRINTABLE_BINARY_MAP` environment variable (path to the file)
2. A `character_map.txt` sitting next to the executable/module (`bin/printable-binary`, `js/printable_binary.js`, `bin/printable-binary-c`, or the WASM dir)
3. The current working directory

If none of those locations exist, the embedded table is used automatically. Edit
the file to experiment with alternative glyphs—the LuaJIT, C (native/APE/WASM),
Zig, and Node.js implementations will all honor the override on their next run.
The Rust crate instead bakes the source map in at compile time, so rebuild it
after changing `character_map.txt`.

### Environment Variables

The full CLIs respect a couple of environment variables (LuaJIT, C, APE, WASM,
Zig, Node, and tests):

- `PRINTABLE_BINARY_MAP` – absolute or relative path to a `character_map.txt` that overrides the embedded table. The lookup order is described above.
- `PRINTABLE_BINARY_MUTE_STATS` – set to `1`, `true`, or `yes` to suppress the usual "Encoded …" / "Decoding mode …" statistics that are normally written to stderr. This is handy for scripts that expect clean stderr output while still reusing the default behavior interactively.

When launching the WASM build with wazero, remember that it does **not** inherit host environment variables unless you pass them. After building `bin/printable-binary.wasm` (for example via `make wasm`), use `wazero run --env=PRINTABLE_BINARY_MUTE_STATS=true bin/printable-binary.wasm` (or `--env-inherit` to forward everything) so the behavior matches the native binaries.

### Inspecting Streams (Passthrough Mode)

One powerful trick is to drop PrintableBinary into a pipeline so you can watch the encoded stream on stderr while the raw bytes continue downstream untouched:

```bash
# Monitor traffic but keep the pipeline lossless
tcpdump -i en0 -w - | \
  ./bin/printable-binary --passthrough > capture.raw 2> capture.pbt

# Alternatively inspect a decompression stream:
gzip -c bigfile > /tmp/data.gz
gzip -dc /tmp/data.gz | \
  ./bin/printable-binary --passthrough | md5sum
# stdout (original bytes) flows into md5sum; stderr shows the printable view.
```

Because `--passthrough` sends the original binary to stdout, you can insert PrintableBinary anywhere in a Unix pipeline for observability without modifying the data flow.

### Real-World Recipes

- **Escape-proof JSON embed** – Avoid backslash/quote hell by pre-encoding the bytes, then drop them straight into a JSON string:

  ```bash
  ENCODED="$(./bin/printable-binary secret.bin)"
  printf '{"payload":"%s"}\n' "$ENCODED" | jq .
  # Decode later:
  printf '%s' "$ENCODED" | ./bin/printable-binary -d > restored.bin
  ```

- **Bash assertion on binary snippets** – Keep fixtures inline without here-doc escaping. Generate the encoded blob once (e.g., `PRINTABLE_BINARY_MUTE_STATS=1 printf 'CAFÉ\n' | ./bin/printable-binary`), then paste it into the here-doc:

  ```bash
  want=$'CAFÉ\n'                                     # byte-for-byte expectation
  got=$(./bin/printable-binary -d <<'EOF'
  CAFĹɃ¶
  EOF
  )
  [[ "$got" == "$want" ]] || { echo "mismatch"; exit 1; }
  ```

- **Peek mixed binary/text streams in place** – Mirror a live HTTP POST while keeping the raw bytes intact:

  ```bash
  nc -l 8080 | ./bin/printable-binary --passthrough \
    >requests.raw 2>requests.pbt
  # tail -f requests.pbt to watch headers + body without mojibake.
  ```

- **Web page embed + JS decode** – Ship binary in HTML as plain text, then revive it in the browser using the shared module:

  ```html
  <script type="module">
    import PrintableBinary from './js/printable_binary.js';
    const encoded = `{{REPLACE_WITH_$(./bin/printable-binary file.bin)}}`;
    const pb = new PrintableBinary();
    const bytes = pb.decode(encoded);
    // do something with bytes (e.g., create a Blob)
  </script>
  ```

- **Inspect hint bytes of common formats** – Spot magic numbers without a hex viewer:

  ```bash
  head -c 16 some.pdf | ./bin/printable-binary
  # Expect to see %PDF␣1.7… rendered directly.

  head -c 8 image.png | ./bin/printable-binary
  # Should show 89PNG⏎␣␣ if the PNG signature is intact.
  ```

### Piping to UTF-16 (or other text encodings)

The encoded output is UTF-8 text. Because every glyph is in the BMP, it transcodes **losslessly** to UTF-16 — handy for Windows/PowerShell/JavaScript/.NET consumers. Two thin `iconv` wrappers default to **little-endian** (ARM and x86_64) and handle the BOM:

```bash
# Encode -> UTF-16LE (with BOM)
printable-binary file | bin/utf8to16 > out.utf16

# Decode a UTF-16 stream (BOM auto-detected; little-endian if absent)
bin/utf16to8 < out.utf16 | printable-binary -d

# Explicit endianness / no BOM
printable-binary file | bin/utf8to16 --be        # UTF-16BE + BOM
printable-binary file | bin/utf8to16 --no-bom    # UTF-16LE, no BOM
```

They are just `iconv` wrappers, so any encoding iconv supports works directly too (e.g. `... | iconv -f UTF-8 -t UTF-16LE`).

## Format Compatibility

The PrintableBinary character set is specifically designed to be highly compatible with common text formats:

### ✅ **Excellent Compatibility With:**

- **JSON** - Perfect in quoted strings (we re-encode `"` as `ˮ`)
- **XML/HTML** - Perfect in text content and attributes (no `<>&` in our encodings)
- **TOML** - Perfect in quoted strings
- **YAML** - Perfect in quoted strings, good in unquoted context
- **C/C++/Java/etc.** - Perfect in string literals (we re-encode `\` as `⧹`)
- **Shell scripts** - Perfect in quoted strings (we re-encode `'` as `ʼ`)
- **SQL** - Perfect in quoted strings
- **Most UTF-8 aware text formats**

### 🎯 **Key Design Decisions for Compatibility:**

- **Double quotes** (34) → `ˮ` (U+02EE) - Avoids JSON/XML attribute conflicts
- **Single quotes** (39) → `ʼ` (U+02BC) - Avoids shell/SQL conflicts
- **Backslashes** (92) → `⧹` (U+29F9) - Avoids escape sequence issues
- **Control characters** → Safe Unicode symbols (·, ¶, ⏎, etc.)
- **No problematic delimiters** in our special encodings

### 📝 **Usage Recommendations:**

```bash
# JSON
echo '{"binary_data": "'$(./bin/printable-binary file.bin)'"}'

# XML/HTML
echo '<data>'$(./bin/printable-binary file.bin)'</data>'

# YAML
echo 'data: "'$(./bin/printable-binary file.bin)'"'

# Shell variable
DATA="$(./bin/printable-binary file.bin)"

# C string literal
printf 'char data[] = "%s";\n' "$(./bin/printable-binary file.bin)"
```

**Note:** If your original binary contains problematic characters (like `{`), they'll appear as-is since they're printable ASCII. Use quoted contexts when embedding in structured formats.

## Glyph Selection Design Philosophy

The replacement glyphs were chosen to balance three competing goals:

1. **Byte Economy** - Prefer shorter UTF-8 sequences (1-2 bytes) where possible to minimize encoding overhead. Most printable ASCII passes through at 1:1, so text-heavy data expands minimally; pure random binary averages ~1.85×.

2. **Visual Suggestion** - Each glyph should hint at what it replaces. Examples:
   - `␣` (open box) for space - clearly indicates "there's a space here"
   - `⏎` for carriage return - universal "return/enter" symbol
   - `⇥` for tab - arrow pointing to a bar suggests tabulation
   - `˂˃` for angle brackets - similar shape, clearly related

3. **Unambiguous Distinction** - The glyph must *not* be confused with the original character. This explains choices like:
   - `ˮ` for double-quote - modifier letter double apostrophe, visually evocative and only 2 bytes
   - `ʼ` for single-quote - modifier letter apostrophe looks similar but is clearly distinct
   - `⧷` for backslash - has a horizontal stroke through it

**High-byte ordering (0x80-0xFF):** The extended byte mappings are roughly lexically ordered - they begin with variants of A (ă, Ă, Ǎ...) and end with variants of Z (ź, Ź, ž, Ž, ż, Ż). This allows developers to ballpark approximately what byte value is being represented just by glancing at the glyph's base letter.

## Character Encoding

- **Control Characters (0-31)**: Mapped to visually distinct symbols like ·, ¯, «, », µ, etc.
- **Space (32)**: Encoded as ␣ for visibility
- **Shell-unsafe ASCII characters**: Mapped to safe Unicode alternatives:
  - Exclamation mark (33) → ﹗ (U+FE57) Small Exclamation Mark
  - Double quote (34) → ˮ (U+02EE) Modifier Letter Double Apostrophe
  - Hash (35) → ♯ (U+266F) Music Sharp Sign
  - Dollar sign (36) → ﹩ (U+FE69) Small Dollar Sign
  - Percent (37) → ﹪ (U+FE6A) Small Percent Sign
  - Ampersand (38) → ⅋ (U+214B) Turned Ampersand
  - Single quote (39) → ʼ (U+02BC) Modifier Letter Apostrophe
  - Parentheses (40-41) → ❨❩ (U+2768-2769) Medium Parenthesis Ornaments
  - Asterisk (42) → ﹡ (U+FE61) Small Asterisk
  - Plus (43) → ﹢ (U+FE62) Small Plus Sign
  - Minus (45) → ﹣ (U+FE63) Small Hyphen-Minus
  - Slash (47) → ⁄ (U+2044) Fraction Slash
  - Colon (58) → ꞉ (U+A789) Modifier Letter Colon
  - Semicolon (59) → ; (U+037E) Greek Question Mark
  - Equals (61) → ꞊ (U+A78A) Modifier Letter Short Equals Sign
  - Question mark (63) → Ɂ (U+0241) Latin Capital Letter Glottal Stop
  - At sign (64) → @ (U+0040) Commercial At
  - Backslash (92) → ⧷ (U+29F7) Reverse Solidus with Horizontal Stroke
  - Brackets (91, 93) → ⟦⟧ (U+27E6-27E7) Mathematical White Square Brackets
  - Backtick (96) → ˋ (U+02CB) Modifier Letter Grave Accent
  - Braces (123-125) → ❴∣❵ (Ornament and mathematical variants)
  - Tilde (126) → ˜ (U+02DC) Small Tilde
- **DEL (127)**: Encoded as ⌦
- **Extended Bytes (128-255)**: Pulled directly from `character_map.txt` and grouped alphabetically so adjacent bytes share related glyphs

### Complete Character Mapping Reference

This table is generated from `character_map.txt` so every implementation stays in sync. **ASCII byte** is the conventional source-byte name; `—` marks bytes outside ASCII. **Glyph name** identifies the Unicode character emitted for that byte.

| Byte | ASCII byte | Char | Unicode | UTF-8 | Glyph name |
| --- | --- | --- | --- | --- | --- |
| 0 | NUL | · | U+00B7 | C2 B7 | Middle Dot |
| 1 | SOH | ¯ | U+00AF | C2 AF | Macron |
| 2 | STX | « | U+00AB | C2 AB | Left-Pointing Double Angle Quotation Mark |
| 3 | ETX | » | U+00BB | C2 BB | Right-Pointing Double Angle Quotation Mark |
| 4 | EOT | ϟ | U+03DF | CF 9F | Greek Small Letter Koppa |
| 5 | ENQ | ¿ | U+00BF | C2 BF | Inverted Question Mark |
| 6 | ACK | ¡ | U+00A1 | C2 A1 | Inverted Exclamation Mark |
| 7 | BEL | ª | U+00AA | C2 AA | Feminine Ordinal Indicator |
| 8 | BS | ⌫ | U+232B | E2 8C AB | Erase To The Left |
| 9 | TAB | ⇥ | U+21E5 | E2 87 A5 | Rightwards Arrow To Bar |
| 10 | LF | ¶ | U+00B6 | C2 B6 | Pilcrow Sign |
| 11 | VT | ↧ | U+21A7 | E2 86 A7 | Downwards Arrow From Bar |
| 12 | FF | § | U+00A7 | C2 A7 | Section Sign |
| 13 | CR | ⏎ | U+23CE | E2 8F 8E | Return Symbol |
| 14 | SO | ȯ | U+022F | C8 AF | Latin Small Letter O With Dot Above |
| 15 | SI | ʘ | U+0298 | CA 98 | Latin Letter Bilabial Click |
| 16 | DLE | Ɣ | U+0194 | C6 94 | Latin Capital Letter Gamma |
| 17 | DC1 | ¹ | U+00B9 | C2 B9 | Superscript One |
| 18 | DC2 | ² | U+00B2 | C2 B2 | Superscript Two |
| 19 | DC3 | º | U+00BA | C2 BA | Masculine Ordinal Indicator |
| 20 | DC4 | ³ | U+00B3 | C2 B3 | Superscript Three |
| 21 | NAK | µ | U+00B5 | C2 B5 | Micro Sign |
| 22 | SYN | ɨ | U+0268 | C9 A8 | Latin Small Letter I With Stroke |
| 23 | ETB | ⏹ | U+23F9 | E2 8F B9 | Black Square For Stop |
| 24 | CAN | © | U+00A9 | C2 A9 | Copyright Sign |
| 25 | EM | ¦ | U+00A6 | C2 A6 | Broken Bar |
| 26 | SUB | Ƶ | U+01B5 | C6 B5 | Latin Capital Letter Z With Stroke |
| 27 | ESC | ⎋ | U+238B | E2 8E 8B | Broken Circle With Northwest Arrow |
| 28 | FS | Ξ | U+039E | CE 9E | Greek Capital Letter Xi |
| 29 | GS | ǁ | U+01C1 | C7 81 | Latin Letter Lateral Click |
| 30 | RS | ǀ | U+01C0 | C7 80 | Latin Letter Dental Click |
| 31 | US | ¬ | U+00AC | C2 AC | Not Sign |
| 32 | SPACE | ␣ | U+2423 | E2 90 A3 | Open Box |
| 33 | EXCLAMATION MARK | ǃ | U+01C3 | C7 83 | Latin Letter Retroflex Click |
| 34 | QUOTATION MARK | ˮ | U+02EE | CB AE | Modifier Letter Double Apostrophe |
| 35 | NUMBER SIGN | ♯ | U+266F | E2 99 AF | Music Sharp Sign |
| 36 | DOLLAR SIGN | Ꞩ | U+A7A8 | EA 9E A8 | Latin Capital Letter S With Oblique Stroke |
| 37 | PERCENT SIGN | ‰ | U+2030 | E2 80 B0 | Per Mille Sign |
| 38 | AMPERSAND | ⅋ | U+214B | E2 85 8B | Turned Ampersand |
| 39 | APOSTROPHE | ʼ | U+02BC | CA BC | Modifier Letter Apostrophe |
| 40 | LEFT PARENTHESIS | ❨ | U+2768 | E2 9D A8 | Medium Left Parenthesis Ornament |
| 41 | RIGHT PARENTHESIS | ❩ | U+2769 | E2 9D A9 | Medium Right Parenthesis Ornament |
| 42 | ASTERISK | ⁎ | U+204E | E2 81 8E | Low Asterisk |
| 43 | PLUS SIGN | ⨦ | U+2A26 | E2 A8 A6 | Plus Sign With Tilde Below |
| 44 | COMMA | , | U+002C | 2C | Comma |
| 45 | HYPHEN-MINUS | ˗ | U+02D7 | CB 97 | Modifier Letter Minus Sign |
| 46 | FULL STOP | . | U+002E | 2E | Full Stop |
| 47 | SOLIDUS | ⁄ | U+2044 | E2 81 84 | Fraction Slash |
| 48 | DIGIT ZERO | 0 | U+0030 | 30 | Digit Zero |
| 49 | DIGIT ONE | 1 | U+0031 | 31 | Digit One |
| 50 | DIGIT TWO | 2 | U+0032 | 32 | Digit Two |
| 51 | DIGIT THREE | 3 | U+0033 | 33 | Digit Three |
| 52 | DIGIT FOUR | 4 | U+0034 | 34 | Digit Four |
| 53 | DIGIT FIVE | 5 | U+0035 | 35 | Digit Five |
| 54 | DIGIT SIX | 6 | U+0036 | 36 | Digit Six |
| 55 | DIGIT SEVEN | 7 | U+0037 | 37 | Digit Seven |
| 56 | DIGIT EIGHT | 8 | U+0038 | 38 | Digit Eight |
| 57 | DIGIT NINE | 9 | U+0039 | 39 | Digit Nine |
| 58 | COLON | ꞉ | U+A789 | EA 9E 89 | Modifier Letter Colon |
| 59 | SEMICOLON | ; | U+037E | CD BE | Greek Question Mark |
| 60 | LESS-THAN SIGN | ˂ | U+02C2 | 3C | Modifier Letter Left Arrowhead |
| 61 | EQUALS SIGN | ꞊ | U+A78A | EA 9E 8A | Modifier Letter Short Equals Sign |
| 62 | GREATER-THAN SIGN | ˃ | U+02C3 | 3E | Modifier Letter Right Arrowhead |
| 63 | QUESTION MARK | Ɂ | U+0241 | C9 81 | Latin Capital Letter Glottal Stop |
| 64 | COMMERCIAL AT | @ | U+0040 | 40 | Commercial At |
| 65 | UPPERCASE A | A | U+0041 | 41 | Latin Capital Letter A |
| 66 | UPPERCASE B | B | U+0042 | 42 | Latin Capital Letter B |
| 67 | UPPERCASE C | C | U+0043 | 43 | Latin Capital Letter C |
| 68 | UPPERCASE D | D | U+0044 | 44 | Latin Capital Letter D |
| 69 | UPPERCASE E | E | U+0045 | 45 | Latin Capital Letter E |
| 70 | UPPERCASE F | F | U+0046 | 46 | Latin Capital Letter F |
| 71 | UPPERCASE G | G | U+0047 | 47 | Latin Capital Letter G |
| 72 | UPPERCASE H | H | U+0048 | 48 | Latin Capital Letter H |
| 73 | UPPERCASE I | I | U+0049 | 49 | Latin Capital Letter I |
| 74 | UPPERCASE J | J | U+004A | 4A | Latin Capital Letter J |
| 75 | UPPERCASE K | K | U+004B | 4B | Latin Capital Letter K |
| 76 | UPPERCASE L | L | U+004C | 4C | Latin Capital Letter L |
| 77 | UPPERCASE M | M | U+004D | 4D | Latin Capital Letter M |
| 78 | UPPERCASE N | N | U+004E | 4E | Latin Capital Letter N |
| 79 | UPPERCASE O | O | U+004F | 4F | Latin Capital Letter O |
| 80 | UPPERCASE P | P | U+0050 | 50 | Latin Capital Letter P |
| 81 | UPPERCASE Q | Q | U+0051 | 51 | Latin Capital Letter Q |
| 82 | UPPERCASE R | R | U+0052 | 52 | Latin Capital Letter R |
| 83 | UPPERCASE S | S | U+0053 | 53 | Latin Capital Letter S |
| 84 | UPPERCASE T | T | U+0054 | 54 | Latin Capital Letter T |
| 85 | UPPERCASE U | U | U+0055 | 55 | Latin Capital Letter U |
| 86 | UPPERCASE V | V | U+0056 | 56 | Latin Capital Letter V |
| 87 | UPPERCASE W | W | U+0057 | 57 | Latin Capital Letter W |
| 88 | UPPERCASE X | X | U+0058 | 58 | Latin Capital Letter X |
| 89 | UPPERCASE Y | Y | U+0059 | 59 | Latin Capital Letter Y |
| 90 | UPPERCASE Z | Z | U+005A | 5A | Latin Capital Letter Z |
| 91 | LEFT SQUARE BRACKET | ⟦ | U+27E6 | E2 9F A6 | Mathematical Left White Square Bracket |
| 92 | REVERSE SOLIDUS | ⧷ | U+29F7 | E2 A7 B7 | Reverse Solidus With Horizontal Stroke |
| 93 | RIGHT SQUARE BRACKET | ⟧ | U+27E7 | E2 9F A7 | Mathematical Right White Square Bracket |
| 94 | CIRCUMFLEX ACCENT | ^ | U+005E | 5E | Circumflex Accent |
| 95 | LOW LINE | _ | U+005F | 5F | Low Line |
| 96 | GRAVE ACCENT | ˋ | U+02CB | CB 8B | Modifier Letter Grave Accent |
| 97 | LOWERCASE A | a | U+0061 | 61 | Latin Small Letter A |
| 98 | LOWERCASE B | b | U+0062 | 62 | Latin Small Letter B |
| 99 | LOWERCASE C | c | U+0063 | 63 | Latin Small Letter C |
| 100 | LOWERCASE D | d | U+0064 | 64 | Latin Small Letter D |
| 101 | LOWERCASE E | e | U+0065 | 65 | Latin Small Letter E |
| 102 | LOWERCASE F | f | U+0066 | 66 | Latin Small Letter F |
| 103 | LOWERCASE G | g | U+0067 | 67 | Latin Small Letter G |
| 104 | LOWERCASE H | h | U+0068 | 68 | Latin Small Letter H |
| 105 | LOWERCASE I | i | U+0069 | 69 | Latin Small Letter I |
| 106 | LOWERCASE J | j | U+006A | 6A | Latin Small Letter J |
| 107 | LOWERCASE K | k | U+006B | 6B | Latin Small Letter K |
| 108 | LOWERCASE L | l | U+006C | 6C | Latin Small Letter L |
| 109 | LOWERCASE M | m | U+006D | 6D | Latin Small Letter M |
| 110 | LOWERCASE N | n | U+006E | 6E | Latin Small Letter N |
| 111 | LOWERCASE O | o | U+006F | 6F | Latin Small Letter O |
| 112 | LOWERCASE P | p | U+0070 | 70 | Latin Small Letter P |
| 113 | LOWERCASE Q | q | U+0071 | 71 | Latin Small Letter Q |
| 114 | LOWERCASE R | r | U+0072 | 72 | Latin Small Letter R |
| 115 | LOWERCASE S | s | U+0073 | 73 | Latin Small Letter S |
| 116 | LOWERCASE T | t | U+0074 | 74 | Latin Small Letter T |
| 117 | LOWERCASE U | u | U+0075 | 75 | Latin Small Letter U |
| 118 | LOWERCASE V | v | U+0076 | 76 | Latin Small Letter V |
| 119 | LOWERCASE W | w | U+0077 | 77 | Latin Small Letter W |
| 120 | LOWERCASE X | x | U+0078 | 78 | Latin Small Letter X |
| 121 | LOWERCASE Y | y | U+0079 | 79 | Latin Small Letter Y |
| 122 | LOWERCASE Z | z | U+007A | 7A | Latin Small Letter Z |
| 123 | LEFT CURLY BRACKET | ❴ | U+2774 | E2 9D B4 | Medium Left Curly Bracket Ornament |
| 124 | VERTICAL LINE | ∣ | U+2223 | E2 88 A3 | Divides |
| 125 | RIGHT CURLY BRACKET | ❵ | U+2775 | E2 9D B5 | Medium Right Curly Bracket Ornament |
| 126 | TILDE | ˜ | U+02DC | CB 9C | Small Tilde |
| 127 | DEL | ⌦ | U+2326 | E2 8C A6 | Erase To The Right |
| 128 | — | ă | U+0103 | C4 83 | Latin Small Letter A With Breve |
| 129 | — | Ă | U+0102 | C4 82 | Latin Capital Letter A With Breve |
| 130 | — | Ǎ | U+01CD | C7 8D | Latin Capital Letter A With Caron |
| 131 | — | ǟ | U+01DF | C7 9F | Latin Small Letter A With Diaeresis And Macron |
| 132 | — | Ǟ | U+01DE | C7 9E | Latin Capital Letter A With Diaeresis And Macron |
| 133 | — | ȧ | U+0227 | C8 A7 | Latin Small Letter A With Dot Above |
| 134 | — | Ȧ | U+0226 | C8 A6 | Latin Capital Letter A With Dot Above |
| 135 | — | ǡ | U+01E1 | C7 A1 | Latin Small Letter A With Dot Above And Macron |
| 136 | — | ƀ | U+0180 | C6 80 | Latin Small Letter B With Stroke |
| 137 | — | Ƀ | U+0243 | C9 83 | Latin Capital Letter B With Stroke |
| 138 | — | Ɓ | U+0181 | C6 81 | Latin Capital Letter B With Hook |
| 139 | — | ƃ | U+0183 | C6 83 | Latin Small Letter B With Topbar |
| 140 | — | Ƃ | U+0182 | C6 82 | Latin Capital Letter B With Topbar |
| 141 | — | ć | U+0107 | C4 87 | Latin Small Letter C With Acute |
| 142 | — | Ć | U+0106 | C4 86 | Latin Capital Letter C With Acute |
| 143 | — | ĉ | U+0109 | C4 89 | Latin Small Letter C With Circumflex |
| 144 | — | Ĉ | U+0108 | C4 88 | Latin Capital Letter C With Circumflex |
| 145 | — | č | U+010D | C4 8D | Latin Small Letter C With Caron |
| 146 | — | Č | U+010C | C4 8C | Latin Capital Letter C With Caron |
| 147 | — | ċ | U+010B | C4 8B | Latin Small Letter C With Dot Above |
| 148 | — | Ċ | U+010A | C4 8A | Latin Capital Letter C With Dot Above |
| 149 | — | ď | U+010F | C4 8F | Latin Small Letter D With Caron |
| 150 | — | Ď | U+010E | C4 8E | Latin Capital Letter D With Caron |
| 151 | — | Đ | U+0110 | C4 90 | Latin Capital Letter D With Stroke |
| 152 | — | ȸ | U+0238 | C8 B8 | Latin Small Letter Db Digraph |
| 153 | — | Ɗ | U+018A | C6 8A | Latin Capital Letter D With Hook |
| 154 | — | ƌ | U+018C | C6 8C | Latin Small Letter D With Topbar |
| 155 | — | Ƌ | U+018B | C6 8B | Latin Capital Letter D With Topbar |
| 156 | — | ȡ | U+0221 | C8 A1 | Latin Small Letter D With Curl |
| 157 | — | ĕ | U+0115 | C4 95 | Latin Small Letter E With Breve |
| 158 | — | Ĕ | U+0114 | C4 94 | Latin Capital Letter E With Breve |
| 159 | — | Ě | U+011A | C4 9A | Latin Capital Letter E With Caron |
| 160 | — | ė | U+0117 | C4 97 | Latin Small Letter E With Dot Above |
| 161 | — | ȩ | U+0229 | C8 A9 | Latin Small Letter E With Cedilla |
| 162 | — | Ȩ | U+0228 | C8 A8 | Latin Capital Letter E With Cedilla |
| 163 | — | ƒ | U+0192 | C6 92 | Latin Small Letter F With Hook |
| 164 | — | Ƒ | U+0191 | C6 91 | Latin Capital Letter F With Hook |
| 165 | — | ǵ | U+01F5 | C7 B5 | Latin Small Letter G With Acute |
| 166 | — | Ǵ | U+01F4 | C7 B4 | Latin Capital Letter G With Acute |
| 167 | — | ğ | U+011F | C4 9F | Latin Small Letter G With Breve |
| 168 | — | Ğ | U+011E | C4 9E | Latin Capital Letter G With Breve |
| 169 | — | ǧ | U+01E7 | C7 A7 | Latin Small Letter G With Caron |
| 170 | — | Ǧ | U+01E6 | C7 A6 | Latin Capital Letter G With Caron |
| 171 | — | ḡ | U+1E21 | E1 B8 A1 | Latin Small Letter G With Macron |
| 172 | — | Ḡ | U+1E20 | E1 B8 A0 | Latin Capital Letter G With Macron |
| 173 | — | ĥ | U+0125 | C4 A5 | Latin Small Letter H With Circumflex |
| 174 | — | Ĥ | U+0124 | C4 A4 | Latin Capital Letter H With Circumflex |
| 175 | — | ȟ | U+021F | C8 9F | Latin Small Letter H With Caron |
| 176 | — | Ȟ | U+021E | C8 9E | Latin Capital Letter H With Caron |
| 177 | — | ƕ | U+0195 | C6 95 | Latin Small Letter Hv |
| 178 | — | Ƕ | U+01F6 | C7 B6 | Latin Capital Letter Hwair |
| 179 | — | ĭ | U+012D | C4 AD | Latin Small Letter I With Breve |
| 180 | — | Ĭ | U+012C | C4 AC | Latin Capital Letter I With Breve |
| 181 | — | Ǐ | U+01CF | C7 8F | Latin Capital Letter I With Caron |
| 182 | — | İ | U+0130 | C4 B0 | Latin Capital Letter I With Dot Above |
| 183 | — | ȉ | U+0209 | C8 89 | Latin Small Letter I With Double Grave |
| 184 | — | ȋ | U+020B | C8 8B | Latin Small Letter I With Inverted Breve |
| 185 | — | ĵ | U+0135 | C4 B5 | Latin Small Letter J With Circumflex |
| 186 | — | Ĵ | U+0134 | C4 B4 | Latin Capital Letter J With Circumflex |
| 187 | — | ǰ | U+01F0 | C7 B0 | Latin Small Letter J With Caron |
| 188 | — | ǩ | U+01E9 | C7 A9 | Latin Small Letter K With Caron |
| 189 | — | Ǩ | U+01E8 | C7 A8 | Latin Capital Letter K With Caron |
| 190 | — | ķ | U+0137 | C4 B7 | Latin Small Letter K With Cedilla |
| 191 | — | Ķ | U+0136 | C4 B6 | Latin Capital Letter K With Cedilla |
| 192 | — | ƙ | U+0199 | C6 99 | Latin Small Letter K With Hook |
| 193 | — | Ƙ | U+0198 | C6 98 | Latin Capital Letter K With Hook |
| 194 | — | ĺ | U+013A | C4 BA | Latin Small Letter L With Acute |
| 195 | — | Ĺ | U+0139 | C4 B9 | Latin Capital Letter L With Acute |
| 196 | — | ľ | U+013E | C4 BE | Latin Small Letter L With Caron |
| 197 | — | Ľ | U+013D | C4 BD | Latin Capital Letter L With Caron |
| 198 | — | ƚ | U+019A | C6 9A | Latin Small Letter L With Bar |
| 199 | — | Ƚ | U+023D | C8 BD | Latin Capital Letter L With Bar |
| 200 | — | Ń | U+0143 | C5 83 | Latin Capital Letter N With Acute |
| 201 | — | ǹ | U+01F9 | C7 B9 | Latin Small Letter N With Grave |
| 202 | — | Ň | U+0147 | C5 87 | Latin Capital Letter N With Caron |
| 203 | — | ņ | U+0146 | C5 86 | Latin Small Letter N With Cedilla |
| 204 | — | Ņ | U+0145 | C5 85 | Latin Capital Letter N With Cedilla |
| 205 | — | ȵ | U+0235 | C8 B5 | Latin Small Letter N With Curl |
| 206 | — | ŏ | U+014F | C5 8F | Latin Small Letter O With Breve |
| 207 | — | Ŏ | U+014E | C5 8E | Latin Capital Letter O With Breve |
| 208 | — | Ǒ | U+01D1 | C7 91 | Latin Capital Letter O With Caron |
| 209 | — | ȫ | U+022B | C8 AB | Latin Small Letter O With Diaeresis And Macron |
| 210 | — | Ȫ | U+022A | C8 AA | Latin Capital Letter O With Diaeresis And Macron |
| 211 | — | ȱ | U+0231 | C8 B1 | Latin Small Letter O With Dot Above And Macron |
| 212 | — | ƥ | U+01A5 | C6 A5 | Latin Small Letter P With Hook |
| 213 | — | Ƥ | U+01A4 | C6 A4 | Latin Capital Letter P With Hook |
| 214 | — | ȹ | U+0239 | C8 B9 | Latin Small Letter Qp Digraph |
| 215 | — | ɋ | U+024B | C9 8B | Latin Small Letter Q With Hook Tail |
| 216 | — | ŕ | U+0155 | C5 95 | Latin Small Letter R With Acute |
| 217 | — | Ŕ | U+0154 | C5 94 | Latin Capital Letter R With Acute |
| 218 | — | ř | U+0159 | C5 99 | Latin Small Letter R With Caron |
| 219 | — | Ř | U+0158 | C5 98 | Latin Capital Letter R With Caron |
| 220 | — | ŗ | U+0157 | C5 97 | Latin Small Letter R With Cedilla |
| 221 | — | Ŗ | U+0156 | C5 96 | Latin Capital Letter R With Cedilla |
| 222 | — | ś | U+015B | C5 9B | Latin Small Letter S With Acute |
| 223 | — | Ś | U+015A | C5 9A | Latin Capital Letter S With Acute |
| 224 | — | š | U+0161 | C5 A1 | Latin Small Letter S With Caron |
| 225 | — | Š | U+0160 | C5 A0 | Latin Capital Letter S With Caron |
| 226 | — | ş | U+015F | C5 9F | Latin Small Letter S With Cedilla |
| 227 | — | Ş | U+015E | C5 9E | Latin Capital Letter S With Cedilla |
| 228 | — | ť | U+0165 | C5 A5 | Latin Small Letter T With Caron |
| 229 | — | Ť | U+0164 | C5 A4 | Latin Capital Letter T With Caron |
| 230 | — | ţ | U+0163 | C5 A3 | Latin Small Letter T With Cedilla |
| 231 | — | Ţ | U+0162 | C5 A2 | Latin Capital Letter T With Cedilla |
| 232 | — | ț | U+021B | C8 9B | Latin Small Letter T With Comma Below |
| 233 | — | Ț | U+021A | C8 9A | Latin Capital Letter T With Comma Below |
| 234 | — | ŭ | U+016D | C5 AD | Latin Small Letter U With Breve |
| 235 | — | Ŭ | U+016C | C5 AC | Latin Capital Letter U With Breve |
| 236 | — | Ǔ | U+01D3 | C7 93 | Latin Capital Letter U With Caron |
| 237 | — | ű | U+0171 | C5 B1 | Latin Small Letter U With Double Acute |
| 238 | — | ȕ | U+0215 | C8 95 | Latin Small Letter U With Double Grave |
| 239 | — | Ʉ | U+0244 | C9 84 | Latin Capital Letter U Bar |
| 240 | — | Ṿ | U+1E7E | E1 B9 BE | Latin Capital Letter V With Dot Below |
| 241 | — | Ʋ | U+01B2 | C6 B2 | Latin Capital Letter V With Hook |
| 242 | — | ŵ | U+0175 | C5 B5 | Latin Small Letter W With Circumflex |
| 243 | — | Ŵ | U+0174 | C5 B4 | Latin Capital Letter W With Circumflex |
| 244 | — | ŷ | U+0177 | C5 B7 | Latin Small Letter Y With Circumflex |
| 245 | — | Ŷ | U+0176 | C5 B6 | Latin Capital Letter Y With Circumflex |
| 246 | — | Ÿ | U+0178 | C5 B8 | Latin Capital Letter Y With Diaeresis |
| 247 | — | ȳ | U+0233 | C8 B3 | Latin Small Letter Y With Macron |
| 248 | — | ƴ | U+01B4 | C6 B4 | Latin Small Letter Y With Hook |
| 249 | — | Ƴ | U+01B3 | C6 B3 | Latin Capital Letter Y With Hook |
| 250 | — | ź | U+017A | C5 BA | Latin Small Letter Z With Acute |
| 251 | — | Ź | U+0179 | C5 B9 | Latin Capital Letter Z With Acute |
| 252 | — | ž | U+017E | C5 BE | Latin Small Letter Z With Caron |
| 253 | — | Ž | U+017D | C5 BD | Latin Capital Letter Z With Caron |
| 254 | — | ż | U+017C | C5 BC | Latin Small Letter Z With Dot Above |
| 255 | — | Ż | U+017B | C5 BB | Latin Capital Letter Z With Dot Above |

This implementation uses a carefully chosen set of UTF-8 characters to represent each possible byte value:

- Control characters (0-31) use visually distinct symbols, primarily from Unicode blocks like Mathematical Symbols, Arrows, and Latin Extended
- Standard printable ASCII characters (33-126, except ", ', and \\) remain themselves
- Special characters (space, double quote, single quote, backslash) get more visible representations
- Extended bytes (128-255) are driven by `character_map.txt` and ordered alphabetically to keep neighbouring glyphs visually related

### Encoding/Decoding Maps

The implementation builds two lookup tables at initialization:

- `encode_map`: Maps byte values (0-255) to their UTF-8 string representations
- `decode_map`: Maps UTF-8 string representations back to byte values

These bidirectional maps ensure efficient and accurate conversion in both directions.

## License

This project is licensed under the MIT License - see the LICENSE file for details.
