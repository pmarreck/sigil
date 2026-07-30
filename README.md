# sigil

[![Mechatron Prime CI](https://img.shields.io/endpoint?url=https%3A%2F%2Fthelio-nixos.tail66c90.ts.net%2Fbadges%2Fsigil.json&style=for-the-badge)](https://thelio-nixos.tail66c90.ts.net/mechatron-prime/)

Verify Ed25519-signed documents whose payload **stays human-scannable**.

```json
{"data":"email␣꞊␣ˮpeter@example.comˮ¶max_major␣꞊␣ˮ1ˮ¶product␣꞊␣ˮmecha˗validateˮ¶","sigtype":"Ed25519","sig":"ȯTŖĹŖĵŽǦ␣Atľď4ĵ⟦ǹǧmCŶUǁǃƕ¯¿ŴŷoűĤĭǵe⌫ṾˮȳkŕȦCƌŤkņqkʼĺĹƘ❵ȧ˗Ťqćǧw∣w⌫"}
```

That is a real signed license. You can read it. You can `grep` it. It is still
plain JSON, and it is still safe for arbitrary binary payloads.

## The one invariant

**The signature covers the payload bytes exactly as supplied.** sigil never
canonicalizes, re-orders, or re-serializes anything.

Everything else follows from that:

- The JSON envelope is **transport only**. Pretty-print it, reorder its keys,
  add whitespace, convert it to CRLF — verification still holds.
- No canonicalization scheme (cf. RFC 8785), no collation library, no locale.
  There is nothing for two implementations to disagree about.
- **Verify before parsing.** `verifyEnvelope` is the only way to obtain payload
  bytes, so a caller physically cannot interpret unauthenticated input.

## Why printable-binary rather than base64

Not dogfooding — [printable-binary](https://github.com/pmarreck/printable-binary)
preserves legible ASCII, so a mostly-ASCII payload stays readable instead of
becoming an opaque blob. It also never emits `"`, `\` or a control character, so
it drops into a JSON string with no escaping. (That property is swept over all
256 byte values in the test suite, because the format depends on it.)

## Usage

```console
$ sigil keygen --out mecha.key          # writes mecha.key (encrypted) + mecha.key.pub
$ sigil sign license.toml --key mecha.key --out license.sigil
$ sigil verify license.sigil --pubkey mecha.key.pub
email = "peter@example.com"
max_major = "1"
product = "mecha-validate"
✓ verified license.sigil (71 bytes)
```

stdout is the authenticated payload and nothing else, so it pipes. Status goes
to stderr. Exit codes distinguish *rejected* (1) from *misused* (64), missing
input (66) and I/O trouble (74).

Embedding the key in a product:

```console
$ sigil pubkey --pubkey mecha.key.pub --format zig
pub const sigil_public_key: [32]u8 = .{
    0xe5, 0x35, 0x1e, 0xe4, ...
};
```

`--format` also takes `c`, `hex`, `raw` and `text`.

`--pubkey <file>` reads the `.pub` file `keygen` wrote and needs no passphrase.
`--key <keyfile>` also works but will prompt, because it derives the key by
decrypting the secret. The keyfile deliberately stores no public key: when it
did, anyone who could write that file chose which key you embedded in your
shipped product.

## Shape

```
any consumer ──► C FFI (libsigil.a) ──► Zig core (pure, no I/O)
```

The CLI is written in C on purpose: C *cannot* `@import` the Zig core, so
bypassing the FFI that Mecha Validate and Mecha Rotshield depend on is
inexpressible rather than merely discouraged.

Signing lives in a **separate** `libsigil_sign.a`. A product that links
`libsigil.a` cannot mint a license, because the code to do so is not in the
binary — a fact about the linker, checked with `nm` in CI rather than asserted
in a comment.

The verifier's entire dependency budget is `std.crypto.sign.Ed25519` plus a
printable-binary decode. It does not link libc.

## Key custody

The secret key is stored passphrase-encrypted (Argon2id → XChaCha20-Poly1305).
The realistic threat is a backup or a synced folder, not a burglar. The KDF
parameters, salt and public key are bound as AEAD associated data, so nobody can
downgrade the work factor and have the reader play along.

No secret crosses the FFI: `sigil sign` hands the library a keyfile and a
passphrase and gets back a finished envelope, so key material never becomes a
buffer that could reach a log line or a core dump.

## Prior art

JWS/JWT already uses this trick — it signs `base64url(header).base64url(payload)`
specifically to dodge JSON canonicalization — so the envelope idea is not novel
and sigil does not claim it is. [PASETO](https://paseto.io/) is the closest
conceptual competitor; `minisign` and OpenBSD's `signify` are the closest
tooling. RFC 8785 is the standards-track answer this design routes around.

What sigil offers instead: a payload you can still read, immunity to
whitespace/CRLF/re-formatting, safety for arbitrary binary including embedded
JSON, and a verifier with essentially no dependencies.

## Build and test

```console
$ ./build      # nix build, ReleaseFast
$ ./test       # Zig unit tests + symbol separation + CLI surface
```

See `docs/DESIGN.md` for the envelope format and the recorded revocation and
key-custody decisions, and `PLAN.md` for what is next.
