# sigil — Plan

Ed25519-signed document verification, shared by **Mecha Validate** and
**Mecha Rotshield**. On the critical path to revenue: neither product ships
without offline license verification.

**The one invariant:** the signature covers the payload bytes *exactly* as
supplied. sigil never canonicalizes, re-orders, or re-serializes. Corollary:
**verify BEFORE parsing** — never interpret bytes you have not authenticated.

See `docs/DESIGN.md` for the envelope format, prior art, and reasoning.

## In Progress

- [ ] Mechatron Prime CI onboarding (`.mechatron-prime/targets` + badge).
      Note: CI was HALTED with a queue of 11 as of 2026-07-27 — a non-green
      badge may not be ours.

## Next

- [ ] `README.md` with the pitch (human-scannable payload, whitespace-immune,
      zero-dependency verifier) and the CI badge.
- [ ] `PROJECT_OVERVIEW.md`.
- [ ] Hand Mecha Validate and Mecha Rotshield an integration note: link
      `libsigil.a` only, embed the key via `sigil pubkey --format c|zig`, and
      implement the confirmation policy from docs/DESIGN.md (monotonic clock
      high-water mark; fail open on network error, closed only on an explicit
      revoked response; grace period rather than a midnight lockout).
- [ ] The confirmation endpoint itself + a short-dated attestation envelope.
      Server-side, so a separate piece of work — but the format is already
      settled (it is just another sigil envelope).
- [ ] Benchmark gate (`./bm`) once verification is on a hot path anywhere.

## Deferred — raise with Peter rather than deciding

- [ ] **i18n groundwork.** The canonical brief wants prepare-phase i18n at app
      construction, but sigil's CLI is an internal fulfillment tool that Peter
      alone runs; customers never see it. Deferring on scope-discipline
      grounds. Say the word and it gets the `--lang` scaffolding.

## Decided (see docs/DESIGN.md for the full reasoning)

- [x] **Revocation:** online re-check whenever the version changes (major or
      minor) plus a one-year offline window (`offline_days` in the payload).
      The policy lives in the products, not in sigil; the confirmation response
      is itself a short-dated sigil envelope so it cannot be spoofed. Three
      guardrails written down: monotonic clock high-water mark, fail-open on
      network error / fail-closed only on an explicit revoked response, and a
      grace period rather than a midnight lockout. — 2026-07-28 08:35 EST
- [x] **Key custody:** passphrase-encrypted keyfile (Argon2id +
      XChaCha20-Poly1305, both Zig std). Signing code lives in a separate
      `libsigil_sign.a`, so a product linking only `libsigil.a` physically
      cannot sign. — 2026-07-28 08:35 EST

## Explicitly deferred (agreed over-engineering)

- A typed schema layer for the payload (`integer`/`decimal`/typed values with
  validation regexes). Payload v1 is: keys `[a-z0-9_]+`, values UTF-8 strings,
  the application interprets them. Add via `v=2` when a second consumer
  actually needs it — it will be additive, not a rewrite.

## Completed

- [x] Pure Zig core `verify()` + C FFI (`sigil_verify`, `sigil_version`,
      `sigil_signature_len`, `sigil_public_key_len`), 8 tests incl. the
      `max_major` forgery case. — 2026-07-27 22:15 EST
- [x] C CLI skeleton. C on purpose: it *cannot* `@import` the Zig core, so the
      FFI bypass is inexpressible rather than merely discouraged. — 2026-07-27 22:15 EST
- [x] git repo on branch `yolo`, commit-msg hook, `.gitignore`. — 2026-07-27 22:30 EST
- [x] `flake.nix` (Zig 0.16.0 pinned via zig-overlay) with real `checks.*`:
      `build`, `test`, `test-cli`; `./build` and `./test` runners. — 2026-07-27 22:35 EST
- [x] Split the C ABI out of the importable module (`src/ffi.zig` is the static
      library's root; `src/lib.zig` emits no `sigil_*` symbols and needs no
      libc). Two test roots, so `zig build test` fails loudly if the verifier
      ever picks up a libc dependency an embedder would inherit. — 2026-07-27 22:35 EST
- [x] The envelope: parse, decode both printable-binary values, verify over the
      decoded `data` bytes, hand back only authenticated payload. Strict on
      duplicate keys, tolerant of unknown fields. `sigil_verify_envelope` +
      `sigil_strerror` across the FFI. 55 tests green. — 2026-07-27 22:45 EST
- [x] RFC 8032 known-answer vectors on both sides — the verifier accepts the
      standard's signatures, and the signer reproduces them byte-for-byte
      (Ed25519 is deterministic). Each vector independently confirmed against
      Node and OpenSSL before being committed. — 2026-07-28 08:30 EST
- [x] Signing: `src/sign.zig` (pure) + `src/ffi_sign.zig` (adapter, holds the
      only randomness) built into a separate `libsigil_sign.a`. No secret ever
      crosses the FFI — `sigil_seal` takes keyfile + passphrase and returns a
      finished envelope. `tests/test_no_signing_symbols` enforces the split
      with `nm`, and was confirmed to actually fail when violated. — 2026-07-28 08:50 EST
- [x] CLI: `verify` / `sign` / `keygen` / `pubkey`, with `-`/`@stdin`,
      `@stdout`/`@stderr`, `--json`, `--quiet`, `--simple`, `--no-color`,
      `--` terminator, later-args-override-earlier, spaces in paths, Windows
      `/flag` spellings, and sysexits codes (0 verified, 1 rejected, 64 usage,
      66 missing input, 74 I/O). `keygen` refuses to clobber an existing key
      without `--force` and confirms an interactively typed passphrase.
      66 CLI tests. — 2026-07-28 08:55 EST
