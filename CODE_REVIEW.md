# Code Review — sigil

**Date:** 2026-07-28
**Reviewer:** Claude (deep-code-review skill, 5 parallel agents)
**Scope:** Full codebase audit at `c3e49de` — 3,217 LOC, Zig core + C FFI + C CLI
**Method:** Every finding below was reproduced by building, linking, running, or
disassembling. Nothing is speculative. Where an agent's diagnosis was wrong, the
correction is noted inline.

## Summary

| Severity | Count |
|---|---|
| CRITICAL 🔥 | 7 |
| WARNING ‼️ | 18 |
| ADVISORY ⚠️ | 20 |

**The Zig core is in genuinely good shape.** No `catch {}`, no `catch unreachable`,
no TODOs or stubs. RFC 8032 conformance is a true claim (verified against the Zig
stdlib source, not assumed). Verify-before-parse holds on every path, enforced by
the type signature — there is no non-verifying extractor. The one invariant
(signature covers payload bytes exactly as supplied) holds.

**Nearly every defect lives in `cli/main.c` and the shell runners** — the layer
between the good core and the customer. This maps onto language enforcement:
Zig makes unused return values a compile error and forces error handling; C and
Bash make both opt-in. The defect density follows the gradient, not the author.

**The most serious findings are about controls, not code.** Two agents
independently shipped working Ed25519 signers while `test_no_signing_symbols`
reported "19 passed, 0 failed." The separation it guards is real today; the
control that is supposed to keep it real is not capable of noticing when it
stops being real.

---

## Critical

### `tests/test_no_signing_symbols` — the custody control is false-green (F1/C2)
**Dimension:** 2 (test coverage) / MFIC
Found independently by two agents. The control greps for 4 forbidden names and
5 substrings. Adding `export fn sigil_mint` to `src/ffi.zig` (a working signer,
confirmed by disassembly) left the control **green**; a C program linking only
`libsigil.a` then minted RFC 8032 vector 1, verifying under the RFC's own public
key. The forbidden stems (`keygen`/`wrapKey`/`argon2`) guard the *keyfile* path;
a raw signer touches none of them, and dead-code elimination keeps Argon2 out so
the belt-and-braces check stays quiet too.

**Fix:** invert to an **allowlist** — assert set equality between `nm` exports
and header declarations, plus a negative control on the private-key primitives
(`Edwards25519.mul`, `scalar.reduce64`). An oracle derived from the crypto, not
from our naming. A denylist is incomplete by construction: it can only catch
violations someone already imagined.

### `build.zig:25-30` — the importable Zig module has zero coverage (F2)
**Dimension:** 2 / MFIC
`b.addModule("sigil")` produces no binary for `nm` to read. Adding three
`pub const` re-exports to `src/lib.zig` left the archive **byte-identical**
(Zig doesn't codegen unreferenced decls), so the control could not notice — and
a Zig consumer importing only the module minted a valid signature.

This is the commercially live path: the canonical brief's **sibling-Zig
exception explicitly permits** Mecha Validate and Rotshield to import the module
directly. **Fix:** source-level `@import`-closure assertion, or a negative
compile test.

### `build.zig:47,66` — `libsigil.a` cannot be linked by a customer's toolchain
**Dimension:** 11 (FFI)
Two independent causes, both confirmed with stock `gcc 15.3.0`:
1. **PIE/PIC:** `relocation R_X86_64_32 … can not be used when making a PIE
   object`. The archive is non-PIC; modern distro gcc defaults to PIE.
2. **compiler-rt soft-float:** with `-no-pie`, link still fails on `roundq`,
   `__divtf3`, `__multf3`, `__fixtfti`, `__floatuntitf`, `__gttf2`, `__lttf2`,
   `__netf2` — all reached from `std/json/static.zig:771` (f128 number parsing).

Only `zig cc` links today, and `zig build` supplies compiler-rt silently, so our
one C consumer never walks the customer's path. **Note:** the envelope has three
string fields and no numbers, so this soft-float code can never execute for a
valid envelope. Options: `bundle_compiler_rt = true` + PIC (safe), or drop
`std.json` for a purpose-built envelope parser (bold — also where the
normalization feature must live).

### `cli/main.c:245-246, 317-328` — `--help`/`--about` documented but never parsed
**Dimension:** 1 (incomplete functionality)
Listed under "Common options:" but parsed only as `argv[1]`.
`sigil verify --help` → `unknown option: --help`, exit 64. All four subcommands.
Same defect class as `--check-only` (dotfiles, 2026-07-27) and the `-Ad`
assertion: documented, never parsed, nothing checked.

### `cli/main.c:374-383` — `verify` reports transient OOM as a forged license
**Dimension:** 12 (error handling)
Collapses **every** FFI error code to exit 1 "rejected", including
`SIGIL_ERR_OUT_OF_MEMORY` and `SIGIL_ERR_BUFFER_TOO_SMALL`. A paying customer
with a momentary allocation failure is told their license is a forgery.
`src/envelope.zig:170-172` explicitly documents avoiding exactly this
("collapsing them would report a transient OOM as a forged license"), and
`cmd_sign` *does* discriminate — so this is also sibling-path divergence.

### `test:46` — a failed build silently certified a stale binary  ✅ FIXED
**Dimension:** 4 / MFIC
`./build 2>&1 | tail -3 || { echo FATAL; exit 1; }` — `||` binds to the
pipeline, whose status is `tail`'s. Observed live during this review: 209/209
green off an artifact nobody had just built. Now captures status before judging;
`tests/test_harness_guards` pins it (red-phase verified: 3 failures before fix).

### `build:25` — `./build` never installed `libsigil_sign.a`  ✅ FIXED
**Dimension:** 1 / MFIC
`test_no_signing_symbols` inspects `zig-out/lib`. The signing archive was never
installed, so on a fresh clone the control cannot run — and locally it certified
**stale bytes** (the local copy's sha256 differed from the nix output). Now
installs every archive and fails loudly if one is absent.

---

## Warnings

### `sign.zig:221-230`, `cli/main.c:577` — `sigil pubkey` returns an unauthenticated key
Keyfiles store `public` in **plaintext** beside the encrypted `ciphertext`, and
`pubkey` echoes that field without decrypting. **Reproduced:** splicing an
attacker's `public` field into a victim keyfile makes `sigil pubkey` print the
attacker's key, no passphrase required. `sign` catches it; `pubkey` is precisely
the command the README tells you to run to obtain the key you **embed in the
shipped product**. Requires local write access, so not remote-exploitable.

**Fix (decided):** delete the field. It is redundant — `keygen` already writes a
sibling `.pub`. With nothing cached to read, `pubkey` *must* derive from the
decrypted secret. Physics over policy: the vulnerability becomes inexpressible
rather than forbidden, so it cannot be helpfully reintroduced later.

### `cli/main.c:147` — secret keyfile written 0644, plus TOCTOU
Verified ambient: `umask 022` → `-rw-r--r--`. The key is Argon2id-encrypted so
this is defense-in-depth, but `DESIGN.md:145` names backups and synced folders
as the threat, and ssh-keygen/gpg/minisign all force 0600. One
`open(..., O_CREAT|O_EXCL, 0600)` fixes the permissions **and** the TOCTOU in
the clobber-probe.

### `cli/main.c:376` — `--json` emits invalid JSON
`sigil_strerror`'s sigtype message contains a literal `"`, spliced unescaped.
Confirmed with `jq: parse error`.

### `cli/main.c:390` — `--quiet` discards the authenticated payload and exits 0
`verify … -q > out.txt` yields an empty file and success. Contradicts both
`--help` and README. The CLI test asserts current behavior, so the test pins the
wrong contract.

### FFI leaks are undetectable by the suite (proven by mutation)
Deleting `defer c_allocator.free(payload)` from `sigil_verify_envelope` still
yields **124/124 passed**. The FFI hardcodes `std.heap.c_allocator`, so
`std.testing.allocator` never covers the code under test.

### `flake.nix:75-77` + `zig-pkg/` tracked in git
`zigDepsHash` is inert: `cp -r ${zigDeps}/zig-pkg ./zig-pkg` nests at
`./zig-pkg/zig-pkg/` because 95 files (1.2 MB) of `zig-pkg/` are git-tracked, so
the *committed* copy compiles. Proved by appending a syntax error to the
vendored source: `nix build` failed with a compile error from that path, not a
hash mismatch. `.gitignore:41` lists `zig-pkg`, so new files there never appear
in `git status`.

### Passphrases silently truncated at 1023 chars (prompt path only)
`--passphrase-file` is uncapped, so a long-passphrase key becomes unopenable
interactively — reported as "wrong passphrase, or the keyfile has been altered".

### `MALFORMED_ENCODING` (-7) is unreachable for `data`/`sig`
Corrupt files are reported as `-1` "does not verify", i.e. as forgeries — the
exact customer-support failure `decodeField`'s own docstring set out to avoid.

### `--json` implemented only by `verify`
`sign`/`keygen`/`pubkey` silently ignore it. `pubkey --out` silently ignored for
`hex`/`c`/`zig` — which is the README's own key-embedding workflow.
`verify --json --out F` silently never creates F.

### `keygen` leaves an orphan secret key on partial failure
Writes a live secret key, then aborts on the `.pub` check, with a message
implying nothing happened.

### `test_cli:282` — `grep -P '[\x80-\xff]'` matches code points, not bytes
Cannot see `✓` or emoji. Fed ✓-containing default output, it still passed.
One-character fix (`grep -q '[^ -~]'`) verified correct.

### No test exercises a bad public key
All-zero and small-order keys *are* rejected (`WeakPublicKey`) but that is
delegated entirely to upstream Zig with nothing pinning it, and it is
misclassified as `BadSignature`. `pubkey --format c` hands embedders a `[32]`
array to paste in, so a zeroed key is a realistic accident.

### 19 masked return values across the shell suites
`shellcheck -o check-extra-masked-returns`: `tests/cli/test_cli` 11,
`test` 4, `tests/test_no_signing_symbols` 4. At default settings the repo reports
two notes. The check exists and ships disabled.

---

## Advisory (selected)

- **Envelope malleability is broader than documented.** Beyond whitespace and
  key order, JSON `m` escaping inside `data` and printable-binary alternate
  encodings both verify identically (decode passes unrecognized UTF-8 through
  and never errors). Not a forgery and not a revocation bypass, but the envelope
  **must never be used as an identifier** — dedup, blocklist, support
  fingerprint. Documentation fix.
- **`verify.zig:43` uses cofactored verification**; `verifyStrict` is the
  cofactorless alternative. RFC 8032 §5.1.7 permits both, so the pin claim
  stands — but the choice is undocumented and untested, and Zig has flipped this
  default before. Goes live if sigil ever verifies a third-party key.
- **README over-claims on core dumps.** `seal`/`signPayload` take `KeyPair` by
  value, so each frame holds an unwiped copy, and `SecretKey.bytes[0..32]` *is*
  the seed. True for logs, not for core dumps.
- `errorToCode`'s `else =>` gives a confidently *wrong* diagnosis for reachable
  errors. Exit codes conflate data errors with usage (64) and I/O (74).
- `--format`/`--force`/`--pubkey-out` are parsed but absent from `--help`.
- Windows `/flag` support works only for single-letter flags; the same
  normalizer mangles root-level absolute paths (`/license.sigil`) into switches.
- `sigil_verify` has **no C consumer** — the primitive ships undogfooded.
- The two-pass sizing contract the headers document is never used, and is
  actively unsafe for `sigil_keygen` (each call burns a fresh key).

---

## Correctly handled (verified, not assumed)

- **RFC 8032 conformance is real.** Zig's `Ed25519` defaults *are* the strict
  ones: `s < L`, canonical `R`, canonical pubkey, identity rejection on both `A`
  and `R`. Confirmed empirically: `s+L` → `BadSignature`, non-canonical `R` →
  rejected, identity pubkey → rejected. **Signature malleability is blocked.**
- **No length fields anywhere**, so the classic parse-untrusted-length
  allocation bug is inexpressible. Allocations are sized from measured input,
  capped at 16 MiB.
- **printable_binary is not in the forgery TCB** — decode runs before verify, so
  a wrong decode fails the check rather than forging one.
- **Ownership is unambiguous:** no function returns heap memory to C, so leaks
  and double-frees are inexpressible in customer code. Every entry point
  null-checks every pointer.
- **A guard-page test confirmed `sigil_verify` reads exactly 64/32 bytes** with
  no over-read. Zero constant drift across all 22 header/Zig constants.
- **The custody control correctly defends against "empty output = clean"**:
  `NM=/bin/false` produces 10 failures, because its positive assertions act as a
  specificity corpus. Whoever wrote that thought about it properly.
- **The test suite is well above average and not collusive.** No test asserts a
  value merely because the implementation produces it. The AEAD associated-data
  sweep flips a bit in the *decoded* value and re-encodes, so only the AEAD can
  catch it. The commercially critical `max_major` tamper case is confirmed
  non-vacuous at three levels, and the CLI fixture self-checks that it actually
  mutated the file before asserting rejection.

---

## A note on red-phase evidence

`PLAN.md:88` records that the custody control "was confirmed to actually fail
when violated." That was true for the class demonstrated. But a red-phase demo
binds only the class you demonstrated — it covered neither F1 nor F2. Red-green
proves a test *can* fire; it does not prove it fires on everything it claims to
cover. Where a control guards a property rather than a case, the check must be
derived from the property (allowlist, set equality, invariant) rather than from
an enumeration of remembered violations.
