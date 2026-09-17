# Mecha License Contract v1 — DRAFT for peer agreement

Status: PROPOSAL, 2026-09-17. Sigil is coordination lead per Peter's
directive of 2026-09-17 12:27 EDT (canonical text: LICENSE_OPERATIONS.md,
"Current directive" section, in Peter's Obsidian vault). Sections marked
FROZEN are Peter-approved and not open to peer negotiation; PROPOSED needs
agreement from the named owners; OPEN needs Peter.

Parties: sigil (lead; envelope, vectors, trust-role contract), validate
(Zig core + CLI), validate_gui (Rust GUI), entropy_shield (RotShield core +
GUI + CLI), mecha-commerce (issuance + delivery). Each owner implements its
own core and adapters; nobody edits another project's tree.

## 1. Envelope and verification (FROZEN — shipped and tested)

- Sigil envelope, transcript v1 (`"sigil.transcript.v1" ‖ u8 alg ‖ u64be
  payload_len ‖ payload`), Ed25519. The payload is signed EXACTLY as
  supplied; nothing canonicalizes or re-serializes, ever.
- Verify BEFORE parse: there is no API to obtain unverified payload bytes.
  The verified bytes come back byte-identical (trailing newline included).
- Consumer surface: `sigil_public_key_from_text` + `sigil_verify_envelope`
  via C ABI (`include/sigil.h`, static `libsigil.a`, verification-only —
  signing symbols do not exist in the consumer library).
  `examples/embed_minimal.c` is the reference embedding, including the
  multi-key grant-class rule (§4).
- Distinct error classes: MalformedEncoding vs BadPublicKey vs BadSignature.
  Authorization failures are the policy layer's (§3) and must never
  masquerade as file corruption — and vice versa.

## 2. Payload schema (FROZEN fields; two OPEN items)

JSON, flat, string values, exactly the release-plan set. The committed
canonical example is `examples/demo/payload.json`:

- `v` — payload schema version, `"1"`.
- `product` — product identifier (`"mecha-validate"`, `"mecha-rotshield"`).
  A license authorizes exactly one product.
- `customer_email`, `customer_name_canonical` — issuance identity/display.
- `features` — capability set (`"full"`; Pro = same SKU, different value).
- `max_major` — major-version ceiling for perpetual grants.
- `offline_days` — offline revocation-check grace window (`"365"`).
- `payment_provider` — grant class. APPROVED values: `"paddle"` (paid),
  `"beta"` (Founding Beta, mandatory `expiry`), `"demo"` (test fixtures
  only, must never verify in a release build). `"none"`+`entitlement_class`
  is REJECTED. Additional classes (e.g. `"comp"`) may be added by Peter.
- `payment_ref` — provider transaction / grant reference.
- `purchase_date` — mint timestamp's UTC date, `YYYY-MM-DD`.
- `expiry` — OPTIONAL. Absent = no time bound. `YYYY-MM-DD` UTC date.

Expiry evaluation (FROZEN, Peter-approved 2026-09-17): valid while
`now_utc < (expiry + 1 day) 00:00 UTC` — i.e. current UTC date <= expiry,
day-inclusive. Mint side: `expiry = purchase_date + 1 calendar month`,
end-of-month clamped. No tzdata on any client; a machine's local timezone
never moves the boundary. Empty/non-string `expiry` = malformed = data
error, never NOT AUTHENTIC. There is NO `valid_from` and no not-before gate
(Peter, 2026-09-17).

OPEN (Peter): (a) name canonicalization — recommendation on file is name
as display + verified email delivery as issuance identity, which changes
old canonicalization prose; (b) signed evaluation grants — whether a trial
class retains 250GB/7-day limits inside a signed grant or becomes a plain
short-expiry certificate (metering removal would delete the only
mutable-counter state worth protecting; see LICENSE_OPERATIONS hidden-fork
section).

## 3. Shared policy module (PROPOSED — the main negotiation)

One implementation, not three. Proposal:

- New sibling repo `mecha_policy`: pure Zig core (no I/O, no clock reads —
  hexagonal), C FFI, consumed natively by validate/rotshield Zig cores and
  via FFI by the Rust GUIs. Commerce (JS) does not gate operations; it gets
  the same semantics via the acceptance vectors (§6) rather than a port.
- Inputs, all injected: verified payload bytes; WHICH trust role verified
  (§4); product id of the asking app; app major version; current UTC time;
  prior monotonic clock high-water mark.
- Output: a typed decision — `authorized` | refusal with a STABLE reason
  code (`no_license`, `not_authentic`, `malformed`, `wrong_product`,
  `expired`, `version_ceiling`, `class_key_mismatch`, `clock_rollback`) —
  consumed identically by operation gates, `license status` JSON, and
  About. One decision path; GUIs cannot grant.
- Sequencing per Peter's directive: authenticity (sigil) → schema validity
  → authorization. Distinct layers, distinct error classes.
- Bounded atomic import (read-verify-replace, previous valid grant
  preserved on any failure) is part of the module's spec but each app owns
  its persistence adapter.

Counter-proposals welcome on: repo location, whether entropy_shield
consumes Zig-native or C FFI, reason-code naming.

## 4. Trust roles and test fixtures (PROPOSED)

Named trust roles, one Ed25519 keypair each:

| Role | Signs | Production key | Test key (committed, passphrase public) |
|---|---|---|---|
| beta-license | `payment_provider:"beta"` grants | ceremony, not yet provisioned | to be minted: `test-beta` |
| paid-license | `"paddle"`/`"comp"` grants | ceremony, not yet provisioned | to be minted: `test-paid` |
| update | release/update manifests | ceremony, not yet provisioned | exists: `examples/update_vectors/update_test.key` |
| demo | integrator documentation | never | exists: `examples/demo/demo.key` |

Rules (directive-mandated):
- A verifier binds each embedded key to the grant classes it may authorize:
  the beta key authorizes ONLY `payment_provider:"beta"` with `expiry`
  present; paid claims verify ONLY under the paid key. Without this a
  leaked beta key signs "paid, no expiry" forgeries.
- Test trust exercises the REAL gate — no skip flag, no test-mode
  allow-all, no GUI boolean, in ANY build including dev/test. Dev builds
  embed test-role pubkeys; release builds embed production-role pubkeys;
  the gate code is identical.
- Release artifacts must refuse all test/demo trust: acceptance includes a
  byte-scan (test pubkeys absent from shipped binaries) and a functional
  test (test-signed license fails at SIGNATURE against release trust).
- Sigil will mint `test-beta` and `test-paid` keypairs + signed fixture
  licenses per product per class (valid, expired, wrong-product,
  wrong-class-for-key) as committed vectors. Test keys never authorize
  production artifacts, structurally (different key, not different flag).

## 5. Entrypoint inventory (PROPOSED — each app owner fills in)

The gate admits protected operations at EVERY entrypoint: direct CLI, FFI
calls, channel/daemon/server, batch, scheduled and background work. Always
allowed without a grant: help/About/version, `license status`, `license
import`, reading already-created reports. Never allowed without a grant: a
new scan/protection/repair, on any path. Each app owner returns an explicit
inventory of its entrypoints (including legacy ones) as part of agreement;
"the GUI checks" is not coverage.

## 6. Acceptance vectors (sigil owns, all apps run)

A versioned, committed vector set (extending the existing demo + update
vector pattern; error CLASS asserted, not mere rejection): absent, altered,
expired, wrong-product, wrong-key, wrong-class-for-key licenses; valid
positive controls per class; expiry boundary triple (day before / of /
after, clock-injected, month-end and leap cases); long-lived process
crossing expiry (recheck at admission checkpoints); import bounds/atomic
failure; deletion (no license, no work, no trial); redelivery/replay (same
cert re-import cannot extend anything); update-vs-license trust separation
(both directions, at SIGNATURE). Each app runs the set against its own gate
in its own CI. Commerce runs the issuer differential (JS-signed must
verify under native sigil byte-for-byte).

## 7. Red team (Einstein erecting mecha_license_redteam)

Sigil supplies: all public keys, the committed signed fixtures, exact build
hashes of artifacts under test. Never: private keys, signing tokens,
production service access, or a signing oracle. The reviewer's goal is
unintended free use WITHOUT signing new certificates; contract text may be
negotiated with them, attacks stay independently authored. Scratch data
only; no host-clock changes; no destructive live-data experiments. Binary
patching is out of scope as a separate threat class (documented in
docs/LICENSING_PRIOR_ART.md).

## 8. What is NOT in this contract

Commercial policy (pricing, refunds, Paddle flows) — MECHA_RELEASE_PLAN.
Native OS code signing/notarization — per-app packaging. Hidden
forks/xattrs for license storage — explicitly deferred pending the
immutable-certificate-suffices determination. Clock-rollback high-water
mark mechanics — retained as a policy-module input but its persistence
design is a separate work unit. Production key provisioning and customer
issuance — NOT authorized by this document.
