# sigil: intent

Status: drafted 2026-11-19 from the project's existing records (README,
docs/DESIGN.md, the license contract, PLAN decisions). The owner has not yet
confirmed this wording; until then it summarizes recorded decisions and adds
none. The linked documents stay authoritative for their details.

## Purpose

sigil signs and verifies Ed25519 documents whose payload stays readable. It
exists because the Mecha products need offline license verification that is
shared, not built into any one product (docs/DESIGN.md, opening).

The invariant everything else follows from: the signature covers the payload
bytes exactly as supplied. sigil never canonicalizes or re-serializes them,
and a caller can obtain payload bytes only by verifying first, so nothing
interprets unauthenticated input.

## Who it serves

- Products that verify licenses offline: Mecha Validate (and its GUI),
  Mecha RotShield and BeamFlix. They embed the verifier through the C ABI
  (`include/sigil.h`), the Zig package, or the Rust crates, plus the shared
  admission rules (mecha_policy).
- The license issuer: mecha-commerce mints and records licenses and
  installation certificates under the shared contract.
- The owner, who runs the CLI to generate keys, hold custody (sealed
  keyfiles, hot bundles, paper cold copies, the key ceremony) and sign. The
  CLI is an internal fulfillment tool; customers never run it.
- Customers, indirectly: the license files they hold can be read, and a
  product refuses anything not signed by its own key.

## Outcomes

- A product that links the verifier cannot mint a license: the signing code
  is not in its library, checked by symbol scans rather than asserted.
- Acceptance is exact and identical everywhere. Two implementations (Zig, and
  the Rust port the owner ruled on 2026-11-10) answer every input the same
  way, held together by one C ABI, shared vectors and differential tests. A
  forgery cannot exploit one implementation accepting what the other
  refuses.
- Envelopes survive email, terminals and copy-paste without weakening
  authentication (normalization can only cause a false rejection).
- Key custody fits the real threat (a backup or synced folder): encrypted
  keyfiles whose work factor cannot be downgraded, no secret crossing the
  FFI, recoverable cold copies, a rehearsed ceremony.
- One licensing contract the products and the issuer share
  (docs/MECHA_LICENSE_CONTRACT_V1.md), with sigil as its lead, and an
  update-signing contract (docs/UPDATE_SIGNING_CONTRACT_V1.md).

## Scope and non-goals

- No canonicalization scheme, collation or locale: the bytes are the bytes.
- No key identifier in the envelope: each product embeds exactly one public
  key per purpose, because choosing a key from the document means parsing
  before verifying.
- Envelope bytes are not an identifier (docs/DESIGN.md).
- Not a general PKI. Whether sigil has any role in an S/MIME certificate
  lifecycle is an open evaluation that defaults to no (PLAN).
- The online confirmation endpoint and the issuer service are separate
  pieces of work; who owns the issuer service is an open owner decision.
- Production keys, production signing, deployment, customer sends and public
  releases happen only with the owner's explicit approval. Everything in this
  repository uses test keys.

## Constraints

- The verifier's dependency budget is essentially zero: Ed25519 plus a
  printable-binary decode, and the core links no libc.
- C interfaces pass arbitrary bytes as pointer plus length.
- Builds go through Nix; `./test` is the one complete gate.
- The KDF parameters and the frozen payload and certificate versions are
  contract; changing them is a contract change, not a refactor.
- Zig stays the canonical implementation until the owner says otherwise.
  The shipped programs cross languages and are named by their core (Rust CLI
  on the Zig core, C CLI on the Rust core; docs/RUST_PORT_DESIGN.md).

## How success is verified

- `./test`: unit tests, the CLI surface and every integration suite on all
  four CLI and library pairs, the Zig-versus-Rust differentials, export
  inventories, the symbol custody scans, and the lint gate.
- Committed vectors with hand-written expectations (examples/), checked for
  byte-identical regeneration.
- docs/RELEASE_GATES.md: red-team evidence, which is pin- and
  platform-specific and never transfers to a newer build.

## Open questions for the owner

- Confirm or correct this document.
- The contract's open items (section 2): name canonicalization and signed
  evaluation grants.
- Whether sigil should own the online issuer service.
- Whether sigil participates in S/MIME at all.
- Operational decisions (ceremony date, paper samples, GUI demo mode, the
  production Worker, the exit code for a wrong passphrase) live in PLAN.md.

## Related documents

- PLAN.md: current work and gates; docs/PLAN_LOG.md: completed items.
- docs/DESIGN.md: envelope, transcript, revocation and custody decisions.
- docs/RUST_PORT_DESIGN.md: the second implementation and its rulings.
- docs/CUSTODY_AND_ISSUER_API_V1.md, docs/KEY_CEREMONY_V1.md: custody.
