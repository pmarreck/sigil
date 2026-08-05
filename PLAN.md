# sigil — Plan

Ed25519-signed document verification, shared by **Mecha Validate** and
**Mecha Rotshield**. On the critical path to revenue: neither product ships
without offline license verification.

**The one invariant:** the signature covers the payload bytes *exactly* as
supplied. sigil never canonicalizes, re-orders, or re-serializes. Corollary:
**verify BEFORE parsing** — never interpret bytes you have not authenticated.

See `docs/DESIGN.md` for the envelope format, prior art, and reasoning.

## In Progress

- [x] **Einstein's remediation queue is complete** — all seven items, each
      reproduced before it was fixed. `6d5a378`, CI green. 312 tests, and
      `./mutate` reports 9/10 mutants killed. — 2026-08-01 02:30 EDT
- [ ] **New scope from Peter (2026-08-04, relayed by Einstein), broken out
      below.** His words: *"sigil must serve as a maximally-correct and secure
      certificate signer; I'm still deciding on how I will provide the private
      key (yubikey or offline airgapped secret etc.; it should be flexible
      enough to be configurable for both) but it looks like Ed25519 will be the
      starting signature format unless something PQC-related is proven/usable;
      signing method should be specified in the cert or sig somehow for
      futureproofing."* Followed by *"please add these to a PLAN.md and work
      down the list."*

### A. Identify the signing method (Peter, 2026-08-04) — BLOCKED on his call

The requirement is real and today's answer is documentation, not construction:
`sigtype` sits in the envelope **unauthenticated**, and a future maintainer who
added a second algorithm and switched on that field would have built a
downgrade oracle. sigil already documents "pin the algorithm in the verifier's
config, never read it from the envelope" — but that is policy where physics is
available, exactly the distinction in the MFIC rules.

Three ways to satisfy it. This wants Peter because it is a **one-way door before
release** and because it turns on how literally THE INVARIANT is meant:

1. **Versioned signing transcript** — sign `domain ‖ version ‖ alg-id ‖
   payload-length ‖ payload-bytes-verbatim` instead of the bare payload.
   Payload bytes are never transformed, so reformatting the envelope still
   works and no canonicalization is needed; but the signed *input* is no longer
   the payload alone. Generalizes to any future algorithm. Einstein's
   recommendation, and mine.
2. **Ed25519ctx** (RFC 8032 §5.1) — mixes a context string into the hash with
   the message untouched. Two checked facts, not assumptions: Zig 0.16's
   `std.crypto.sign.Ed25519` does **not** expose it (the only `ctx` parameters
   in that file belong to the blind-key API), and it does not generalize to
   non-Ed25519 algorithms.
3. **Status quo** — verifier-pinned algorithm, `sigtype` informational only.
   Costs nothing, satisfies "futureproofing" only by convention.

**The question for Peter**: is "the signature is Ed25519 over the raw payload
bytes, full stop" a wire property you want to keep, or is "the payload bytes are
never transformed" the property that actually mattered? (1) preserves the second
and gives up the first. Nothing is released, so either is free *today* and
neither is free later.

- [ ] Get that decision.
- [ ] Then: specify field widths, length encoding and domain separation
      explicitly; write vectors and downgrade tests BEFORE implementing. No
      improvised encoding — a hand-rolled length prefix is how signature
      schemes get ambiguity bugs.

### B. Custody flexibility (Peter, 2026-08-04)

Peter wants the private key *provider* configurable — YubiKey or offline
air-gapped secret — not two finished drivers. The July 28 passphrase-encrypted
keyfile decision is not reversed; it becomes the first provider.

- [x] Define the smallest signer/key-provider port that keeps envelope and
      certificate semantics independent of custody. The existing Argon2id →
      XChaCha20-Poly1305 keyfile is provider #1 and is already tested.
      — 2026-08-05 02:17 EDT
      - [x] Inject a provider that receives only the bytes to sign and returns
            a fixed-size signature. Curiosity poke: keep seed and expanded-key
            storage inside provider #1, including provider construction.
      - [x] Preserve the current C CLI, RFC 8032 vectors, envelope bytes, and
            bare-payload signing transcript while §A remains an owner decision.
      - [x] Mechanically classify unsupported algorithm, missing hardware
            driver, external ceremony, and provider failure without claiming a
            YubiKey or air-gapped driver exists.
      - [ ] Run canonical tests/build/mutation/Nix and exact terminal
            Mechatron CI before publishing integration notes.
- [x] Capability discovery with honest unsupported behavior. Concretely: most
      YubiKey PIV firmware cannot do Ed25519 at all — PIV is RSA and ECDSA
      P-256/P-384, with Ed25519 only on 5.7+. A provider that cannot perform the
      configured algorithm must say so, not fail obscurely at signing time.
      — internal capability preflight and set-classifier tests, 2026-08-05
      02:17 EDT
- [x] Do NOT write a PKCS#11/PIV implementation without hardware to test it
      against. No driver or support claim was added. — 2026-08-05 02:17 EDT
- [x] Air-gapped ceremony is mostly a workflow question — the keyfile is one
      line of JSON and never leaves the signing host. The port and deferred
      ceremony requirements are documented in `docs/KEY_PROVIDERS.md`; no
      workflow was guessed. — 2026-08-05 02:17 EDT

### C. Exit-code contract inconsistency (found 2026-08-04)

- [ ] `--help` says exit 1 means "NOT AUTHENTIC ... Only 1 ever means a document
      was rejected on its merits", but a **wrong passphrase** also exits 1. A
      passphrase is not a document and it is not being rejected on its merits.
      Same misclassification family as the OOM and low-order-key bugs already
      fixed. Not changed on the spot: it is a documented CLI contract with an
      existing test pinning it, so it wants a deliberate choice (probably 77
      EX_NOPERM, or 65) rather than a midnight edit.

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

- [x] **Mechatron Prime CI green.** Peter supplied sudo; hook 658279047 created
      2026-07-28 22:41:54Z. It was created 73 min AFTER the last push, and
      GitHub does not replay history — so the 404 badge was simply "no push
      event yet", not a misconfiguration. First push after that (`884c0be`)
      built in 6s: `PASSING`. — 2026-07-28 19:20 EDT
- [x] **`verify` no longer reports a transient failure as a forgery** (queue
      item 1). `cli/exit_codes.h`, header-only and pure, tested as a classifier
      over a partition of every code in `sigil.h`. Only a bad signature exits 1;
      malformed input is 65, OOM is 75, unknown codes are 70. Both directions
      pinned, so "never accuse anything" cannot pass. — 2026-07-28 19:18 EDT

- [x] **Keyfile `public` field deleted** (queue item 2). Red phase first: with
      the field present, splicing an attacker's value made `sigil pubkey --key`
      print the attacker's key — the exact key the README says to embed in a
      shipped product. Now removed, not validated; format bumped to
      `secret-key-v2`; public key derived from the decrypted seed; dropped from
      the AAD (it cannot be bound when it must be derived after decryption).
      Re-ran the original attack against the fixed binary: splicing a `public`
      field back in changes nothing. Cost, accepted: `pubkey --key` prompts;
      `pubkey --pubkey` (the sibling `.pub`) still does not. — 2026-07-30 12:15 EDT

- [x] **Payload schema reconciled** against the locked spec (authority:
      `Obsidian Vaults/…/Mecha LLC/MECHA_RELEASE_PLAN.md`, "License key model").
      Peter's call: the spec's names win. `email` → `customer_email`,
      `issued` → `purchase_date`, plus `customer_name_canonical` for
      activation-time identity matching. One deliberate deviation at Peter's
      prompting: `paddle_transaction_id` → `payment_provider` + `payment_ref`,
      so a vendor name never sits inside a signed immutable key while
      per-license provenance is still recorded. — 2026-07-30 15:20 EDT
- [x] **Beta tokens must not survive forever** (Peter, 2026-07-30). Supersedes
      the release plan's "free perpetual license". Mandatory `expiry`. A
      perpetual token that bypasses trial and refund logic is worth more to an
      attacker than any paid license. — 2026-07-30 15:20 EDT

### Blocked on Peter
- [ ] **`features` shape** — the entitlement lever for the capability tiers
      (detection free; repair/creation gated). Deliberately not invented. The
      README's example envelope stays on the old placeholder names until this
      lands, since regenerating it means signing a payload we would then have
      to change again.
- [ ] The release plan needs both decisions above written back into it —
      Einstein's call, not mine; it is a business document with an existing
      documented precedence problem (the two-app vs three-app bundle price).

### High, still open

- [x] `--json` emitted invalid JSON. `sigil_strerror` was spliced into a JSON
      string literal unescaped, and `sigtype is not "Ed25519"` broke the
      output at exactly the moment a consumer most needs to read the reason.
      `cli/json.h` (RFC 8259 escaping, header-only so it is testable), swept
      over all 256 byte values plus every strerror message, and every `--json`
      path in the CLI suite now goes through **jq** as the parse oracle.
      — 2026-08-01 02:10 EDT
- [x] `--quiet` no longer discards the authenticated payload. It means "no
      status output", per both `--help` and the README; the payload is data on
      stdout and the status is commentary on stderr. The old CLI test pinned
      the wrong contract and was rewritten first. — 2026-08-01 02:12 EDT
- [x] **The suite can now detect FFI leaks.** Reproduced first: deleting
      `defer alloc.free(payload)` left the suite at 48/48 green, because
      `c_allocator` cannot detect a leak at all. The FFI now uses
      `testing.allocator` under `builtin.is_test`. Re-planting the same defect
      reports 2 leaks by name. — 2026-08-01 02:15 EDT
- [x] **Mutation testing exists** (`./mutate`), reporting a number rather than
      a boolean. **9/10 killed.** It immediately found two more gaps that a
      green suite was hiding: an off-by-one in the output-capacity check (every
      existing test used a buffer either comfortably large or absurdly small,
      so "exactly right" was never exercised) and the keyfile format-version
      check (the malformed-keyfile test used placeholder values, so it failed
      at decoding long before the version was consulted). Both now have tests.
      The one accepted survivor is "the decrypted seed is never wiped" —
      whether a stack buffer was zeroed is not observable without relying on
      UB, and a test built on UB is worse than no test. It stays in the list so
      the number stays honest. The exit code means "a NEW survivor appeared",
      and a known survivor that starts dying is also flagged so the allowlist
      cannot quietly grow into an excuse. — 2026-08-01 02:27 EDT
- [x] `features` is confirmed necessary and specified (Peter, 2026-08-04): a
      Pro upgrade is the same SKU with a different capability set, which no
      other field can express. Shape and the three rules that keep the check
      honest (additive allowlist, absent-means-base, whole-name match tested as
      a classifier over a set) are in `docs/DESIGN.md` and the release plan.
      The README example envelope was regenerated on the real field names.
      — 2026-08-04 23:10 EDT
- [x] Revocation and beta-token expiry written into `MECHA_RELEASE_PLAN.md` as
      dated post-lock amendments, along with the `payment_provider` /
      `payment_ref` split, sigil as the named implementation, and the
      confirmation endpoint added to the shared-infrastructure list — without
      it, `offline_days` never resets and revocation does not exist.
      — 2026-08-04 23:08 EDT
- [x] `MALFORMED_ENCODING` was unreachable for `data`/`sig`. printable-binary's
      decoder is total over valid UTF-8 — an unmapped glyph becomes *some* byte
      rather than an error — so a file mangled in transit came back as
      "signature does not verify", telling a paying customer their license is
      FORGED. Now screened with `pb.validate`, the codec's own oracle rather
      than a copy of the alphabet kept here, so the two cannot drift apart.
      Specificity corpus: all 256 byte values round-trip, both together and
      one at a time. — 2026-08-04 23:33 EDT
- [x] Bad public keys are now tested, and the finding was worse than this entry
      claimed. All eight small-order points are **accepted** by
      `Ed25519.PublicKey.fromBytes`; upstream rejects them further down as
      `IdentityElement`, which sigil collapsed into `BadSignature`. Two
      consequences: a broken or substituted key was reported as a forged
      document (the same misclassification as the OOM bug), and sigil's whole
      security rested on an upstream property nothing here pinned — if Zig's
      cofactored verify ever relaxed, a substituted low-order key would
      validate *any* signature over *any* message with the suite still green.
      `verify()` now screens low-order points itself and returns
      `BadPublicKey`. The corpus is self-checking: each point is multiplied by
      the cofactor and asserted to be the identity, so a typo in the table
      fails loudly instead of silently shrinking the set. Specificity: five
      real keypairs must verify, and a wrong key must still say
      `BadSignature`. — 2026-08-04 23:20 EDT
- [x] **`./mutate` destroyed uncommitted work.** It snapshots the sources it
      mutates and restores them between mutants; an edit made during a run was
      silently reverted at the next restore, and it ate a set of tests
      mid-session. Against Peter's data-safety rule, and my own tool's fault.
      It now takes a lock, hashes what it last wrote to each source, and on any
      deviation aborts, leaves the foreign edit in place, and KEEPS the
      snapshot rather than overwriting. Verified by editing a source mid-run:
      aborted, edit survived, snapshot preserved. (The first attempt at that
      verification raced — the edit landed before the snapshot and legitimately
      became the baseline — so the check now waits for the baseline line.)
      — 2026-08-04 23:34 EDT
- [x] The README's example envelope is now checked to be a real signed license.
      It claimed "That is a real signed license" and nothing verified that, so
      any doc edit could have turned the front page into a plausible fake with
      the suite still green. The public key is published beside it, so a reader
      can check it too, and the CLI suite re-verifies it on every run with a
      tamper control that reports *itself* as vacuous if the example changes.
      — 2026-08-04 23:12 EDT
- [ ] `--json` implemented only by `verify`; `pubkey --out` silently ignored
      for hex/c/zig (the README's own embedding workflow).
- [x] Passphrases were silently truncated at 1023 chars on the prompt path only.
      Because only that path was capped, the two disagreed: a key created from a
      long `--passphrase-file` could never be opened by typing the same
      passphrase, and it presented as "wrong passphrase" on a passphrase that
      was correct — an unopenable signing key with nothing pointing at the
      cause. Now read unbounded, grown by hand rather than with `realloc`
      (which may copy and free, leaving a plaintext passphrase in memory that
      nothing can reach to wipe). Removing the cap introduced an unbounded
      malloc loop over stdin, so the replacement bound at `MAX_INPUT` REPORTS
      rather than truncates — silently cutting the input is the defect that
      started this. Control test: a passphrase agreeing on the first 1023
      characters and then diverging must still be rejected, which is exactly
      the case truncation used to accept. — 2026-08-04 23:47 EDT

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
