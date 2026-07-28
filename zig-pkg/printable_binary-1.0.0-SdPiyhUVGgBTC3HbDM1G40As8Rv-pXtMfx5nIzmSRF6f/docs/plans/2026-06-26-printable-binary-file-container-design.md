# Design: printable-binary-file.json container + web decode workflow

**Date:** 2026-06-26
**Issue:** https://github.com/pmarreck/printable_binary/issues/1
**Status:** DRAFT — awaiting Peter's spec sign-off (forks 1–4 ruled by Einstein
2026-06-26; see inbox/processed/2026-06-26-RULING-issue-1-forks.md)

## Problem
The browser demo bills itself "Encoder/Decoder" but (a) offers **no clear
DECODE workflow** — you can only decode by drag-dropping a `.pbt` file; there is
no way to paste a printable-binary block and get a binary back — and (b) has
**no way to preserve/restore file metadata** (filename, perms, owner/group,
timestamps). Encoding `foo.png` yields `foo.png.pbt` and discards everything
else.

## Resolved decisions (Einstein ruling, on Peter's behalf)
1. **Architecture = A2.** The JSON envelope is a documented *schema* (the single
   source of truth). The only *algorithms* — the existing bytes↔glyphs codec and
   the new CRC-32 — live in the Zig core and are reached through the C FFI. Each
   consumer (C CLI in C, web demo in JS) assembles/parses the trivial flat-dict
   envelope with its native JSON facilities. Cross-impl agreement is guaranteed
   by a **differential test** (container built by C decodes in JS and vice
   versa) plus **CRC vector-pinning** — not by routing JSON through WASM.
2. **Checksum = CRC-32/ISO-HDLC** (the zip/gzip/png CRC; reflected, poly
   `0xEDB88320`, init/xorout `0xFFFFFFFF`). Vector-pinned:
   `CRC32("123456789") == 0xCBF43926`.
3. **On-disk name = `<originalname>.pbf.json`** (e.g. `photo.png.pbf.json`).
   Keeps the name+ext visible, gives editors/jq a `.json` affordance, `.pbf`
   marks it. The authoritative filename round-trips inside the `filename` key.
4. **Web UX = deferred, non-blocking.** Does not gate core/CLI. At the web gate,
   mock BOTH an explicit Encode/Decode affordance AND an auto-detect+paste-box,
   and let Peter pick — biasing toward making decode *obvious* (the issue's real
   complaint is discoverability).

Minors: `snake_case` keys; CRC fields are lowercase 8-hex strings; the container
is **additive** — the raw `.pbt` encode/decode flow stays; the container is a
NEW option, not a replacement.

## Container schema v1 (`printable-binary-file`)
```json
{
  "format": "printable-binary-file",
  "version": 1,
  "filename": "photo.png",
  "byte_length": 12345,
  "crc32": "cbf43926",
  "crc32_encoded": "1a2b3c4d",
  "modified_ms": 1719430000000,
  "created_ms": 1719420000000,
  "mode": "0644",
  "owner": "pmarreck",
  "group": "staff",
  "data": "<printable-binary-encoded string>"
}
```

Serialized with `data` LAST so all metadata sits up front (JS object key order
is insertion order). `created_ms` is birthtime — populated by the CLI (which can
`stat` it); browsers expose only `lastModified` (-> `modified_ms`), so the web
encoder omits `created_ms` (the web decoder still shows it when a CLI-made
container carries it).

### Field semantics
| key            | type    | required | meaning |
|----------------|---------|----------|---------|
| `format`       | string  | yes      | literal `"printable-binary-file"` (format discriminator) |
| `version`      | number  | yes      | schema version (1) |
| `filename`     | string  | yes      | original base filename (authoritative; restored on decode) |
| `data`         | string  | yes      | the printable-binary-encoded original bytes |
| `byte_length`  | number  | yes      | length in bytes of the ORIGINAL (decoded) data |
| `crc32`        | string  | yes      | CRC-32 of the ORIGINAL bytes, lowercase 8-hex |
| `crc32_encoded`| string  | opt      | CRC-32 of the UTF-8 bytes of the `data` string |
| `modified_ms`  | number  | opt      | mtime, integer ms since Unix epoch (UTC) |
| `created_ms`   | number  | opt      | birthtime, ms since epoch (omit if unavailable) |
| `mode`         | string  | opt      | POSIX permission bits as octal string, e.g. `"0644"` |
| `owner`        | string  | opt      | owner username (POSIX) |
| `group`        | string  | opt      | group name (POSIX) |

### Cross-platform rule
POSIX-only fields (`mode`, `owner`, `group`) and `created_ms` are **omitted when
unavailable** (Windows, browser). **Decode MUST tolerate any missing optional
field and never fail because one is absent.** The browser File API yields only
`name`, `size`, and `lastModified` (ms) — so the web demo populates `filename`,
`byte_length`, `modified_ms`, `crc32` (and `crc32_encoded`), omitting the rest.

### Self-verification semantics (decode)
- If `crc32_encoded` is present, verify it against the UTF-8 bytes of `data`
  BEFORE decoding (catches transport corruption of the JSON/`data` itself).
- After decoding `data` → bytes, recompute CRC-32 and compare to `crc32`;
  recompute length and compare to `byte_length`.
- A mismatch is a hard error in the CLI (non-zero exit, message to stderr) and a
  clear error in the web UI. (No silent acceptance of corrupted round-trips.)

## Architecture / where each piece lives
- **Zig core (`src/zig/printable_binary.zig`)**
  - Existing: `pb_encode` / `pb_decode` (the codec) — unchanged, reused.
  - NEW `pb_crc32(input: ?[*]const u8, len: usize) -> u32` exported
    `callconv(.c)`. Pure, no I/O. Table-driven CRC-32/ISO-HDLC.
- **C FFI header (`src/printable_binary.h`)**: declare `uint32_t pb_crc32(const
  char*, size_t);`.
- **C CLI (`src/printable_binary.c` + FFI CLI)**: a verb/flag to EMIT a container
  (`--to-file-json` / read file+stat → assemble JSON) and to CONSUME one
  (`--from-file-json` / parse JSON → write bytes + restore metadata). Honors
  `-`/`@stdin`/`@stdout`. Names exact flags during implementation (kept Unix +
  Windows-alias-friendly per CLI conventions).
- **JS (`js/printable_binary.js`)**: container assemble/parse methods + a JS
  CRC-32 (vector-pinned to the same constant) used by the web demo.
- **No new format logic in WASM**; the web demo stays pure-JS.

## CRC-32 detail (to avoid impl drift)
CRC-32/ISO-HDLC, reflected input/output, polynomial `0xEDB88320` (reflected
`0x04C11DB7`), init `0xFFFFFFFF`, final xor `0xFFFFFFFF`. Both the Zig and JS
implementations are unit-tested against published vectors:
`""` → `0x00000000`, `"123456789"` → `0xCBF43926`, `"a"` → `0xE8B7BE43`. Because
both are pinned to the SAME published oracle, authorship is irrelevant and they
cannot silently disagree (MFIC: external oracle).

## TDD oracle / test plan (write tests FIRST)
1. **CRC-32 vectors** (Zig unit + JS): the published vectors above. RED first.
2. **Container round-trip** (the primary MFIC inverse-pair oracle):
   `decode(encode(bytes, meta)) == (bytes, meta)` — byte-identical `data` AND
   identical metadata (modulo platform-omitted fields). RED first.
3. **Self-verify negative tests**: flip a byte in `data`, or corrupt a CRC
   field, → decode errors (proves the check isn't vacuous).
4. **Cross-impl differential** (added to `test/test_cross_implementation.sh`):
   a container emitted by the C CLI decodes correctly in JS, and a
   JS/Node-emitted container decodes correctly via the C CLI — byte + metadata
   identical. External oracle against envelope drift.
5. **Missing-optional-field tolerance**: a container with only the required
   fields decodes cleanly (no POSIX fields) — proves cross-platform tolerance.

## Non-goals (YAGNI)
- No cryptographic/tamper-evidence hashing (CRC-32 is transport-integrity only).
- No compression (the codec is the codec; container just wraps it).
- No multi-file/archive container (single file per container in v1).
- No restoration of owner/group/mode by the *web* demo (browser can't set them);
  it restores filename + mtime where the download mechanism allows.

## Build order
core CRC-32 (+FFI) → container codec + round-trip oracle → CLI verb → cross-impl
differential → web UI (after Peter picks the mockup). Ping Einstein at the core
and CLI milestones.

## Web-UI mockups (for Peter's pick — the one hard gate)
The issue's core complaint is "no CLEAR way to decode." Both options add a paste
box + a metadata panel; they differ in how the decode path is surfaced. (Text
mockups — I can't see rendered output; Peter picks, then I build.)

### Option A — Explicit Encode / Decode tabs (Einstein's lean: most discoverable)
```
        ┌ ▶ ENCODE ┐ ┌  DECODE  ┐      <- mode tabs (decode is now obvious)
ENCODE: [ drop a file / click to choose ]
        output:  ( ) plain text   (*) .pbf.json container
                 (keeps filename, dates, perms + self-check crc32)
        [ Copy ] [ Download photo.png.pbf.json ] [ Clear ]

DECODE: paste encoded text OR a .pbf.json container:
        [ ............................................ ]
              ...or drop a .pbt / .pbf.json file
        ┌ Detected: printable-binary-file container ─────┐
        │ name: photo.png   12.3 KB   modified 2026-06-20 │
        │ mode 0644   integrity: ✓ crc32 verified          │
        └─────────────────────────────────────────────────┘
        [ Download photo.png ] [ Clear ]
```

### Option B — Auto-detect, single unified surface (fewer clicks; decode implicit)
```
Drop a file or paste below — auto-detects ENCODE vs DECODE.
[ drop a file / click to choose ]
──────────────── or paste ────────────────
[ raw text, printable-binary, or a .pbf.json container ............ ]
┌ Auto-detected: .pbf.json container -> DECODE ────────┐
│ -> photo.png · 12.3 KB · modified 2026-06-20          │
│ integrity ✓ crc32 verified                            │
└───────────────────────────────────────────────────────┘
(other states: "plain bytes -> ENCODE", "printable-binary -> DECODE")
[ Copy ] [ Download ] [ Clear ]
```

**Recommendation:** A — it makes decode unmistakable (directly answers the
issue), and the metadata panel + container option are equally expressible in B.
Awaiting Peter's pick before building index.html.

## Transport resistance (whitespace) — added 2026-06-27
The container must survive being pasted into email bodies / reflowed by text
transports that inject whitespace. Empirically (test/js + test/test_container):
- Whitespace BETWEEN JSON tokens (reindent, CRLF, trailing spaces) was always
  fine — `JSON.parse` ignores it.
- Whitespace landing INSIDE `data` originally broke decode two ways, both fixed:
  1. **strict `crc32_encoded`** rejected any byte change, even whitespace the
     glyph payload is indifferent to → **fix:** `crc32_encoded` is computed over
     the *canonical* payload (data with `[\r\n\t ]` stripped). The default
     encoding emits none of those, so clean containers' checksum is UNCHANGED
     (backward-compatible); only transport-injected whitespace is tolerated.
  2. **JSON forbids a raw newline inside a string** (a hard line-wrap of the long
     `data` line) → **fix:** a lenient parse — on `JSON.parse` failure, strip raw
     control whitespace (`[\r\n\t]`, never legitimate in our metadata strings or
     the glyph payload) and retry.
- Decode strips the canonical whitespace from `data` before `decode()` (default
  decode does NOT ignore whitespace; that is opt-in `-S`). **Integrity is intact:
  a genuine non-whitespace corruption is still rejected** (crc32 of the original
  bytes, checked post-decode).

**Required of EVERY impl** (the "all executables" goal): canonicalize the payload
(`strip [\r\n\t ]`) for the `crc32_encoded` check + before decoding, and parse
leniently (hand-rolled C/Lua parsers get this free by skipping whitespace while
scanning `data`; strict parsers like JS `JSON.parse` / Zig `std.json` need the
strip-and-retry fallback). `test/test_container` enforces this per impl.
