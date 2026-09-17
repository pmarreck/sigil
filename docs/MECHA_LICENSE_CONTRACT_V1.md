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
  `expired`, `version_ceiling`, `class_key_mismatch`, `clock_rollback`,
  `operation_not_granted`) —
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

## 9. Revision 1.1 rulings (2026-09-17, lead)

Adopted from validate's and validate_gui's replies (both accepted the FROZEN
tier and the mecha_policy proposal as written; validate consumes it as a
native Zig dependency and re-exports the decision through its own C FFI so
the GUI never links a second verifier):

- Reason codes: validate's `operation_not_granted` ADDED (authentic,
  current grant that does not cover the requested operation class).
  Import-adapter codes (`import_too_large`, `store_unwritable`) stay
  app-side. App-local presentation (validate's AUTH_* verdict family) is
  the app's own.
- Clock high-water mark: mecha_policy specifies the persisted store format
  (opaque bytes in/out) so every app persists the same thing; apps own
  storage location and I/O.
- Trust domain vs signer role are ORTHOGONAL. `test-beta`/`test-paid` keys
  sign real beta/paid-CLASS grants; only test artifacts embed their
  pubkeys. The invariant is "test authority never authorizes production
  artifacts" (enforced by which pubkeys a build embeds), NOT "test keys
  cannot sign paid-class payloads" — the class-binding gate is untestable
  without wrong-class-under-each-key vectors. An authentic signed
  wrong-class grant is a POLICY refusal (`class_key_mismatch`); a test key
  offered to a production artifact is an AUTHENTICITY refusal (that pubkey
  is simply not embedded).
- Trust domain is a compile-time build option (validate:
  `-Dlicense-trust=production|test`); gate code identical; any test clock
  override compiles out under production trust; `license status` JSON
  reports `trust_domain`.
- Release byte-scan asserts ALL FOUR test/demo pubkeys absent
  (test-beta, test-paid, update-test, demo), plus the functional
  test-signed-license rejection at SIGNATURE.
- License import bound: 64 KiB. (The runbook's "Sigil 4 KiB" reference is
  incorrect — sigil imposes no such bound; its CLI mercy cap is 16 MiB.
  The 64 KiB bound is app import policy.)
- Import replaces the stored grant ONLY when the imported certificate's
  policy decision is `authorized` for this product at import time. Every
  refusal — signature, schema, AND policy level (expired, wrong-product,
  wrong-class, version ceiling) — preserves the prior working grant and
  reports the specific reason.
- Discovery wording (validate's, adopted verbatim): "Discovery (directory
  listing and stat) is bootstrap and ungated; it must not open, read,
  sniff, detect or validate file contents, and must produce no
  file-validity evidence." validate adds a source-scan control that fails
  if the walker ever gains an open/read call. Any readability opens the
  GUI performs before submission are the GUI's own and protected — early
  refusal there is welcome but the authoritative admission stays in the
  core.
- Expiry recheck cadence for long-lived processes: app-tunable but
  BOUNDED — a gate recheck at least every 60 seconds or every 1000 work
  units, whichever comes first (validate's 1000-file/60-s proposal adopted
  as the bound, not a fixed constant). The binding requirement is the
  test triple per entrypoint: admitted-before-expiry completes; the
  checkpoint on or after expiry refuses with the expired reason; nothing
  is admitted after expiry.
- Product identifiers (frozen): `mecha-validate`, `mecha-rotshield`.

## 10. Trial grants: static signed vs mutable usage state (OPEN — Peter)

Peter reconfirmed certificate-required trials with easy acquisition and
proposed signed metadata carrying the initial trial date plus processed
bytes. Evaluation, as requested, of the two mechanisms separately:

- A STATIC signed trial grant (class `trial`, signed `purchase_date` as
  trial start, short `expiry`, no metering) has the same authenticity and
  rollback properties as every other certificate: nothing mutable to
  protect, forgery impossible without the key, deletion yields no license
  and no work, re-import cannot extend anything. The only residual attack
  is host-clock manipulation, bounded by the clock high-water mark.
- PROCESSED-BYTES metering cannot be made authentic client-side: a signed
  certificate attests only what the ISSUER knew at signing (the trial
  start). A running byte counter is client-mutable state; with no issuer
  secret in clients (directive), the client cannot re-sign its own
  counter, so any local counter — hidden fork, xattr, or file — is
  honor-system, resettable by a determined user. Only periodic server
  round-trips could attest usage, which contradicts the no-new-phone-home
  posture. Recommendation: if byte quotas matter commercially, treat the
  counter as explicitly best-effort deterrence; otherwise prefer the
  date-only signed trial, which also deletes the last mutable-counter
  motivation for hidden storage.
- RotShield trial terms are UNDISCUSSED (Peter, via Einstein 2026-09-17)
  and are not derived from Validate's by assumption. RotShield-specific
  constraint already frozen: expiry never deletes parity or damages
  originals; recovery of already-protected data after trial expiry needs
  its own narrowly scoped policy decision.
