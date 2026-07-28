# sigil — Plan

Ed25519-signed document verification, shared by **Mecha Validate** and
**Mecha Rotshield**. On the critical path to revenue: neither product ships
without offline license verification.

**The one invariant:** the signature covers the payload bytes *exactly* as
supplied. sigil never canonicalizes, re-orders, or re-serializes. Corollary:
**verify BEFORE parsing** — never interpret bytes you have not authenticated.

See `docs/DESIGN.md` for the envelope format, prior art, and reasoning.

## In Progress

- [ ] The envelope: parse `{"data":…,"sigtype":"Ed25519","sig":…}`, decode both
      printable-binary values, verify over the decoded `data` bytes, only then
      hand the payload back. Import `printable_binary`'s Zig module directly
      (sibling exception — it already dogfoods its own C FFI).
- [ ] CLI surface: `sigil verify <file> --pubkey <path>` plus the brief's
      conventions (`-`/`@stdin`, `--json`, stderr for metadata, later args
      override earlier).

## Next

- [ ] Mechatron Prime CI onboarding (`.mechatron-prime/targets` + badge).
      Note: CI was HALTED with a queue of 11 as of 2026-07-27 — a non-green
      badge may not be ours.
- [ ] `sigil keygen` / `sigil sign` — **design key custody first.** The private
      key must never ship. Signing must be separable from verifying so the
      products embed only the verifier.
- [ ] `PROJECT_OVERVIEW.md` once the CLI surface settles.
- [ ] Benchmark gate (`./bm`) once verification is on a hot path anywhere.

## Open questions (do NOT decide alone)

- [ ] **Revocation.** Offline verification cannot revoke. Options: short-dated
      licenses, an opportunistically-fetched revocation list, or accepting no
      revocation (what most indie desktop software does). Peter decides.
      Blocks the payload's final field set (`expires` exists only if we pick
      short-dating).

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
