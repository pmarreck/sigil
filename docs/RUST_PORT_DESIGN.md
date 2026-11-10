# Rust port of sigil: design

Status: in progress, 2026-11-10. Steps 0 to 2 and the signing library of
step 3 are implemented; see "Status" and "Order of work". Items marked "owner
ruling" were decided by SCS (Senior Construct Swarmlord, the project owner).
Everything not yet implemented is a proposal and can change before code lands.

## Owner rulings (2026-11-10)

1. sigil is ported to Rust in full.
2. The Zig implementation stays as a permanent differential oracle.
3. Both implementations pass the same CLI test suite.
4. Both are available to consumers as libraries.
5. Both work with exactly the same data.
6. The shared admission rules (mecha_policy: decide, install decide, machine
   hash, hint hash) are ported into the same Rust workspace.
7. The port includes a Rust CLI. The same test suite runs across both CLI
   surfaces, and the two libraries' ABIs are close enough that a consumer
   can use either.
8. Each frontend also runs against the other implementation's library through
   that library's ABI, so the cross pairs both test and dogfood the ABI.

## Why two implementations are a risk, and what holds them together

A license forgery needs only one implementation to accept something the other
refuses. Three mechanisms keep that from happening, and each one fails a build
rather than producing a report:

- **One C ABI.** `include/sigil.h` and `include/sigil_sign.h` are the contract.
  The Rust libraries export exactly those symbols with exactly those error
  codes. No second header exists.
- **Two frontends, both pure ABI consumers.** The existing CLI is C
  (`cli/main.c`), deliberately unable to import the Zig core. The Rust CLI
  (`rust/sigil-cli`) follows the same rule: it declares the functions of the
  two headers as `extern "C"` and never depends on the Rust core crates, so
  the ABI is dogfooded on the Rust side too.
- **The bypass is made unbuildable, not just forbidden.** A later change
  that reaches past the ABI into a core function would leave the ABI
  unexercised and hide the need for a new exported function. Two controls
  stop that. The Rust CLI must also link and pass against the Zig archive,
  where no Rust core exists to call. And a harness check reads the workspace
  dependency graph and fails if `sigil-cli` depends on any core crate.
- **A two-by-two matrix.** Each frontend links each library, giving four
  `sigil` binaries: C on Zig, C on Rust, Rust on Zig and Rust on Rust.
  `tests/cli/test_cli` and every integration suite run unchanged against all
  four through `SIGIL_BIN`. The cross pairs prove the ABIs are
  interchangeable; the same-language pairs are what ships. Output must be
  byte-identical across the four wherever the suite asserts bytes.
- **Differential checks.** Shared vectors plus a differential fuzz compare the
  two on verdict, error class and output bytes (see "Differential testing").

## Workspace layout

```text
rust/
  Cargo.toml              workspace, Cargo.lock committed
  sigil/                  verify only: transcript, envelope, verify
  sigil-sign/             keygen, seal, key providers, paper, QR, PDF
  mecha-policy/           decide, install decide, machine hash, hint hash
  sigil-ffi/              staticlib exporting include/sigil.h
  sigil-sign-ffi/         staticlib exporting include/sigil_sign.h
  mecha-policy-ffi/       staticlib exporting mecha_policy.h
  sigil-cli/              the Rust CLI, an extern "C" consumer of both headers
```

- `sigil` depends on no signing code, mirroring `libsigil.a` against
  `libsigil_sign.a` today. A symbol scan over the built `sigil-ffi` archive,
  the Rust counterpart of `tests/test_no_signing_symbols`, enforces it.
- The core crates forbid `unsafe`. Only the three `-ffi` crates contain it.
  Every exported function takes pointer plus length where the header does
  and zeroizes secrets on every exit path. The core is written not to panic
  on any input, which the differential fuzz exercises; were it to, an
  `extern "C"` function aborts rather than unwinding into the caller. The
  header has no internal-error code to map a panic to.
- Rust consumers depend on the `sigil` and `mecha-policy` crates through a
  Cargo Git dependency pinned to a commit. C, Zig and other consumers link the
  static archives with the existing headers.
- Errors are closed enums with exhaustive matches. The numeric C codes derive
  from those enums in one place, so a new variant cannot be added without
  choosing its code.

## Identical data

The Zig core is pure: no I/O, no clock, and no randomness inside the format
code. Seeds, salts and nonces are parameters. The port keeps that shape, which
makes most outputs comparable byte for byte.

| Operation | Requirement |
|---|---|
| Verify (payload, envelope) | Same accept or refuse, same error code, for every input |
| Sign | Byte-identical envelope (Ed25519 is deterministic) |
| Public key text, `pubkey` formats | Byte-identical |
| Seal, keyfile, hot bundle with fixed seed, salt and nonce | Byte-identical, proven by known-answer vectors exported from the Zig tests |
| `keygen` through the CLI | OS entropy differs per run, so the test is a round trip: a key made by either opens and signs in the other |
| Paper backup, QR matrix, PDF bytes | Byte-identical for the same artifacts |
| mecha_policy decisions and hashes | Same reason code and same hex output |

Envelope tolerance (whitespace, field order, printable-binary alternates)
must match exactly, including what is rejected. `envelope.zig` is the largest
source of subtle divergence and gets the most fuzz time.

## Status (2026-11-10)

Step 1 is implemented: `rust/sigil` (transcript, verify, printable-binary,
envelope, public-key text) and `rust/sigil-ffi` export all eight functions of
`include/sigil.h`. `tests/differential/run` holds them to Zig on the
signature edge-case corpus (hand-written verdicts), every envelope in
`examples/` under every key, keys covering all byte values, the buffer and
NULL contracts, and a seeded mutation fuzz. Two planted mutants (cofactorless
verification; dropping the decoder's lead-byte aliasing) were each caught.

Step 2 is implemented: `rust/mecha-policy` and `rust/mecha-policy-ffi` export
all eight functions of `mecha_policy.h`. `tests/differential/policy` holds
them to the Zig library pinned as the flake input `mecha-policy` and to every
hand-written expectation in the vector manifests. The payload schema uses a
small exact JSON parser instead of serde, because serde_json accepts a JSON
array as a struct and Zig's `std.json` does not; v1 `max_major` reproduces
Zig's permissive `parseInt` (signs and `_` separators), checked by an
exhaustive sweep of every version-field string up to four characters.

The signing library of step 3 is implemented: `rust/sigil-sign` (keyfile and
hot-bundle format, Argon2id, XChaCha20-Poly1305, seal, keygen, PKCS#8 PEM, QR,
PDF and paper backup) and `rust/sigil-sign-ffi` export all seven functions of
`include/sigil_sign.h`. `tests/differential/sign` holds them to Zig and to
oracles neither produced:

- every error name, and the keyfile, seal and bundle operations with their
  buffer and NULL contracts;
- public keys and the restored PEM against OpenSSL's Ed25519 for the fixture
  seeds in `examples/sign_vectors/`;
- one committed license envelope per manifest and role, reproduced byte for
  byte at production KDF parameters;
- key pairs generated by each implementation, opened, signed with and
  restored by both;
- 59 keyfile variants around the strict parser, 52 with hand-written
  verdicts;
- paper PDFs across artifact sizes up to the QR capacity edge, plus a
  `qpdf --check`;
- a seeded mutation fuzz over keyfiles and bundles.

Planted mutants: reporting the wrong class for a keyfile opened as a bundle,
and dropping the lane-count bound, were both caught. Removing the leading-zero
check is an equivalent mutant, because the JSON lexer already refuses `01`.
Replacing the PDF writer's Zig-compatible number rounding with Rust's default
is not observable through these inputs; the `fmt_num` unit table, which the
package build runs, catches it. Still open in step 3: the C CLI on the Rust
libraries passing `tests/cli` unchanged.

## Signature acceptance must match exactly

`src/verify.zig` uses Zig's cofactored Ed25519 verifier and additionally
rejects low-order public keys as `BadPublicKey`. Common Rust crates differ on
the edge cases (non-canonical `S`, non-canonical or low-order `R`, mixed-order
keys, cofactored versus cofactorless equation). The Rust verifier is therefore
written against explicit rules, not a crate's default `verify`:

1. Decode the public key; reject non-canonical encodings and low-order points
   as the bad-key class.
2. Reject a signature whose `S` is not canonical.
3. Check the cofactored equation, matching Zig's treatment of `R`.

The exact rules are pinned by first characterizing the Zig verifier against a
committed edge-case corpus (the published Ed25519 edge-case families plus
small-order and mixed-order keys), then holding Rust to the same table. Any
row where the two disagree fails the suite.

## Dependencies

Proposed crates, all pinned by `Cargo.lock` and vendored by Nix:
`curve25519-dalek` (and `ed25519-dalek` for signing), `sha2`, `argon2`,
`chacha20poly1305`, `zeroize`, and the existing Rust `printable_binary`
library pinned to a commit. The Argon2id parameters and the XChaCha20-Poly1305
associated data must reproduce `src/sign.zig` exactly; the known-answer
vectors prove it. No crate is added for JSON, QR or PDF: those are ported from
the Zig sources so the bytes match.

## Differential testing

Both archives export the same symbol names, so they cannot be linked into one
process. The harness is two processes:

- A small C driver, compiled once per implementation, reads length-prefixed
  cases on stdin and writes a verdict record per case (return code, output
  length, output SHA-256).
- `tests/differential` feeds both drivers the same stream and fails on the
  first record that differs, printing the case.
- Inputs: every `examples/` vector set, the signature edge-case corpus, and a
  seeded mutation fuzz over valid envelopes, payloads, keyfiles, bundles and
  certificates. Seeds are fixed, so a failure is replayable.
- Bounded regressions run in `./test`. Long campaigns run from `./fuzz`.

The same driver pattern covers mecha_policy, using its committed vectors and
the pinned Zig library as the oracle.

## Build and Nix

- Flake packages: `sigil-zig` and `sigil-rust`, each a complete tree
  (`bin/sigil`, `lib/`, `include/`, `test-fixtures/`). `packages.default`
  selects by the tracked `CANONICAL_IMPL` file, which starts as `zig`.
- `./build` builds the canonical implementation; `--all-impls` builds both.
  Outputs are retained out-links consumed in place, per the fleet build
  convention. Nothing is copied from the store.
- `./test` builds both and runs every suite once per implementation, plus the
  differential suite. The `test-all` flake check does the same, so CI and the
  local gate cannot drift.
- Rust is pinned in the flake. Windows and macOS targets follow the build
  layout plan; this design does not claim them.

## Order of work

The step numbers match PLAN.md and the commit history.

0. Workspace, Nix package and CI wiring with one trivial exported function,
   so the toolchain is proven before any logic exists.
1. `sigil` verify path red-first: transcript, envelope, verify, the three
   `sigil.h` text helpers. Gate: all vector sets, the edge-case table and the
   differential fuzz agree with Zig.
2. `mecha-policy`, same gate against the Zig library.
3. `sigil-sign`: seal and keyfile known answers, key providers, paper, QR,
   PDF, with the C CLI on the Rust libraries passing `tests/cli` unchanged.
   3b. `sigil-cli` in Rust, then all four frontend and library pairs passing.
4. `CANONICAL_IMPL` selection and publication.

Consumers can pin after step 1 (verify) and step 2 (policy). Which
implementation is canonical after step 4 is an owner decision and stays `zig`
until asked.

## Costs to keep in view

- Every contract change is made twice, and the differential suite is the only
  thing that proves the two changes agree.
- mecha-commerce's JavaScript verifier is already a second implementation of
  verification; Rust makes three. Its issuer differential should eventually
  run against both native implementations.
- A bug shared by both implementations (a misread of the contract) is not
  caught by differential testing. The hand-written vector expectations remain
  the independent oracle for that.
