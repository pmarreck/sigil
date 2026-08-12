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

**The signature is verified over the DECODED `data` bytes (as the payload of
the signing transcript below) — never over the JSON.** That is the
whole trick, and it is the right one: the JSON envelope may be reformatted,
re-ordered, pretty-printed, or have whitespace inserted, and verification still
holds. JSON is pure transport.

Verify path: parse JSON → take `data` string → printable-binary decode → build
the signing transcript → verify Ed25519 over it → only then parse the payload.

## The signing transcript — decided 2026-08-11 (Peter)

Peter asked for the signing method to be identified in the certificate for
futureproofing, and chose binding it **inside the signed bytes**. What gets
signed is therefore no longer the bare payload:

```
transcript = DOMAIN ‖ u8(alg_id) ‖ u64be(payload_len) ‖ payload
```

| Field | Width | Value |
|---|---|---|
| `DOMAIN` | 19 bytes, fixed ASCII | `sigil.transcript.v1` |
| `alg_id` | 1 byte | `1` = Ed25519. `0` is reserved and never valid. |
| `payload_len` | 8 bytes, big-endian | `payload.len` |
| `payload` | `payload_len` bytes | **verbatim, never transformed** |

**THE INVARIANT still holds, in the sense that mattered.** The payload bytes are
copied in untouched — not canonicalized, re-ordered or re-serialized — so the
JSON envelope may still be reformatted freely, and sigil still needs no JCS, no
collation and no locale. What changed is that the signature now covers a header
as well as the payload. That is the trade Peter chose, and it was free to make
only because no license had been issued yet.

**Why each field is shaped this way** — every one of these is a known way that
hand-rolled signing formats break:

- **Fixed-width everything, plus an explicit length.** The encoding is
  *injective*: given a transcript you can recover `(alg_id, payload)` uniquely,
  so no two distinct inputs can ever produce the same signed bytes. Length
  prefixes are not decoration; without one, appending a field in a future
  version would make the payload boundary ambiguous, and ambiguity in a signed
  encoding is a forgery primitive.
- **`u64be` rather than a varint.** Fixed width cannot be encoded two ways. A
  varint can (`0x00` vs `0x80 0x00`), and "two encodings of one value" is
  exactly the door this design closes.
- **The version lives in `DOMAIN`, not in a separate field.** Bumping to
  `sigil.transcript.v2` changes the domain string, so a v1 signature can never
  be replayed as v2. Domain separation and versioning are the same mechanism.
- **`DOMAIN` is a fixed prefix.** A signature over raw bytes — the pre-2026-08-11
  format, a JWT, any other protocol — is not a valid sigil signature unless
  those bytes happen to begin with `sigil.transcript.v1` and carry a matching
  length. Cross-protocol replay is foreclosed by construction.
- **The public key needs no binding here.** RFC 8032 already includes `A` in the
  challenge hash, so key-substitution is covered by Ed25519 itself.

**`alg_id` is bound, but the verifier still pins it.** Binding stops a signature
made under one algorithm from being replayed as another once a second algorithm
exists. It does *not* license reading the algorithm out of the document: the
verifier compares against its own configured value and never selects from
attacker-controlled input. Both halves are needed, and the second is the one
that keeps `sigtype` harmless.

`sigtype` in the envelope remains **unauthenticated and advisory** — an attacker
may rewrite it freely and it exists only to turn a bare "BadSignature" into a
message that says what went wrong. It is no longer load-bearing for anything,
because the authoritative algorithm identifier now lives inside the signature.

**Key rotation: deliberately absent (Peter, 2026-08-11).** The envelope carries
no `kid`. Each app embeds exactly one public key for its own product, per the
release plan. Choosing a key by an identifier read from the document would mean
parsing before verifying, which is the one thing this module's types exist to
prevent. A compromised key is handled by shipping an app update — which the
revocation design already requires on any version change.

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

**Authority:** `Obsidian Vaults/Peter Marreck/Professional/Mecha LLC/MECHA_RELEASE_PLAN.md`,
"License key model". sigil's earlier examples predated that document and used
different names for the same concepts; Peter's call (2026-07-30) is that the
spec's names win. This matters more than it looks: sigil signs exact bytes, so
renaming a key after license #1 is issued means a legacy parse path forever, or
reissuing every license.

```toml
customer_email = "peter@example.com"
customer_name_canonical = "peter marreck"
expiry = "2027-07-30"          # optional for a sale; REQUIRED for a beta token
features = "repair,batch"      # additive; absent means base tier
max_major = "1"
offline_days = "365"
payment_provider = "paddle"
payment_ref = "txn_01J8XYZ"
product = "mecha-validate"
purchase_date = "2026-07-30"
v = "1"
```

Renamed from sigil's placeholder examples: `email` → `customer_email`,
`issued` → `purchase_date`, `order` → the payment pair below. Added:
`customer_name_canonical`, which the spec requires for activation-time identity
matching (the user types email *and* name; the app checks both against the
token's canonical form — lowercase, punctuation stripped, whitespace collapsed).

**One deliberate deviation from the spec, at Peter's prompting.** The spec says
`paddle_transaction_id`. Paddle is a vendor, not a domain concept, and Paddle
Billing already forced one rethink by not issuing license keys at all — so
naming a signed, immutable field after it is a bet. But a generic
`payment_provider_transaction_id` loses something real: after a migration, old
licenses genuinely *do* hold Paddle references, and a generic name would make a
Stripe ID and a Paddle ID indistinguishable.

Both concerns are satisfied by moving the vendor out of the key and into a
value:

```toml
payment_provider = "paddle"
payment_ref = "txn_01J8XYZ"
```

The key names never need to change; provenance is recorded per license, so a
2026 token still says `paddle` and a 2028 one says whatever replaced it; and
nothing is ever mislabeled. Two short keys instead of one long inaccurate one.

`offline_days` is data rather than a constant in two codebases so the window can
be widened for a customer with a genuinely air-gapped machine without shipping a
new build. See the revocation section below for what consumes it.

## `features` — decided 2026-08-04 (Peter)

`features` is the entitlement lever for the capability tiers (detection always
free; repair/creation license-gated). I argued it was speculative generality,
on the grounds that every axis that varied between two licenses was already
carried by `product`, `max_major` and `expiry`. That was wrong: **a Pro upgrade
is the same SKU with a different capability set**, and no other field can
express two customers of the *same* product getting different capabilities.

Shape: a comma-separated list of names in one value, no spaces.

```toml
features = "repair,batch"
```

sigil neither parses nor enforces this — it signs opaque bytes. The rules below
are for the apps, and each one is a way this class of check normally goes wrong:

- **Additive allowlist only.** The app asks "does this token grant `X`?" and
  grants nothing it does not recognize. Never a denylist, never "everything
  except". An allowlist query fails closed on an unknown name for free; a
  denylist fails open on every name nobody thought to add.
- **Absent means base tier.** Every license issued before a feature name exists
  must keep working, and must *not* acquire that feature the day the build that
  knows the name ships. This is the one that bites in practice: today's tokens
  have no `features` key at all, so "missing → grant everything" would hand the
  entire existing customer base a free Pro upgrade on release day.
- **Whole-name match.** Names match as whole list elements, never as
  substrings — `pro` must not match inside `no-pro-trial`, and `repair` must
  not match inside `repair-preview`. Per the project's testing rule, this gets
  tested as a **classifier over a set** of names, not one example at a time:
  build a corpus of names that must match and names that must not, and assert
  the full partition.

The list is unordered and duplicates are meaningless; the apps should treat it
as a set. Whether an unknown name is worth a diagnostic (an older build reading
a newer token) is an app-level call — it is a UX question, not a security one,
since the capability is already denied.

## Beta tokens — decided 2026-07-30 (Peter)

The release plan lists the pre-launch beta mechanism as "`BETA-{N}` license
tokens … free perpetual license". **Peter's decision supersedes that: beta
tokens must not survive forever.** They carry a mandatory `expiry`.

The reasoning is the same one that makes them attractive to forge in the first
place. A perpetual token that bypasses trial and refund logic is the single
highest-value target in the scheme — it is worth more to an attacker than any
paid license, because it never expires and never gets revoked by a chargeback.
Bounding its lifetime turns a permanent compromise into a dated one.

Note this is a payload-level rule, not a sigil-level one: sigil verifies opaque
bytes and has no opinion about `expiry`. The apps enforce it. But an expiry the
apps ignore is decoration, so the beta path deserves its own red-team pass
before the program runs.

`max_major` makes the commercial rule (same major = free upgrade, major bump =
paid) a property of the data rather than server logic.

**Explicitly NOT doing yet (agreed over-engineering):** a schema/type system
(`integer`/`decimal`/`printable-binary` typed values with validation regexes).
Add when a second consumer actually needs it; it will be additive via `v=2`, not
a rewrite. If money ever enters a payload, use integer minor-units, never float.

## Revocation — decided 2026-07-28 (Peter)

**Online re-check on update, plus a one-year offline window.** Concretely, the
app must successfully confirm a license online when *either* trigger fires:

1. the running version changed (any major **or** minor bump — updating already
   requires the network, so this is free), or
2. `offline_days` (365) have passed since the last successful confirmation.

Between triggers the app is fully offline. This is revocation-by-reconfirmation
rather than a downloaded denylist: refunds and chargebacks take effect at the
customer's next confirmation instead of immediately.

**None of this is sigil's code.** sigil verifies signatures; the policy lives in
Mecha Validate and Mecha Rotshield, and the state it needs (`last_confirmed`,
`installed_version`) is app state, not license content. What sigil contributes
is that the confirmation *response* is itself a sigil envelope — a short-dated
signed attestation — so the reply cannot be spoofed by anything a customer can
point their hosts file at, and no second verification mechanism is needed.

Three failure modes to get right, because all three are easy to get wrong and
both products will share the mistake:

- **The offline clock is attacker-controlled.** A local system clock can be set
  backwards to extend the window indefinitely. Keep a monotonic high-water mark
  — the latest date ever observed — and never let effective "now" move backwards
  from it. This does not make the clock trustworthy, it just removes the
  free win.
- **"Cannot reach the server" is not "revoked."** Fail *open* on network
  failure, TLS failure, timeout and 5xx; fail *closed* only on an authenticated
  response that explicitly says revoked. Inverting this bricks paid software the
  first time a DNS provider has a bad afternoon.
- **A sustained inability to confirm still needs an answer.** After the offline
  window lapses and confirmation keeps failing, degrade with visible warnings
  over a grace period rather than locking out at the stroke of midnight. The
  grace length is an app-level knob.

Accepted cost, stated plainly: a refunded customer keeps working software for up
to `offline_days`. That is the price of not phoning home, and it is the right
trade at this price point.

## Key custody — decided 2026-07-28 (Peter)

The keyfile stores **no public key** (removed 2026-07-30). It once did, so
`sigil pubkey` could run without a passphrase — which meant anyone who could
write the keyfile chose the key a developer would embed in a shipped product,
and `sigil pubkey --key` is exactly the command the README told them to run.
Peter's instruction was *"mechanically force it to be computed"*: the field is
deleted rather than validated against the derived value, so the mistake is
inexpressible rather than detected. The public key now comes from the decrypted
seed, which costs a passphrase prompt on `--key`; the passphrase-free path is
the sibling `.pub` file that `keygen` already writes.

**The secret key lives in a passphrase-encrypted keyfile** (Argon2id →
XChaCha20-Poly1305, both from Zig std, so no new dependency). The realistic
threat is not a burglar; it is a backup, a synced folder, or a stray `tar` that
carries the key somewhere it was never meant to go. Encryption at rest makes
every one of those copies inert.

The separation is structural, not advisory:

- `libsigil.a` — verification only. This is what Mecha Validate and Mecha
  Rotshield link.
- `libsigil_sign.a` — key generation, passphrase wrapping, signing. Only the
  `sigil` CLI links it.

A product that links the verifier **cannot sign**, because the code to do so is
not in the binary. That is a property of the linker rather than a rule someone
has to remember, which is the whole point.

## Build shape (Peter's standard)

Zig core (pure, no I/O) → C FFI → C CLI dogfooding the FFI. Scaffold via the
`scaffold-zig-project` skill. First test should be the verifier: sign a known
payload, verify it, then flip one byte and assert rejection.
