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

**Authority:** `Obsidian Vaults/Peter Marreck/Professional/Mecha LLC/MECHA_RELEASE_PLAN.md`,
"License key model". sigil's earlier examples predated that document and used
different names for the same concepts; Peter's call (2026-07-30) is that the
spec's names win. This matters more than it looks: sigil signs exact bytes, so
renaming a key after licence #1 is issued means a legacy parse path forever, or
reissuing every licence.

```toml
customer_email = "peter@example.com"
customer_name_canonical = "peter marreck"
expiry = "2027-07-30"          # optional for a sale; REQUIRED for a beta token
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
Billing already forced one rethink by not issuing licence keys at all — so
naming a signed, immutable field after it is a bet. But a generic
`payment_provider_transaction_id` loses something real: after a migration, old
licences genuinely *do* hold Paddle references, and a generic name would make a
Stripe ID and a Paddle ID indistinguishable.

Both concerns are satisfied by moving the vendor out of the key and into a
value:

```toml
payment_provider = "paddle"
payment_ref = "txn_01J8XYZ"
```

The key names never need to change; provenance is recorded per licence, so a
2026 token still says `paddle` and a 2028 one says whatever replaced it; and
nothing is ever mislabelled. Two short keys instead of one long inaccurate one.

`offline_days` is data rather than a constant in two codebases so the window can
be widened for a customer with a genuinely air-gapped machine without shipping a
new build. See the revocation section below for what consumes it.

**Still undecided — do not invent it:** `features`, the entitlement lever for
the capability tiers (detection always free; repair/creation licence-gated).
Its shape is a product decision Peter has not made, so the example above omits
it rather than guessing. The example envelope in `README.md` stays on the old
placeholder names until `features` is settled, because regenerating it means
signing a payload we would then have to change again.

## Beta tokens — decided 2026-07-30 (Peter)

The release plan lists the pre-launch beta mechanism as "`BETA-{N}` license
tokens … free perpetual license". **Peter's decision supersedes that: beta
tokens must not survive forever.** They carry a mandatory `expiry`.

The reasoning is the same one that makes them attractive to forge in the first
place. A perpetual token that bypasses trial and refund logic is the single
highest-value target in the scheme — it is worth more to an attacker than any
paid licence, because it never expires and never gets revoked by a chargeback.
Bounding its lifetime turns a permanent compromise into a dated one.

Note this is a payload-level rule, not a sigil-level one: sigil verifies opaque
bytes and has no opinion about `expiry`. The apps enforce it. But an expiry the
apps ignore is decoration, so the beta path deserves its own red-team pass
before the programme runs.

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
