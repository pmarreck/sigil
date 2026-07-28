# Design: arbitrary metadata injection into `.pbf.json` containers

**Date:** 2026-07-21
**Status:** DESIGN COMPLETE — approved by Peter (all forks ruled); NOT yet
implemented. Future nice-to-have. Implement TDD-first (Lua reference → port to
the other four container surfaces).
**Depends on:** the `.pbf.json` container (`-C`/`--container`), shipped in
`feat(container)` commit `ac5712a` and its predecessors.
**Related:** [`2026-06-26-printable-binary-file-container-design.md`](2026-06-26-printable-binary-file-container-design.md)
(container v1 schema + transport-resistance).

## Problem / motivation

The container carries a fixed set of fields (filename, crc32s, optional
POSIX/timestamp/mime metadata). Users want to attach **arbitrary** key/value
metadata to a file's container — provenance, source id, a routing hint, a
content-type override — so that **other tooling can read it first**, before (or
instead of) decoding the payload. This is the container analogue of extended
attributes (xattrs) or HTTP `X-` headers: out-of-band annotation.

Because the decoder already ignores unknown keys (it only reads keys it knows),
adding arbitrary keys is forward-compatible for free — the whole feature is
additive and never breaks an existing decoder.

## CLI grammar (container mode only)

Three input forms, all producing `(namespace, key, value)` entries:

- `--kv "KEY:VALUE"` — canonical, self-contained form.
- `-k KEY -v VALUE` — sugar for one pair. `-k` must **precede** its `-v`
  (one pending pair at a time). Repeatable.
- `--key-namespace NAME` — see *Namespaces* below.

### `--kv` parsing rules

1. Trim leading whitespace.
2. **Key:** if the string starts with `"`, the key is the text up to the next
   unescaped `"` (so a quoted key may itself contain `:`); otherwise the key is
   the text up to the **first `:`**.
3. Expect a `:` next (after optional surrounding whitespace); missing → error.
4. Trim optional whitespace after the `:`.
5. **Value:** the remainder. If it starts and ends with `"`, strip the wrapping
   quotes.
6. In any quoted key or value, unescape `\"` → `"` and `\\` → `\`.

Colon-in-**value** is free (first-colon split): `--kv "url:https://x"` →
`url` = `https://x`. Colon-in-**key** requires quoting the key, or using
`-k/-v` (the escape hatch).

All of these are equivalent and set `author` = `Ada Lovelace`:

```
-k author -v "Ada Lovelace"
--kv "author:Ada Lovelace"
--kv "author: Ada Lovelace"        # optional space after ':'
--kv 'author:"Ada Lovelace"'       # quoted value
--kv "author:\"Ada Lovelace\""     # escaped-quote value
--kv '"author":"Ada Lovelace"'     # quoted key + value
```

### Namespaces (stateful / positional)

`--key-namespace NAME` sets the **current namespace** for every pair that
**follows** it, until the next `--key-namespace`. Pairs before any
`--key-namespace` go **top-level**. This is a deliberate exception to the
"named flags parse in any order" convention — the injection flags
(`-k`/`-v`/`--kv`/`--key-namespace`) form an **ordered stream**.

Multiple namespaces are allowed and accumulate into their own buckets. Repeating
the same NAME continues appending to that bucket.

```
-k a -v 1 \
--key-namespace meta  -k b -v 2  --kv "c:3" \
--key-namespace other -k d -v 4
# a  -> top-level
# b,c -> under "meta"
# d  -> under "other"
```

## Resolved design decisions

### 1. Placement (Peter's ruling: let the user decide)

- **Default (no namespace):** pairs become **top-level** container keys.
- **With `--key-namespace NAME`:** pairs nest under `container[NAME]` (an
  object). Nesting isolates the pair keys, so under a namespace a pair key may be
  anything (even `crc32`) without shadowing anything.

### 2. Reserved-key set (Peter's ruling ①: structural/integrity only)

Reject an injected **top-level** key, or a `--key-namespace NAME`, iff it is one
of the **7 structural/integrity keys**:

```
format  version  filename  byte_length  crc32  crc32_encoded  data
```

Rationale: these are the only keys whose presence changes decode behavior or
integrity, so a user key must never shadow them. Everything else —
`mime`, `mode`, `owner`, `group`, `modified_ms`, `created_ms`, and any novel
key — is user-settable. Notably `-k mime -v image/png` is **allowed** and
**overrides** an auto-detected value (see *Emission*).

The reserved list is an **MFIC contract**: the identical 7-key list lives in all
5 implementations; a cross-impl test asserts `-k crc32 …` (and
`--key-namespace data`) error on **every** surface.

### 3. Value type: always a JSON string

Every injected value is emitted as a JSON string (properly escaped). No typed /
numeric / boolean / raw-JSON values (YAGNI). `-k count -v 42` → `"count": "42"`.

### 4. Integrity (Peter's ruling ②: unverified annotation)

Injected metadata is **not** covered by `crc32` (original bytes) nor
`crc32_encoded` (payload). It is carried as-is, like an HTTP `X-` header — a
transport could alter it without tripping the integrity checks. This is
documented and intentional; the field is a *hint for other tooling*, not
verified content. (Covering it would require a canonicalization contract + a new
`crc32_meta` schema field across all 5 impls — rejected as over-engineering for a
hint.)

### 5. Emission order & dedupe

Container key order (the existing invariant: **`data` is always last** so
metadata reads up front):

```
format, version, filename, byte_length, crc32, crc32_encoded,
  <auto metadata: mime/mode/owner/group/timestamps, where the impl emits them>,
  <top-level injected pairs, in CLI order>,
  <namespace objects, in first-appearance order>,
  data
```

Dedupe rules (keep valid JSON — no duplicate keys):
- A top-level injected key that matches a same-named **auto** key **overrides**
  it (only Node currently auto-emits `mime`/`mode`/… so only Node needs the
  merge; Lua/C/Zig auto-emit only `filename`, which is reserved, so no non-reserved
  collision is possible there).
- Duplicate injected key **within the same bucket** (top-level or a given
  namespace) → **last value wins** (Peter's "later overrides earlier" rule).
- A `--key-namespace NAME` shares the top-level key space with top-level injected
  keys; on collision, last-wins at emit (rare; not worth a dedicated error).

### 6. Guards (hard errors, nonzero exit)

- Any of `-k`/`-v`/`--kv`/`--key-namespace` **without `-C`** → error (meaningless
  off-container).
- `-k` with no following `-v` (pending key at end of args, or two `-k` in a row)
  → error.
- Reserved top-level key or reserved `--key-namespace NAME` → error (decision 2).

### 7. Decode: unchanged

Decode reads only the keys it knows; injected/unknown keys (top-level or nested)
are **ignored** and never required. Injected metadata is therefore **not**
round-tripped through a decode — it lives in the container JSON for other tooling
to read, and a decode reconstructs only the original file bytes.

## Schema examples

Top-level (default):

```json
{
  "format": "printable-binary-file",
  "version": 1,
  "filename": "reading.csv",
  "byte_length": 2048,
  "crc32": "b4ccfa4a",
  "crc32_encoded": "7fbf27bb",
  "author": "Ada Lovelace",
  "source": "sensor-7",
  "data": "…"
}
```

Namespaced (`--key-namespace provenance …`):

```json
{
  "format": "printable-binary-file",
  "version": 1,
  "filename": "reading.csv",
  "byte_length": 2048,
  "crc32": "b4ccfa4a",
  "crc32_encoded": "7fbf27bb",
  "provenance": { "author": "Ada Lovelace", "source": "sensor-7" },
  "data": "…"
}
```

## Cross-implementation scope

Five container surfaces, each already exercised by the parameterized
`test/test_container` (run per-impl via the flake `test-container-*` checks):

| Surface        | File(s)                                   | Notes |
|----------------|-------------------------------------------|-------|
| Lua (reference)| `bin/printable-binary-luajit`             | implement first |
| Node           | `bin/printable-binary-node.js`, `js/printable_binary.js` | only impl with auto `mime`/`mode`/… → needs the override-merge |
| Zig            | `src/zig/main.zig` (container in the CLI, not the core) | manual JSON string build |
| standalone C   | `src/printable_binary.c` + `src/container_json.h` | array `preserve_chars` |
| FFI C          | `src/printable_binary_ffi_main.c` + `src/container_json.h` | `preserve_chars` is a `char *` (NULL-check!) — see the ac5712a NULL-deref lesson |

Shared JSON helpers live in `src/container_json.h` (both C surfaces) — add a
JSON-string emit + escape helper there if not already present (`cj_fputs_escaped`
exists for values).

## TDD test plan (write FIRST, in `test/test_container`; red before green)

Derive any impl-specific glyphs from the impl under test (as the `--spaces`
ambiguity test does), never hardcode. Concrete cases:

1. **Top-level, `-k/-v`:** `-C -k author -v Ada file` → container has
   `"author": "Ada"` at top level; round-trip still recovers bytes.
2. **`--kv` split + optional space:** `--kv "source: sensor-7"` →
   `"source": "sensor-7"`.
3. **Quoted value / escaped value / quoted key** — all four grammar variants
   above → identical `author` = `Ada Lovelace`.
4. **Colon in value:** `--kv "url:https://x"` → value `https://x`.
5. **Namespace:** `--key-namespace provenance -k author -v Ada` →
   `"provenance": { "author": "Ada" }`, and NO top-level `author`.
6. **Multi-namespace routing:** `-k a -v 1 --key-namespace m -k b -v 2
   --key-namespace n -k c -v 3` → `a` top-level, `b` under `m`, `c` under `n`.
7. **Last-wins:** `-k k -v 1 -k k -v 2` → `"k": "2"`.
8. **mime override (Node):** `-k mime -v text/plain` on a file Node would
   auto-detect → exactly one `mime`, value `text/plain`.
9. **Reserved rejection:** `-k crc32 -v deadbeef` → nonzero exit, error names the
   reserved key; likewise `--key-namespace data`.
10. **Off-container guard:** `-k a -v 1` **without** `-C` → nonzero exit.
11. **Dangling key guard:** `-C -k a file` (no `-v`) → nonzero exit.
12. **Decode ignores unknown:** decode a container carrying injected top-level +
    namespaced keys → still yields original bytes (unknown keys ignored).

## Non-goals / future considerations (YAGNI now)

- **Typed values** (numbers, booleans, nested JSON) — strings only for now.
- **Verifying** injected metadata with a crc — see decision 4.
- **Reading/printing** injected metadata on decode (e.g. a `--show-meta` flag) —
  out of scope; other tooling reads the JSON directly.
- **Windows `/k` `/v` `/kv` aliases** and **i18n'd flag aliases** — follow the
  project CLI conventions when implemented, but not part of the MVP surface.
- **Quote-aware colon-in-key** is supported (rule 2); deeper quoting/escaping
  (single quotes, backslash-escaped colons outside quotes) is not — use `-k/-v`.
