# sigil — design notes (captured 2026-07-27, not yet built)

A signed-document verifier. Peter picked the name; Mecha Validate and Mecha
Rotshield both need offline license verification, so it must be **shared** and
must not live inside either product.

## Envelope (Peter's design, 2026-07-27)

```json
{"data":"<printable-binary of the payload bytes>",
 "sigtype":"Ed25519",
 "sig":"<printable-binary of the raw signature>"}
```

**The signature covers the DECODED `data` bytes — never the JSON.** That is the
whole trick, and it is the right one: the JSON envelope may be reformatted,
re-ordered, pretty-printed, or have whitespace inserted, and verification still
holds. JSON is pure transport.

Verify path: parse JSON → take `data` string → printable-binary decode → verify
Ed25519 over exactly those bytes → only then parse the payload.

### Why printable-binary rather than base64

Not just dogfooding. printable-binary **preserves legible ASCII**, so a mostly
ASCII payload (TOML) stays human-scannable rather than becoming an opaque blob.
That is the actual differentiator of this format — see prior art below.

## The genericity decision: sigil MUST NOT canonicalize

Making sigil generic is nearly free **provided it never re-serializes anything**.
Its contract is: *sign and verify exactly the bytes handed to it.*

Consequences:

- Canonical ordering becomes the **caller's** responsibility, not sigil's.
- No collation dependency — **including for licensing**. The generator emits
  sorted TOML once, sigil signs those bytes, the verifier decodes and checks.
  Nothing ever re-sorts, so there is nothing to disagree about.
- Add a `datatype` field (`toml` / `json` / `octet-stream`) purely as a label
  for the consuming application.

**Dependency asymmetry that settles it:** the verifier ships to customers and
gets embedded in two products; the generator runs on Peter's machine. Keep the
verifier's dependency budget at ~zero (`std.crypto.sign.Ed25519` and a byte
compare). Use `collation_mf_do_you_speak_it` in the generator if desired.

If sigil ever *does* need to canonicalize, `collation_mf_do_you_speak_it`
(reproducible, locale-independent, versioned ordering) is the right tool and
Peter already owns it.

## Prior art — know this before positioning

- **JWS/JWT** — the incumbent, and **it already uses this exact trick**: signs
  `base64url(header).base64url(payload)` and verifies over those bytes,
  specifically to dodge JSON canonicalization. Peter's insight is correct but
  not novel. Do not claim novelty for the envelope idea.
- **PASETO** — explicitly the anti-JWT; `v4.public` is Ed25519. Closest
  conceptual competitor.
- **minisign** / **signify** (OpenBSD) — tiny Ed25519 file signing. Closest
  tooling competitors.
- **RFC 8785 (JSON Canonicalization Scheme)** — the standards-track answer this
  design routes around.
- Commercial licensing: Keygen.sh, Cryptlex, LicenseSpring.

**Position on readability and simplicity, not on the envelope.** The honest
pitch: human-scannable payload, safe for arbitrary binary (including embedded
JSON), immune to whitespace / CRLF / quoting / re-formatting, still trivially
parseable as plain JSON, zero-dependency verifier.

Cross-promotes `printable_binary` and (optionally) `collation_mf_do_you_speak_it`.

## Payload v1 — deliberately minimal

Keys `[a-z0-9_]+`, values UTF-8 strings, **the application interprets them**.
Byte order is the only ordering, which is unambiguous by construction because
Peter generates every key.

```toml
email = "..."
issued = "2026-07-27"
max_major = "1"
order = "pdl_01J8XYZ"
product = "mecha-validate"
v = "1"
```

`max_major` makes the commercial rule (same major = free upgrade, major bump =
paid) a property of the data rather than server logic.

**Explicitly NOT doing yet (agreed over-engineering):** a schema/type system
(`integer`/`decimal`/`printable-binary` typed values with validation regexes).
Add when a second consumer actually needs it; it will be additive via `v=2`, not
a rewrite. If money ever enters a payload, use integer minor-units, never float.

## Open question

Revocation. Offline verification cannot revoke. Options: short-dated licenses,
an opportunistically-fetched revocation list, or accept no revocation (what most
indie desktop software does). Decide deliberately rather than by default.

## Build shape (Peter's standard)

Zig core (pure, no I/O) → C FFI → C CLI dogfooding the FFI. Scaffold via the
`scaffold-zig-project` skill. First test should be the verifier: sign a known
payload, verify it, then flip one byte and assert rejection.
