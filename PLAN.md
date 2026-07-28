# sigil — Plan

Ed25519-signed document verification, shared by **Mecha Validate** and
**Mecha Rotshield**. On the critical path to revenue: neither product ships
without offline license verification.

**The one invariant:** the signature covers the payload bytes *exactly* as
supplied. sigil never canonicalizes, re-orders, or re-serializes. Corollary:
**verify BEFORE parsing** — never interpret bytes you have not authenticated.

See `docs/DESIGN.md` for the envelope format, prior art, and reasoning.

## In Progress

- [ ] **Mechatron Prime webhook — needs Peter.** Everything else is done: the
      repo is public at github.com/pmarreck/sigil (branch `yolo`),
      `.mechatron-prime/targets` lists four attributes each verified to build,
      and the README carries the canonical badge. The provisioner reads the
      shared secret through `sudo`, which an agent cannot supply, so the live
      run is Peter's. Dry run confirmed exactly one action: `CREATE
      pmarreck/sigil`. Admission was HALTED overnight but went `running` at
      2026-07-28 17:46Z and the queue is empty, so the first build should go
      straight through. `/badges/sigil.json` 404s until then — expected, not a
      failure.

## Next

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
      with `nm`. — 2026-07-28 08:50 EST
      **Correction (2026-07-28 16:35 EDT):** this entry originally claimed the
      control "was confirmed to actually fail when violated." That was true only
      of the one class demonstrated — deleting the library separation — and it
      was written as though it covered the claim generally. It did not: a
      renamed export and a Zig-module re-export both walked past it. A red-green
      demo proves a control *can* fire; it never proves it fires on everything
      the control claims to cover. See the allowlist entry below.
- [x] CLI: `verify` / `sign` / `keygen` / `pubkey`, with `-`/`@stdin`,
      `@stdout`/`@stderr`, `--json`, `--quiet`, `--simple`, `--no-color`,
      `--` terminator, later-args-override-earlier, spaces in paths, Windows
      `/flag` spellings, and sysexits codes (0 verified, 1 rejected, 64 usage,
      66 missing input, 74 I/O). `keygen` refuses to clobber an existing key
      without `--force` and confirms an interactively typed passphrase.
      66 CLI tests. — 2026-07-28 08:55 EST

## Post-review remediation (2026-07-28 deep-code-review, 5 agents)

Full findings: `CODE_REVIEW.md`. Every item below was reproduced by building,
linking, running or disassembling — none are speculative.

- [x] `./test` masked-pipeline guard; `./build` never installed
      `libsigil_sign.a`; nm status masked (twice — the second layer was `exit`
      inside a command substitution). `tests/test_harness_guards` pins it.
      — 2026-07-28 12:20 EDT
- [x] `tests/test_lint`: SC2312 gate for Bash + clang-tidy for C, each with a
      specificity corpus proving the gate still bites. 19 sites triaged.
      — 2026-07-28 12:20 EDT
- [x] `grep -P '[\x80-\xff]'` matched code points, not bytes — the `--simple`
      check could not see ✓. — 2026-07-28 12:20 EDT
- [x] **Custody control inverted from denylist to allowlist (F1/F2/C2).**
      Both bypasses reproduced first, then fixed, then re-confirmed:
      *(a)* `export fn sigil_mint` — old control 19 passed/0 failed while a C
      program linking only `libsigil.a` minted RFC 8032 vector 1 byte-for-byte;
      *(b)* `pub const sign = @import("sign.zig")` in lib.zig — archive stayed
      byte-identical, so `nm` saw nothing.
      Three layers now: set equality between the archive's C ABI exports and
      `include/sigil.h` declarations; a cryptographic oracle on the two
      primitives only signing reaches (`Edwards25519.mul`, `scalar.reduce64`,
      determined by diffing symbol tables, not guessed) each paired with a
      positive assertion against `libsigil_sign.a` as its specificity corpus;
      and the verification surface intact so shrinking the archive is not an
      out. `src/module_probe.zig` forces codegen of the importable module's
      public surface so the same oracle reaches the sanctioned sibling-Zig
      path. Verified: (a) → 3 failures, (b) → 2 failures, clean → 21/0.
      The crypto oracle survives an adversary who also edits the header.
      — 2026-07-28 16:35 EDT
- [x] `zig-pkg/` untracked (95 files, 1.2 MB). Build confirmed still green with
      no committed copy, so `zigDepsHash` is doing real work. — 2026-07-28 16:35 EDT

- [x] **`libsigil.a` linkable by a customer (C1).** Fixed in `b5cfb87` by the
      bold route: `std.json` dropped for a purpose-built parser, plus PIC.
      Re-confirmed 2026-07-28 16:40 EDT — stock gcc 15.3.0 (not `zig cc`)
      links and runs against the archive, now 512,956 bytes, down from
      949,604. `tests/test_c_conformance` gates it, 12 assertions.

### Critical, still open
- [ ] **`--help`/`--about` documented but never parsed** on any subcommand.
      `sigil verify --help` → `unknown option`, exit 64.
- [ ] **`verify` reports transient OOM as a forged license** — collapses every
      FFI code to exit 1. `envelope.zig:170` documents avoiding exactly this;
      `sign` already discriminates.

### High, still open

- [ ] **Delete the `public` field from the keyfile.** Splice confirmed: an
      attacker's `public` field makes `sigil pubkey` print the attacker's key
      with no passphrase — and that is the command README tells you to run to
      get the key you embed in the shipped product. The field is redundant
      (`keygen` already writes a sibling `.pub`). Deleting it makes the bug
      inexpressible rather than forbidden; `pubkey` must then derive from the
      decrypted secret. Peter: "Mechanically force it to be computed!"
- [ ] **C conformance binary exercising `sigil_verify`** (Peter's ask). The raw
      primitive currently ships with no C consumer. Compile it with **stock
      cc**, not `zig cc`, so it also mechanically gates C1 — `zig build`
      supplies compiler-rt silently, which is why nobody noticed.
- [ ] Keyfile written 0644 under default umask + TOCTOU in the clobber probe.
      One `open(..., O_CREAT|O_EXCL, 0600)` fixes both.
- [ ] `--json` emits invalid JSON (unescaped `"` from `sigil_strerror`).
- [ ] `--quiet` discards the authenticated payload and exits 0, contradicting
      both `--help` and README. The CLI test pins the wrong contract.
- [ ] **The suite cannot detect FFI leaks** — proven by mutation: deleting
      `defer c_allocator.free(payload)` still gives 124/124. The FFI hardcodes
      `c_allocator`, so `testing.allocator` never covers it.
- [ ] Passphrases silently truncated at 1023 chars on the prompt path only,
      producing an unopenable key reported as "wrong passphrase".
- [ ] `MALFORMED_ENCODING` unreachable for `data`/`sig` — corrupt files are
      reported as forgeries, the exact support failure the docstring names.
- [ ] `--json` implemented only by `verify`; `pubkey --out` silently ignored
      for hex/c/zig (the README's own embedding workflow).
- [ ] No test for a bad public key. All-zero/small-order *are* rejected, but
      only by upstream Zig, unpinned, and misclassified as `BadSignature`.

### Feature: envelope normalization (Peter, 2026-07-28)

Make verification survive transport mangling — email wrapping, `>` quote
prefixes, arbitrary injected junk.

Proven safe by exhaustion: encoding all 256 byte values yields exactly 256
distinct code points, and **none** is ASCII whitespace; `>`, `<`, `\` and `"`
are all remapped to lookalikes too. So stripping is a filter over an allowlist
*derived from the codec*, not a hand-written denylist.

Security argument: normalization runs BEFORE verification and the signature
covers the *decoded* bytes, so a normalization bug can only cause a false
rejection, never a false acceptance. Availability risk, not authenticity risk.

- [ ] Stage 1 (pre-parse): strip `\t\n\r` and space from the whole envelope.
      JSON-safe and value-safe. Fixes hard-wrapping.
- [ ] Stage 2 (post-parse, per value): strip any code point outside the
      256-symbol alphabet from `data` and `sig`. Fixes `>` prefixes.
- [ ] Default on, with a stderr warning when normalization changed something.
- [ ] Constraint to enforce: stage 1 is only safe while every envelope field is
      printable-binary or a fixed token. Reject unknown fields.

### Deferred / ideas

- [ ] **Mutation-test the suite.** It has never been mutation-tested; the FFI
      leak gap was found that way and is unlikely to be the only one. Every
      surviving mutant names an invalid region of the suite.
- [ ] **Elixir: NIF + pure-Elixir sigil, tested differentially** (Peter's idea,
      2026-07-28). Ed25519 is already in `:crypto` (OTP 24+), so a pure version
      is ~100 lines once printable-binary decode is ported. The differential
      suite is the point: an oracle causally independent of the Zig. Zigler
      handles NIF build integration, and Zig cross-compilation solves the
      historic "NIFs are miserable to deploy" problem — which is itself the
      story worth telling in that community. Candidate libs chosen by ecosystem
      *gap*: z7z (absent), printable_binary (no equivalent), validate (absent),
      sigil. Scheduler discipline differs per lib: short/hot → plain NIF,
      long-running → dirty CPU-bound schedulers.
- [ ] Envelope malleability is broader than documented (JSON `\u` escapes,
      alternate printable-binary encodings). Not a forgery, but the envelope
      must never be used as an identifier. Documentation fix.
- [ ] `verify.zig:43` uses cofactored verification; `verifyStrict` is the
      cofactorless alternative. Undocumented and untested. Matters only if
      sigil ever verifies a third-party key.
