# Mecha License Contract v1 — DRAFT for peer agreement

Status: rev 1.3, 2026-09-28 (rev 1.1 rulings in section 9; rev 1.2 adds sections 11-12; rev 1.3 adds section 13, Peter's RotShield operation-class ruling); section 14 is a rev 2.0 DRAFT for paid terms (2026-10-01), not yet in force. Sigil is coordination lead per Peter's
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
- Release byte-scan asserts ALL test/demo pubkeys absent (five since
  2026-10-01: test-beta, test-paid, test-install-cert, update-test, demo),
  plus the functional
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
  originals. Recovery after expiry is RULED in section 13 (2026-09-28):
  Verify is grant-free at all times; Repair requires a valid grant.

## 11. Admission vs already-admitted work (rev 1.2 clarification, 2026-09-19)

Clarifies, does not relax, the rev 1.1 checkpoint bound.

- ADMISSION is the instant a unit of protected work is accepted for
  execution. The gate decides at admission; nothing else grants.
- The UNIT is a FIXED, FINITE work plan captured at admission — never a
  mutable or open-ended job attached to a file. For validate batch work:
  one file. For coverage: one file WITH its round count fixed at
  admission; additional rounds or repeats beyond that plan are new units
  needing admission. For RotShield: one transaction (create/update/repair of one
  registration's safe unit; Verify is ungated per section 13 and is not an
  admitted unit). For validate git work: one
  repository AS CAPTURED at admission — the refs resolved at the admission
  instant and the objects reachable from them, with the traversal bounded
  to that captured set; objects, refs or commits added after admission are
  not part of the plan and need fresh admission (a live walk of refs that
  can grow mid-traversal is a gap, ruled 2026-09-19). A huge single unit
  is admitted once and runs to completion or rollback even if expiry
  passes mid-unit;
  it never re-admits itself and cannot be extended after admission. App
  owners must confirm their admission APIs capture a finite plan; an API
  lacking that boundary is a contract gap to close before the gate ships.
- The checkpoint bound applies BETWEEN units (between files in a batch,
  between coverage calls, between RotShield transactions), never inside
  one admitted unit (validate's reconciliation, ruled 2026-09-19). Apps
  SHOULD cap the size of a single admitted plan (e.g. rounds per coverage
  admission) so a plan admitted just before the boundary cannot become
  unbounded post-expiry work; the cap is app policy, recorded in the
  entrypoint matrix.
- A per-plan cap is NOT a lifetime work quota (ruled 2026-09-21). A caller
  may make any number of separately admitted calls; each admission
  re-checks the clock against the known expiry, and expiry stops new
  units. The violation is hidden splitting INSIDE one admission — a call
  that internally chains plans beyond what it captured is an unbounded
  plan regardless of any cap. Test trust changes which pubkeys a build
  embeds, never whether admission runs. Witness: a multi-call sweep
  across an injected boundary — pre-boundary calls complete, the first
  at/after-boundary call is refused with no work, none admitted later,
  total work = sum of pre-boundary plans.
- Before admitting EACH subsequent unit the gate consults its cached
  decision; that cache is refreshed by a full re-evaluation at least every
  60 seconds or every 1000 units, whichever comes first, AND — the binding
  rule — a cached decision may never admit a unit whose admission instant is
  past the license's known UTC expiry boundary. The cache is an optimization
  for cost, not a grace period: the boundary is computed from the injected
  clock at every admission, so the 60 s/1000-unit refresh can only delay
  learning about a NEW license (import), never extend an expired one.
- Test requirements (per entrypoint): (a) unit admitted before expiry
  completes; (b) first admission at or after the boundary refuses with
  `expired`; (c) no admission after the boundary regardless of cache age —
  driven by an injected clock stepping across the boundary, which needs
  neither 1000 files nor 60 real seconds; (d) the huge-single-unit case:
  admitted before, completes after, nothing new admitted.
- Severity guidance for review: any NEW unauthorized unit admitted after the
  boundary is a gate bypass (the reviewer's CRIT class); an already-admitted
  unit completing after the boundary is by-design and not a finding.

## 12. Acceptance candidates and review provenance (rev 1.2, 2026-09-19)

A consumer becomes a review candidate ONLY by explicit nomination carrying:
exact commit; artifact SHA-256 per target; trust domain (`test` or
`production`) and which trust-role pubkeys the artifact embeds; reproducible
build provenance (flake attribute or documented command). Nomination sets
the ACCEPTANCE target and its provenance; it does not decide whether
evidence is valid. No acceptance claim exists without a nominated
candidate, but findings about any other exact artifact remain valid with
its status stated explicitly (baseline / WIP / released) — a shipped
artifact never escapes a finding because nobody nominated it.

Acceptance pairs every denial case with REAL authorized work through the
SAME entrypoint on the SAME candidate (a gate that refuses everything passes
every denial test). The review's independent matrix must derive from the
accepted contract revision, tracking its revision history — not from an
obsolete draft value or from whatever limit a binary happens to document;
the adopted import ceiling is 64 KiB and boundary tests cover below / at /
above it, with an oversized import preserving the prior grant. Trust domain
and signer role are separate axes in every case: state build-domain,
key-domain, signer-role and grant-class explicitly, and include missing-key
and wrong-key refusals on the same candidate. Test-trust positives are
development evidence; production-artifact acceptance additionally needs a
production-trust positive control, which depends on owner key provisioning
and is never satisfied by giving the reviewer a key or a signing oracle.

## 13. RotShield operation classes (rev 1.3, Peter ruling 2026-09-28)

Peter, in the entropy_shield conversation on 2026-09-28, relayed verbatim
by entropy_shield: "License for repair, no license for verify. That
incentivizes the repurchase (in the event of a new major version) right
away. In the event the project is sunsetted or otherwise no longer for
sale, it will be open-sourced and license restrictions released." This
supersedes his immediately prior answer that licensed both.

- FROZEN, RotShield only: Verify is GRANT-FREE. It is real content
  verification producing a real integrity verdict, not metadata-only
  discovery, and it stays available with no grant, with an expired grant,
  and for a major the grant does not cover. Create, Update and Repair
  REQUIRE a valid grant (mecha_policy `authorized`) at admission.
- Verify never chains. A Verify result may inform the user, never admit
  work: any repair, re-protect, create or update reached from a Verify
  flow (GUI confirmation callback, CLI convenience, backend adapter) is a
  new unit admitted through the gate. Reads whose only product is a
  verdict are Verify-class; reads that feed a write take the class of
  that write. entropy_shield maps each entrypoint in its inventory.
- Scope: the ruling was given about RotShield. Validate's gate is
  UNCHANGED: verification is Validate's product and the 2026-09-17
  directive licenses it in every build. Any extension to Validate needs
  Peter's explicit word.
- max_major stays as implemented: the version ceiling compares the
  running app major to the grant's `max_major`; releasing a newer major
  never revokes a grant for a major it already covers.
- Sunset commitment: if RotShield is sunsetted or otherwise no longer for
  sale it will be open-sourced and the license restrictions released. An
  owner commitment recorded here, not a mechanism: no build carries an
  automatic outage or sunset bypass, no source release or license choice
  is scheduled, and the commitment authorizes no key ceremony.
- No sunset mechanism (Peter, 2026-10-01 16:45 EDT): shipped apps carry no
  sunset switch or unlock statement. If a product is sunsetted, the
  license checks are removed from the code and the source is published.
  Do not add an unlock path. Offline policy (same day): an expired grant
  is restored by going online; the refusal screen must say so plainly;
  RotShield Verify stays grant-free.
  Air-gapped machines renew by file (section 14.3).
- Acceptance additions (RELEASE_GATES, entropy_shield row): Verify
  positive with no grant AND with an expired grant on protected data;
  Repair/Create/Update denial cases each paired with authorized work; a
  Verify-then-Repair flow whose Repair step is refused with no grant while
  the Verify verdict was still delivered.
- mecha_policy: no change. Grant-free operations never call `decide`;
  ABI 1 and both vector manifests stand.
- Recovery-store maintenance (lead ruling 2026-09-28 17:20 EDT, on
  entropy_shield's question): automatic repair or regeneration of
  RotShield's OWN store (index, metadata, structure) from parity records
  it already holds is infrastructure maintenance, grant-free, same class
  as Clear, and may run before a free Verify. Bounds: it reads no customer
  content, recomputes no parity from customer files (that is Create/Update),
  writes nothing to customer files (that is Repair), and emits no file
  validity verdict. A store rebuild that needs customer bytes is a gated
  unit of the class of the work it performs.

## 14. Paid terms and the versioned grant (rev 2.0 DRAFT, Peter decision 2026-10-01)

Peter's decisions, relayed by mecha-commerce from his email of 2026-10-01
10:54 EDT: a purchase issues a 1-month grant ("essentially a paid trial
period"); after the month an online refresh issues a 1-year grant for that
specific major.minor; point releases need no refresh; a minor release needs
a refresh and restarts the year; a major release needs a new purchase; no
refunds after 1 month; refund or chargeback within the month means no
refresh (offline) or invalidation (online); a chargeback after the month
revokes at the next online check; beta unchanged and has no 250 GB scanning
limit; the ledger is a Durable Object with UUIDv7 ids.

Scope: PAID only. Beta and alpha stay on payload v1, unchanged, for the
October 15 beta. Nothing in this section ships until the peers agree and the
open questions below are answered.

- Purchase grant: payload v1 as frozen. `payment_provider` paddle,
  `expiry` = `purchase_date` + 1 calendar month (end-of-month clamp, UTC,
  day-inclusive, the beta rule), `max_major` the purchased major. Verified
  2026-10-01 with `mecha-policy decide`: authorized on its expiry day,
  `expired` the next day. No contract change.
- Versioned grant: payload v2 (`"v":"2"`), every v1 field plus
  `max_minor` (decimal string). Policy: authorized only when
  (app_major, app_minor) <= (max_major, max_minor) lexicographically,
  else `version_ceiling`; `expiry` = mint date + 1 calendar year (Feb 29
  clamps to Feb 28), mandatory in v2. Signed by the paid-license role.
  v1 grants keep evaluating exactly as today.
- mecha_policy: the request gains `app_minor`; ABI version 2
  (`mecha_policy_abi_version() == 2`), one decide entrypoint; consumers
  assert 2 at startup. TDD against an extended vector manifest before any
  consumer moves.
- Refresh: a new issuer operation, `refreshEntitlement(entitlement_id,
  installed_major, installed_minor)`, reached from the app's online check
  carrying its current license. It mints through `issueForEntitlement` as a
  superseding, audited entitlement linked to the original (section 5 of
  the custody contract already allows that shape). Refused unless the
  ledger shows the entitlement active (no refund, no chargeback, adjustment
  states settled), the installed major equals the purchased major, and the
  refund window has closed. Never extends a purchase grant; never mints a
  higher major. The confirmation endpoint still never mints.
- Revocation: refunds and chargebacks are ledger state; the confirmation
  endpoint reports `revoked`; grace is Paddle's own adjustment lifecycle
  (pending then approved, chargeback created then reversed), not a
  separate 25-hour timer (commerce's recommendation; sigil agrees).
- `offline_days` stays in both versions for the confirmation cadence; the
  grant's `expiry` is what bounds use.

Open questions for Peter (each changes the payload or the policy):
1. Ceiling or exact: does a 1.3 grant also run 1.0-1.2? Recommended:
   ceiling, matching `max_major`.
2. Renewal: when a year ends with no new minor, does an online refresh
   issue another year for the same major.minor, free, indefinitely within
   the major? This reading makes a purchase effectively perpetual for its
   major with a yearly check-in.
3. Month-end offline gap: the year grant can only be minted after the
   refund window closes, so a buyer who is offline at the end of the month
   loses access until they reconnect. Recommended: purchase-grant expiry =
   purchase + 1 month + 7 days, with refresh allowed only from the day after
   the refund window. A refunded buyer offline would keep running for up to
   7 extra days.
4. ANSWERED 2026-10-01 22:15 EDT (section 14.2a): the `trial` class only.
   Original: the 250 GB scanning limit: which class carries it? Client-side byte
   counting cannot be made authentic (section 10); it would be a signed
   limit enforced on the honor system.

### 14.1 Reconciliation with Peter's email 171 (2026-10-01 10:59 EDT, via Einstein)

- Class wording. Commerce's brief calls the first month an initial paid
  license; Peter's email calls it a trial that everyone gets. Both readings
  keep execution certificate-required; neither permits unsigned or perpetual
  access. Contract wording until Peter says otherwise: the first month after
  a PURCHASE is a paid grant (class `paddle`, 1-month `expiry`), described
  to customers as a trial because it is refundable in full. If Peter means
  that anyone may get a month WITHOUT paying, that is a separate signed
  `trial` class (free, email-verified, 1-month `expiry`, role-bound like
  beta, never refreshable into a paid grant) and needs his explicit word.
- Refresh warnings (client behavior, no payload change): the app warns
  from one week before a 1-month grant's `expiry` and from one month before
  a 1-year grant's `expiry`, computed from the signed `expiry` on the same
  UTC day-inclusive rule.
  The refresh endpoint reports no separate due date: the signed `expiry`
  is the due date. A refresh attempted before the refund window closes is
  refused with `not_yet` and `retry_from` (the UTC date the window closes,
  `purchase_date` + 1 calendar month, plus one day).
- Installations: one person's license covers every OS and any number of
  installations; the three-installation cap is withdrawn. Each installation
  runs under its own machine-bound installation certificate (section 15).
  Peter chose a self-hosted service over Keygen.
- Beta: calendar-month expiry, no scanning cap. "Unlimited" refers to the
  scanning allowance, never to validity.


### 14.2 Peter 2026-10-01 16:23 EDT (commerce session): migration, degraded mode, trial

- Plastic (the 1-month purchase grant, class `paddle`): no reminders before
  it expires; this supersedes the one-week warning from email 171. After
  its `expiry`, an online app whose entitlement is still active (not
  refunded, not revoked) migrates to concrete automatically through the
  refresh operation. Offline after plastic expiry the app refuses protected
  work and shows only that it must go online to migrate. This also answers
  section 14 question 3: no overlap days; the refund window and plastic
  validity end together, and migration happens after both.
- Concrete (the versioned grant, payload v2): `expiry` = the MIGRATION
  (mint) date + 1 calendar year, never purchase date + 1 month + 1 year.
  This is what "mint date + 1 calendar year" above already states; it is
  now the ruled wording. A minor-version refresh likewise anchors on its
  own mint date.
- Concrete expired and offline: Validate stops validating. RotShield keeps
  verifying existing protected data and does not create, update or repair,
  which section 13 already guarantees because Verify is grant-free.
  Whether this degraded mode itself ends is open with Peter.
- Trial: a cloud-issued signed grant, class `trial` (`payment_provider`
  "trial"), mandatory `expiry` = issue date + 7 days, signed by its own
  per-product role (`validate-trial-license`, `rotshield-trial-license`)
  so a leaked trial key can mint only trials; plus an installation
  certificate like every phase. A role-and-class addition to mecha_policy,
  additive; built once trial issuance (who may obtain one, how often) is
  settled.
- Trial meter: the 250 GB counter lives in the app's settings, bound to the
  machine hash and protected by a keyed MAC whose key is embedded and
  obfuscated in the app. That key is NOT a sigil trust role: it is never in
  the key registry, never accepted by any server, never authorizes anything
  but the local meter, and must differ from every license and install-cert
  key. Deterrence only; anyone who extracts it can reset the meter, as
  section 10 already states for client-side metering.


### 14.2a Peter 2026-10-01 22:15 EDT (commerce session): no kill switch, email-free trial

- No remote version block, ever. No server-driven "this version is
  blocked" flag (such as BoltAI 2's `currentVersionBlocked`) goes in this
  contract, the issuer API or any app. Monthly phone-home may report that
  a new version exists; it never disables the running one. Only the
  signed grant's own `expiry` and version ceiling limit what runs.
- Trial issuance needs no email address. A trial is requested and keyed
  by (product, machine hash) only, so issuing one stores no personal data.
  This is consistent with the 2026-09-15 no-registration evaluation
  decision that question 5 below noted.
- The trial keeps the 250 GB scanning limit as a signed countdown (the
  trial-meter bullet above). This answers section 14 question 4: the
  limit belongs to the `trial` class only.
- RESOLVED 2026-10-02 by section 15.1 (server-side clustering of hashed
  hints refuses a second trial to a known device). Original: preventing
  repeat trials when the raw machine id
  changes (`/etc/machine-id` and Windows MachineGuid are user-editable).
  Candidates sent by commerce include an xattr marker (Peter's suggestion)
  and server-signed meter checkpoints. If checkpoints are chosen, the
  trial-meter key stops being an app-embedded MAC key and becomes a
  server signing role, which changes the trial-meter bullet and adds a
  role to KEY_REGISTRY.

### 14.3 Offline renewal by file (Peter, 2026-10-01 16:50 EDT)

For air-gapped machines, every online license operation also works by
carrying files. "Go online" then means "any machine, once".

- Request: the app writes `renewal-request.json` containing the imported
  license envelope (exact bytes), the machine hash, the installed
  major.minor and the operation wanted (`activate`, `migrate`, `renew`,
  `rebind`). Unsigned: the issuer verifies the embedded license itself,
  so nothing in the request is trusted on its own say-so. It carries no raw
  machine identifier.
- Exchange: the customer uploads it on a web page from any online device;
  `rebind` additionally requires the email one-time link, exactly as
  online. The issuer applies the same refusals as the online path
  (refunded, revoked, wrong major, refund window open) and is idempotent:
  the same request returns the same stored bytes.
- Response: a `renewal.sigil-bundle` holding the new license envelope
  and/or installation certificate, each a normal sigil envelope. The app
  imports it through the existing import path (64 KiB bound, grant
  preserved on every refusal); nothing in the bundle is trusted until each
  envelope verifies under its role key and passes mecha_policy.
- Scope: activation, plastic-to-concrete migration, concrete renewal,
  minor-version refresh and rebind. Not on the October 15 critical path
  unless a beta tester is air-gapped; required before paid launch.
- Formats (commerce's proposal, adopted 2026-10-01 with sigil vectors in
  examples/renewal_vectors): both files are UTF-8 JSON objects in
  canonical form, defined as exactly what `jq -cS` emits (sorted keys, no
  whitespace, non-ASCII raw; jq escapes the quote, backslash, controls
  U+0000-U+001F AND U+007F as `\u007f`, which is the one place it is
  stricter than RFC 8259 minimal escaping; jq is the rule), every value a string, no other
  keys, 64 KiB bound. Request:
  `{"installed_major","installed_minor","license","machine","operation","v":"1"}`
  with `license` the exact envelope text and `machine` 64 lowercase hex.
  Bundle: `{"install_cert","license","v":"1"}`; `install_cert` always
  present on success, `license` only when one was minted (migrate, renew,
  minor refresh). A refusal returns no bundle, only the online verdict
  code. Idempotency key: SHA-256 of the exact request bytes.
- Embedded envelopes (Peter, 2026-10-01 17:20 EDT): `license` and
  `install_cert` hold the printable-binary ENCODING of the exact envelope
  bytes, so neither file contains any JSON escape and a reader may refuse
  any backslash outright. Verification and `license_sha256` run on the
  DECODED bytes. Normative mapping: printable-binary `character_map.txt`
  SHA-256 47fc27044b11e3db9f915f6686d27bd42f3ed80d28fb06647b5736e840637094,
  the table at printable-binary 3f697d5 (sigil's own envelope encoder pin)
  and unchanged at its later commits. Checked 2026-10-01: no byte value
  encodes to a quote, backslash, DEL or control character, and all 256
  round-trip.
- Rebind by file: the customer clicks the email one-time link first (a
  pending rebind recorded server-side), then uploads; the upload stays one
  stateless request.
- Rebind quota: superseded 2026-10-02 by section 15.1 (2 devices per
  entitlement, $10 add-on seats, server-side counting). Rebind itself
  stays an email-link operation without the owner signing (email 171).
## 15. Installation certificates (IN FORCE for every phase including the October 15 beta, Peter 2026-10-01 15:41 EDT; paid-phase details still rev 2.0 draft)

A license says who may use a product; an installation certificate says
which machine may run it under that license. Execution needs both.

- Envelope: a sigil envelope signed by a new online role,
  `install-cert-<product>`, held in the issuer Worker beside the license
  roles, separate key per product, never the license key. Payload
  (`"v":"1"`, keys sorted as in every sigil payload): `cert_id` (UUIDv7),
  `expiry` (never later than the license's own `expiry`; for an undated
  license, 1 calendar year), `issued` (UTC date), `license_sha256` (hex
  SHA-256 of the exact license envelope bytes it binds to), `machine`
  (hex SHA-256 of the per-product fingerprint, below), `product`.
- Fingerprint: computed by the app, never sent raw. Inputs per OS: Linux
  `/etc/machine-id`; macOS `IOPlatformUUID`; Windows
  `HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid`. `machine` =
  SHA-256 of `"mecha-install-v1" || product || 0x00 || raw id`, so the same
  machine yields unrelated values for different products and the server
  never learns the raw identifier.
- Issuance (online, at first launch after license import): the app sends
  its license envelope and `machine`; the Worker verifies the license under
  its own registry key, checks the entitlement is active in the ledger,
  mints the certificate through the same audited path as licenses (audit:
  cert_id, license entitlement, machine hash, time), and stores it. Same
  license and same `machine` return the stored certificate; nothing new is
  minted.
- Admission (offline, every protected operation, beside the license
  check): the certificate verifies under the install-cert role key;
  `license_sha256` equals the hash of the imported license; `machine`
  equals the locally computed value; today (UTC) is on or before both
  expiries. Any mismatch refuses with a distinct reason
  (`install_cert_missing`, `install_cert_other_machine`,
  `install_cert_other_license`, `install_cert_expired`), never a file
  verdict.
- Self-service rebind: an email-authenticated customer (a one-time link to
  the license's address) can bind the license to a new `machine`; the old
  certificate is marked replaced in the ledger and reported `revoked` by the
  confirmation endpoint. Section 15.1 caps devices per entitlement; a
  rebind moves a seat, so whoever controls the license's email address
  can still move one.
- Refresh (section 14) re-issues the certificate for the new license on the
  same `machine` in the same online call.
- Normalization (fixed 2026-10-01): the raw id is trimmed of ASCII
  whitespace and ASCII-lowercased before hashing; the single implementation
  is mecha_policy `machineHash` (`mecha_policy_machine_hash`), so no app
  hashes the identifier its own way.
- Shared decision: mecha_policy `decideInstall` /
  `mecha_policy_install_decide` (3fb8cb8, additive to ABI 1) returns
  `install_cert_valid`, `_malformed`, `_wrong_product`, `_other_machine`,
  `_other_license`, `_expired`, `_clock_rollback`; the app adds
  `install_cert_missing` when it holds no certificate,
  `install_cert_not_authentic` when the certificate fails signature
  verification under the install-cert role, and
  `install_cert_machine_unavailable` when the raw OS id cannot be read
  (validate 23001eadd, adopted 2026-10-01). Spec and vectors:
  sigil examples/install_cert_vectors (mecha-install-cert-vectors/1, test
  role `test-install-cert`, passphrase public by design).
- Audit (commerce 0df5327, accepted): the mint audit row stays four fields
  (entitlement id, envelope SHA-256, role, time); the certificate's
  SHA-256 identifies it, and cert_id and machine live in the stored
  certificate record.
- IN FORCE FOR THE OCTOBER 15 BETA (Peter, 2026-10-01 15:41 EDT): every
  phase, beta included, requires an installation certificate; no phase
  runs without one. The beta needs one more online key,
  `install-cert-validate`.

Answered by Peter 2026-10-01 15:41 EDT (commerce session; canonical
mecha-commerce TERMINOLOGY.md at 0daf7a8): question 5, a free TRIAL is a
real phase (250 GB of scanning, one week); question 6, the beta needs
installation certificates. His phase names: trial; plastic (first license on
purchase, 1 month, refundable, refreshed online before the month ends);
concrete (issued once the plastic sets, 12 more months, not refundable);
beta. Concrete-licensed apps phone home monthly to check validity and new
versions, never error when that fails, warn from one month before expiry
when they have not been online, disclose this behavior, and extend
silently. Commerce is relaying his answers on trial issuance, the
plastic-to-concrete handoff and concrete expiry; section 14 is revised
when they arrive.

Open questions for Peter, in addition to section 14's four:
5. ANSWERED 2026-10-01 15:41 EDT: a free trial is a real phase (250 GB of
   scanning, one week); details being relayed by commerce. Original:
   is the first month available WITHOUT a purchase (a free `trial` class),
   or only after paying? Recommended: only after paying, the simplest form
   and the one commerce built toward.
   Note (commerce, 2026-10-01): a free trial anyone can obtain would also
   conflict with the 2026-09-15 no-registration evaluation decision.
6. ANSWERED 2026-10-01 15:41 EDT: yes, the beta requires installation
   certificates (sigil had recommended no; superseded). Original question:
   must the October 15 beta already require installation certificates?
   Recommended at the time: no. The beta ships license-only, as built and tested, and
   certificates arrive with paid launch. Requiring them for the beta adds a
   new signing role, an online activation path and app-side fingerprinting
   on every platform inside two weeks.

### 15.1 Device cap and server-side device policy (Peter 2026-10-02 11:42 EDT via commerce; sigil ruling 2026-10-02)

- Cap: each paid entitlement allows 2 devices, any mix of operating
  systems; each additional device is a $10 add-on seat. This replaces
  "no replacement quota" in section 15 and the rebind-quota bullet in
  section 14.3. Seats live in the commerce ledger and nowhere in a signed
  payload: license payload v1 and certificate payload v1 stay frozen, and
  buying a seat changes no file the customer holds.
- Decision site: the server decides device counts (Steam style) from
  observations the app reports at activation, rebind and refresh, online
  or by section 14.3 file. Client admission is unchanged: mecha_policy
  still checks license, certificate, machine and expiry offline, and a seat
  count never becomes an admission input.
- Observations: the request's existing certificate `machine` value plus an
  optional `hints` object with at most two keys, `disk` and `mac`, each a
  lowercase hex SHA-256. A separate machine-id hint is NOT added: `machine`
  already is the per-product hash of that identifier, and a second hash of
  the same value adds no evidence. Missing hints are omitted, never empty.
- Hint hash: SHA-256 of `"mecha-hint-v1" || product || 0x00 || kind || 0x00
  || normalized value`, kind `disk` or `mac`. Normalization:
  - `disk`: serial of the device holding the OS system volume (root on
    Linux and macOS, the Windows system drive), trimmed of ASCII whitespace
    and ASCII-lowercased; omitted when unreadable without elevation.
  - `mac`: the numerically lowest universally administered MAC among
    physical interfaces, as 12 lowercase hex digits without separators.
    Locally administered (second-lowest bit of the first octet set),
    all-zero and broadcast addresses are skipped, since randomized and
    virtual MACs carry no device identity.
  - Single implementation: mecha_policy `hintHash` (additive to ABI 1),
    with known-answer vectors in sigil examples, exactly as for
    `machineHash`. No app hashes a hint its own way.
- Salt scope: the hash is salted by product only, deliberately, because
  trial dedupe must match a device across different licenses.
- Privacy, stated precisely: these hashes are pseudonymous, not secret.
  The server operator could recover a MAC by brute force (with a known
  vendor prefix, about 2^24 candidates), and a disk serial when its format
  is guessable. The raw values never leave the machine, but the app's
  disclosure text must say it reports hashed hardware identifiers for
  license enforcement.
- Trust: hints are unauthenticated client claims. A modified client can
  report anything, for example the same hints from every machine. That is
  accepted. Like section 10's meter, the cap deters honest overuse and
  casual sharing, and it is not a cryptographic control.
- Counting (server policy, changeable without any format change): a device
  is a cluster of certificates whose observations overlap in at least 2 of
  their present values (`machine`, `disk`, `mac`); a request carrying only
  `machine` joins a cluster only on `machine` equality. The same clustering
  refuses a second trial to a known device, which replaces the xattr
  marker and meter-checkpoint options for re-trial prevention unless Peter
  says otherwise. Server-signed meter checkpoints are therefore not
  adopted, and the trial-meter key stays as section 14.2 states.
- Refusal at the cap: activation returns `device_limit_reached`. This is an
  issuer response, never an app admission reason or a file verdict.
- Freeing a seat: rebind (email one-time link, as ruled) or
  email-confirmed "deactivate all devices". Each replaced certificate is
  marked replaced in the ledger and reported `revoked` by the confirmation
  endpoint; the app refuses protected work once it learns `revoked`.
  Accepted slippage: an offline machine keeps running until its next
  online check or its certificate `expiry`, and an air-gapped machine
  (section 14.3) learns of revocation only when it next carries a file.
- Beta (October 15): observe-only. The beta app reports hints, and the
  server records clusters and counts but never refuses on the cap. sigil
  rules this as commerce recommended; Peter may override.
- Future Pro tier (one GUI client, many headless scanner nodes priced per
  node): noted, not designed. It needs a node class in the ledger and is
  out of scope for v1.
